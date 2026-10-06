--!nonstrict
-- TypeTorch kernel 0.3.8: THE SIGNED SETTINGS RECORD (plans/20; replaces every ConfigService key).
--
-- One DataStore entry, Constants.DATASTORE / SETTINGS_KEY ("settings"), written only by the CLI (`typetorch settings`,
-- `fleet setup`, `access push`): { v = 1, seq, at, body, sig, sigF }. `body` is JSON text:
--   { defaultBranch?, channels? = { [branch] = "prod" | "dev" }, access? = { members, revoked, devBadgeId },
--     fleet? = { url, token }, analytics? = { ...sink settings }, game? = { [key] = JSON } }
-- `sig` / `sigF` are the main and fallback prod keys' Ed25519 signatures of
--   "tt1settings" \n seq \n at \n body
-- (Signing.settingsCanonical), checked by the same strict rule as signed deploys (Signing.verify). The body is signed as
-- the exact text stored, so no canonical JSON is needed on either side.
--
-- In-universe code can write the DataStore but can't sign: a copy is taken only when it verifies, its body parses and
-- fits the caps, and its seq is higher than the last good copy's. A missing record, a failed read, an unsigned or
-- invalid copy and an older seq all keep the last good copy (reported in status().settings). An OLDER signed copy put
-- back by game code is refused by servers that hold a newer one; a server that boots meanwhile takes it until the next
-- write (plans/20 "Rollback by replay").
--
-- Reads: at boot (Settings.start, in parallel with the other boot reads), from the sync tick at most every
-- SETTINGS_REFRESH_SECONDS, and right after a ping (`{ k = "settings", s = seq }` on TypeTorch/deploy) with a newer seq,
-- at most every SETTINGS_PING_GAP seconds.
--
-- SERVER ONLY: the record holds tokens (fleet, analytics). Nothing in it ever replicates; the framework gets a copy
-- through the server API (api:settings()).

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Settings = {}

local deps = {
	-- Signing.luau (the kernel passes it, after Signing.init): verify(canonical, sig, sigF), settingsCanonical(...).
	signing = nil,
	warn = warn,
	print = print,
}

function Settings.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

local FIELDS = { "defaultBranch", "channels", "access", "fleet", "analytics", "game" }

local good = nil -- { seq, at, body (decoded), text (the body text), by = "sig" | "sigF", takenAt = os.time() }
local info = {
	state = "unknown", -- "unknown" (not read yet), "ok", "missing", "unsigned", "invalid", "error" (the read failed)
	reads = 0,
	settled = false, -- the first read finished (whatever it found)
	known = false, -- a read succeeded at least once (a missing record counts)
	readOk = false, -- the last read succeeded
	error = nil, -- the last problem (a refused copy, a failed read), kept until a good copy replaces it
	errorAt = nil,
	refused = nil, -- { why, seq?, at = unix s }: the last copy refused while a good one is kept
}
local listeners: { (any, any) -> () } = {}
local reading = false
local readAt = -math.huge -- os.clock() of the last read
local pingDue = false
local warnedAt: { [string]: number } = {}

local function warnOnce(kind: string, text: string)
	local now = os.clock()
	if warnedAt[kind] and now - warnedAt[kind] < 60 then
		return
	end
	warnedAt[kind] = now
	deps.warn(text)
end

local function note(why: string)
	info.error = string.sub(why, 1, 300)
	info.errorAt = os.time()
end

local function wholeNumber(value): boolean
	return typeof(value) == "number" and value == value and value % 1 == 0 and value >= 1 and value <= 2 ^ 53
end

local function deepCopy(value)
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value do
		copy[key] = deepCopy(inner)
	end
	return copy
end

-- The decoded body checked field by field (unknown fields are kept but ignored). Returns (body, why).
local function checkBody(text: string): (any?, string?)
	local ok, body = pcall(HttpService.JSONDecode, HttpService, text)
	if not ok or typeof(body) ~= "table" then
		return nil, "the body isn't a JSON object"
	end
	if body.defaultBranch ~= nil and (typeof(body.defaultBranch) ~= "string" or #body.defaultBranch == 0 or #body.defaultBranch > 64) then
		return nil, "defaultBranch must be a branch name"
	end
	if body.channels ~= nil then
		if typeof(body.channels) ~= "table" then
			return nil, "channels must be { [branch] = prod | dev }"
		end
		for branch, channel in body.channels do
			if typeof(branch) ~= "string" or (channel ~= "prod" and channel ~= "dev") then
				return nil, "channels must be { [branch] = prod | dev }"
			end
		end
	end
	for _, field in { "access", "fleet", "analytics", "game" } do
		if body[field] ~= nil and typeof(body[field]) ~= "table" then
			return nil, `{field} must be an object`
		end
	end
	if body.game ~= nil then
		local encodedOk, encoded = pcall(HttpService.JSONEncode, HttpService, body.game)
		if not encodedOk or #encoded > Constants.SETTINGS_GAME_MAX then
			return nil, `game is over {Constants.SETTINGS_GAME_MAX} bytes`
		end
	end
	return body, nil
end

-- One stored value: (copy?, state, why). copy = { seq, at, body, text, by } for a copy to take.
local function judge(value): (any?, string, string?)
	if value == nil then
		return nil, "missing", nil
	end
	if typeof(value) ~= "table" or value.v ~= 1 then
		return nil, "invalid", "not a v1 settings record"
	end
	if not wholeNumber(value.seq) then
		return nil, "invalid", "bad seq"
	end
	if typeof(value.at) ~= "string" or #value.at == 0 or #value.at > 40 or string.find(value.at, "\n", 1, true) then
		return nil, "invalid", "bad at"
	end
	if typeof(value.body) ~= "string" or #value.body > Constants.SETTINGS_BODY_MAX then
		return nil, "invalid", `the body must be JSON text of at most {Constants.SETTINGS_BODY_MAX} bytes`
	end
	if good and value.seq <= good.seq then
		if value.seq == good.seq and value.body == good.text then
			return nil, "same", nil
		end
		return nil, "older", `seq {value.seq} is not newer than the copy held (seq {good.seq})`
	end
	if value.sig == nil and value.sigF == nil then
		return nil, "unsigned", "unsigned (no sig, no sigF)"
	end
	local signing = deps.signing
	if not signing then
		-- The sibling Signing module: the same table the kernel initialized (Signing.init) before the first read.
		local ok, module = pcall(function()
			local sibling = script.Parent and script.Parent:FindFirstChild("Signing")
			return if sibling then require(sibling) else nil
		end)
		signing = if ok and typeof(module) == "table" and typeof(module.verify) == "function" then module else nil
		deps.signing = signing
	end
	if not signing then
		return nil, "invalid", "no signing module"
	end
	local canonical = signing.settingsCanonical(value.seq, value.at, value.body)
	if not canonical then
		return nil, "invalid", "bad signed fields"
	end
	local verified, why, by = signing.verify(canonical, value.sig, value.sigF)
	if not verified then
		return nil, "invalid", `signature: {why or "does not verify"}`
	end
	local body, bodyWhy = checkBody(value.body)
	if not body then
		return nil, "invalid", bodyWhy
	end
	return { seq = value.seq, at = value.at, body = body, text = value.body, by = by }, "ok", nil
end

-- Reads the record now (one GetAsync) and takes a good copy. Yields. Returns whether a new copy was taken.
local function read(): boolean
	if reading then
		return false
	end
	reading = true
	readAt = os.clock()
	info.reads += 1
	local ok, value = pcall(function()
		return DataStoreService:GetDataStore(Constants.DATASTORE):GetAsync(Constants.SETTINGS_KEY)
	end)
	reading = false
	info.settled = true
	if not ok then
		info.readOk = false
		note(`read failed: {value}`)
		if not good then
			info.state = "error"
		end
		warnOnce("read", `[TypeTorch] settings: the read failed ({string.sub(tostring(value), 1, 120)}); {if good then `keeping #{good.seq}` else "none yet"}`)
		return false
	end
	info.readOk = true
	info.known = true
	local copy, state, why = judge(value)
	if state == "same" then
		return false
	end
	if not copy then
		if good then
			if state == "missing" then
				why = "the record is gone from the DataStore"
			end
			info.refused = { why = why, seq = if typeof(value) == "table" and wholeNumber(value.seq) then value.seq else nil, at = os.time() }
			note(`{why}; kept #{good.seq}`)
			warnOnce(`refused {state}`, `[TypeTorch] settings: {why}; keeping #{good.seq}`)
		else
			info.state = state
			if state ~= "missing" then
				note(why or state)
				warnOnce(`refused {state}`, `[TypeTorch] settings refused: {why}`)
			end
		end
		return false
	end
	local before = good
	good = copy
	copy.takenAt = os.time()
	info.state = "ok"
	info.error, info.errorAt, info.refused = nil, nil, nil
	deps.print(`[TypeTorch] settings #{copy.seq} ({copy.at}, verified by {copy.by})`)
	for _, listener in listeners do
		task.spawn(listener, copy.body, before and before.body)
	end
	return true
end

-- Starts the boot read (doesn't yield).
function Settings.start()
	task.spawn(read)
end

-- Re-reads when the last read is older than `maxAge` seconds (0: now). Yields.
function Settings.refresh(maxAge: number?)
	if os.clock() - readAt < (maxAge or 0) then
		return
	end
	read()
end

-- A ping ({ k = "settings", s = seq } on the deploy topic): re-read soon when `seq` is newer than the copy held, at most
-- once per SETTINGS_PING_GAP seconds. Doesn't yield.
function Settings.ping(seq: any)
	if wholeNumber(seq) and good and seq <= good.seq then
		return
	end
	if pingDue then
		return
	end
	pingDue = true
	local wait = math.max(0, readAt + Constants.SETTINGS_PING_GAP - os.clock())
	task.delay(wait, function()
		pingDue = false
		read()
	end)
end

-- The first read finished (found, missing or failed): the boot doesn't wait longer.
function Settings.settled(): boolean
	return info.settled
end

-- A read succeeded at least once (a missing record counts): the dev lists (revocations) are known (S-M2).
function Settings.known(): boolean
	return info.known
end

-- The last read succeeded.
function Settings.readOk(): boolean
	return info.readOk
end

-- The last problem, or nil.
function Settings.readError(): string?
	return info.error
end

-- The good copy's body (decoded; DON'T change it), or nil.
function Settings.current(): any?
	return if good then good.body else nil
end

-- A deep copy of the body plus { seq, at } for the framework (server only), or nil.
function Settings.copy(): any?
	if not good then
		return nil
	end
	local copy = deepCopy(good.body)
	copy.seq, copy.at = good.seq, good.at
	return copy
end

-- fn(body, previous) after every new good copy (previous may be nil). Returns a disconnect function.
function Settings.onChange(fn: (any, any) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local index = table.find(listeners, fn)
		if index then
			table.remove(listeners, index)
		end
	end
end

-- (ok, value) of one body field for the readers that used ConfigService keys: ok = false until the first read finished
-- (keep what you have), value = nil when the record or the field is missing.
function Settings.field(name: string): (boolean, any)
	if not info.settled then
		return false, nil
	end
	if not good then
		return info.state ~= "error", nil
	end
	return true, good.body[name]
end

-- status().settings: { state, seq?, at?, age?, verifiedBy?, fields, reads, error?, errorAt?, refused? }. Never a value.
function Settings.status()
	local fields = {}
	if good then
		for _, field in FIELDS do
			if good.body[field] ~= nil then
				table.insert(fields, field)
			end
		end
	end
	local age = nil
	if good then
		local ok, parsed = pcall(DateTime.fromIsoDate, good.at)
		if ok and parsed then
			age = math.max(0, os.time() - parsed.UnixTimestamp)
		end
	end
	return {
		state = info.state,
		seq = good and good.seq,
		at = good and good.at,
		age = age,
		verifiedBy = good and good.by,
		fields = fields,
		reads = info.reads,
		error = info.error,
		errorAt = info.errorAt,
		refused = if info.refused then table.clone(info.refused) else nil,
	}
end

-- Tests: forget everything.
function Settings._reset()
	good = nil
	info.state, info.reads, info.settled, info.known, info.readOk = "unknown", 0, false, false, false
	info.error, info.errorAt, info.refused = nil, nil, nil
	table.clear(listeners)
	readAt = -math.huge
	pingDue = false
end

return Settings
