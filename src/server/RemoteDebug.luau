--!nonstrict
-- TypeTorch kernel 0.5.0: REMOTE DEBUG (plans/25). The owner opens /servers/<JobId> in the backend's explorer and reads
-- this server like the dev menu would: status, builds, budget, logs, players, a player's client logs, error counts, and
-- (through the running generation's framework) modules, state, assets, network stats and a read-only Dex.
--
-- A Roblox server can't be called into, so it PULLS:
--   1. the explorer marks the job watched on the backend; this server's next heartbeat reply carries `rd = 1`
--      (Fleet.luau hands it to RemoteDebug.wake);
--   2. the kernel long-polls `GET <url>/v1/fleet/commands?wait=8` (Authorization: the settings' backend key, X-TT-Job:
--      the JobId), runs each command on a kernel thread and posts the answers to `POST <url>/v1/fleet/results`;
--   3. it stops as soon as the backend says the job is no longer watched (the backend keeps a job watched 60 s after
--      the page last said so or a command came), after RD_FAILURES_MAX failed polls in a row, or when the settings lose
--      the backend. Not watched = no request at all.
--
-- Trust (the owner's rules):
--   * the backend is the one in the SIGNED settings record (Fleet.target(): `backend` = { url, key }): this module polls
--     nowhere else, so commands can only come from it;
--   * only ops on the fixed allow-list run (Constants.RD_KERNEL_OPS here, RD_FRAMEWORK_OPS through api:onRemoteDebug);
--     v1 is read-only: there is no op that changes anything;
--   * at most RD_COMMANDS_PER_MINUTE commands (burst RD_COMMANDS_BURST), each within RD_OP_TIMEOUT s;
--   * OWNERS ONLY: a command carries who asked: { kind = "roblox", userId } must be an owner by the kernel's own rule
--     (Access.isOwnerUserId); { kind = "token" } (the backend's admin token, or a token session) is treated as an owner
--     via the admin token, a deliberate decision (plans/25): that token is already full trust over the backend;
--   * SECRETS NEVER LEAVE: every answer is JSON-encoded, then every copy of a secret the kernel knows (the settings'
--     key / token / secret / password fields, the backend key, the remote-claude store's tokens), or any piece of one
--     at least 12 characters long, is replaced with "<redacted>" before it is posted; answers over RD_RESULT_MAX bytes
--     are refused, not cut.
-- Every poll and post is counted in the budget view (HTTP label "debug"; the kernel wraps deps.http).

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local RemoteDebug = {}

local deps = {
	http = nil, -- HttpService (wrapped for the budget view)
	jobId = "",
	active = false, -- a live server (a JobId, not Studio)
	-- () -> { url, token, host }? : the signed settings' backend (Fleet.target()).
	target = function()
		return nil
	end,
	encode = nil, -- (table) -> string
	decode = nil, -- (string) -> any
	-- () -> { string }: secret strings to scrub from every answer.
	secrets = function()
		return {}
	end,
	-- [op] = function(args, caller) -> result: the kernel's own ops.
	ops = {},
	-- () -> ((op, args, caller) -> result)?: the running generation's handler (api:onRemoteDebug), or nil.
	framework = function()
		return nil
	end,
	-- (userId) -> boolean: an owner by the kernel's rule (Access.isOwnerUserId). May yield (a cached web call).
	isOwner = function(_userId)
		return false
	end,
	-- Runs fn on a kernel thread (the kernel passes spawnOnKernel): a generation's hard stop can't end it.
	spawn = function(fn, ...)
		task.spawn(fn, ...)
	end,
	-- Sends a kernel message to one client (Transport.kernelSend).
	kernelSend = function(_player, _channel, ...) end,
	clock = os.clock,
	time = os.time,
	wait = function(seconds)
		return task.wait(seconds)
	end,
	random = math.random,
	warn = warn,
	print = print,
}

local KERNEL_OPS, FRAMEWORK_OPS = {}, {}

local state = {
	running = false,
	closed = false,
	watchUntil = 0, -- the backend said "watched" (heartbeat rd, or a poll's watch = true) until then
	holdUntil = 0, -- a 401/403/404: no session before then
	tokens = 0,
	tokensAt = 0,
}
local stats = { sessions = 0, polls = 0, commands = 0, answered = 0, refused = 0, failed = 0, timeouts = 0, redacted = 0, lastPollAt = nil, lastCommandAt = nil, lastError = nil, lastErrorAt = nil, lastOp = nil }

function RemoteDebug.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
	table.clear(KERNEL_OPS)
	table.clear(FRAMEWORK_OPS)
	for _, op in Constants.RD_KERNEL_OPS or {} do
		KERNEL_OPS[op] = true
	end
	for _, op in Constants.RD_FRAMEWORK_OPS or {} do
		FRAMEWORK_OPS[op] = true
	end
	state.tokens, state.tokensAt = Constants.RD_COMMANDS_BURST or 10, deps.clock()
end

-- Secrets ------------------------------------------------------------------------------------------------------------

local SECRET_WORDS = { "key", "token", "secret", "password", "auth", "cookie" }

local function secretName(name: any): boolean
	if typeof(name) ~= "string" then
		return false
	end
	local lower = string.lower(name)
	for _, word in SECRET_WORDS do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

-- Strings at least 8 characters long under a key whose name looks secret (key, token, secret, password, auth, cookie),
-- anywhere in `value` (tables at most `depth` deep), appended to `out`.
function RemoteDebug.collectSecrets(value: any, out: { string }, depth: number?, hinted: boolean?)
	depth = depth or 4
	if typeof(value) == "string" then
		if hinted and #value >= 8 and #value <= 4096 then
			table.insert(out, value)
		end
		return out
	end
	if typeof(value) ~= "table" or depth <= 0 then
		return out
	end
	for key, inner in value do
		RemoteDebug.collectSecrets(inner, out, depth - 1, hinted or secretName(key))
	end
	return out
end

-- The ways a JSON encoder may write `text`: quotes and backslashes escaped, and also forward slashes.
local function jsonForms(text: string): { string }
	local plain = string.gsub(text, '[\\"]', function(char)
		return "\\" .. char
	end)
	local slashed = string.gsub(plain, "/", "\/")
	return { plain, slashed }
end

-- `text` with every copy of each secret, and every piece of one at least 12 characters long (a preview cut a long
-- value short), replaced by "<redacted>". Returns (text, count).
function RemoteDebug.scrub(text: string, secrets: { string }): (string, number)
	local count = 0
	for _, secret in secrets do
		if typeof(secret) == "string" and #secret >= 8 then
			local variants = { secret }
			for _, form in jsonForms(secret) do
				if not table.find(variants, form) then
					table.insert(variants, form)
				end
			end
			for _, variant in variants do
				local prefix = string.sub(variant, 1, math.min(#variant, 12))
				local from = 1
				while true do
					local first = string.find(text, prefix, from, true)
					if not first then
						break
					end
					local last = first + #prefix - 1
					while last - first + 1 < #variant and string.sub(text, last + 1, last + 1) == string.sub(variant, last - first + 2, last - first + 2) do
						last += 1
					end
					text = string.sub(text, 1, first - 1) .. "<redacted>" .. string.sub(text, last + 1)
					count += 1
					from = first + 10
				end
			end
		end
	end
	return text, count
end

local function currentSecrets(): { string }
	local ok, list = pcall(deps.secrets)
	local secrets = if ok and typeof(list) == "table" then list else {}
	local target = deps.target()
	if target and typeof(target.token) == "string" then
		table.insert(secrets, target.token)
	end
	-- Longest first, so a secret that contains another is replaced whole.
	table.sort(secrets, function(a, b)
		return #a > #b
	end)
	return secrets
end

-- Client logs (kernel channel __tt/rdlogs) ---------------------------------------------------------------------------

local LOG_KINDS = { output = true, info = true, warning = true, error = true }
local nextLogsId = 0
local pendingLogs: { [number]: { player: Player, done: boolean, logs: any } } = {}

-- A client's reply, checked field by field (it comes from an untrusted client): at most RD_CLIENT_LOGS_MAX entries and
-- RD_CLIENT_LOGS_BYTES bytes, the newest kept, oldest first.
function RemoteDebug.cleanLogs(value: any)
	if typeof(value) ~= "table" then
		return nil
	end
	local entries = {}
	local count = 0
	for _, raw in value do
		count += 1
		if count > 1000 then
			break
		end
		if typeof(raw) == "table" and typeof(raw.i) == "number" and typeof(raw.t) == "number" and typeof(raw.text) == "string" then
			table.insert(entries, { i = raw.i, t = raw.t, kind = if LOG_KINDS[raw.kind] then raw.kind else "output", text = string.sub(raw.text, 1, 600) })
		end
	end
	table.sort(entries, function(a, b)
		return a.i < b.i
	end)
	local kept, bytes = {}, 0
	for index = #entries, 1, -1 do
		local entry = entries[index]
		bytes += #entry.text + 32
		if #kept >= (Constants.RD_CLIENT_LOGS_MAX or 200) or bytes > (Constants.RD_CLIENT_LOGS_BYTES or 64000) then
			break
		end
		table.insert(kept, 1, entry)
	end
	return kept
end

-- Transport.onKernel(CHANNEL_RDLOGS): the asked player's answer { id, logs }, taken once.
function RemoteDebug.onClientLogs(player: Player, payload: any)
	if typeof(payload) ~= "table" or typeof(payload.id) ~= "number" then
		return
	end
	local pending = pendingLogs[payload.id]
	if not pending or pending.done or pending.player ~= player then
		return
	end
	pending.logs = RemoteDebug.cleanLogs(payload.logs)
	pending.done = true
end

-- Asks `player`'s kernel client for its log ring after `since`; yields until it answers (or the timeout).
function RemoteDebug.clientLogs(player: Player, since: number?)
	nextLogsId += 1
	local id = nextLogsId
	local pending = { player = player, done = false, logs = nil }
	pendingLogs[id] = pending
	deps.kernelSend(player, Constants.CHANNEL_RDLOGS or "__tt/rdlogs", { id = id, since = since or 0 })
	local deadline = deps.clock() + (Constants.RD_CLIENT_LOGS_TIMEOUT or 5)
	while not pending.done and deps.clock() < deadline do
		deps.wait(0.05)
	end
	pendingLogs[id] = nil
	if not pending.done then
		error("no_reply: the player's client didn't answer in time", 0)
	end
	if pending.logs == nil then
		error("bad_reply: the player's client sent something that isn't a log list", 0)
	end
	return pending.logs
end

-- Plain data -----------------------------------------------------------------------------------------------------------

-- `value` as data JSON can carry: finite numbers, strings, booleans, arrays and string-keyed tables; NaN and infinities
-- become nil, an Instance its full name, a function or thread its type name, a cycle "<cycle>", other datatypes their
-- tostring; numeric keys of a table that isn't an array become strings. At most 40 deep and 100,000 values (then "...").
function RemoteDebug.toPlain(value: any)
	local seen = {}
	local budget = 100000
	local function plain(v, depth)
		budget -= 1
		if budget < 0 then
			return "..."
		end
		local kind = typeof(v)
		if kind == "nil" or kind == "boolean" or kind == "string" then
			return v
		elseif kind == "number" then
			return if v == v and v ~= math.huge and v ~= -math.huge then v else nil
		elseif kind == "table" then
			if seen[v] then
				return "<cycle>"
			end
			if depth > 40 then
				return "..."
			end
			seen[v] = true
			local count, maxIndex = 0, 0
			for key in v do
				count += 1
				if typeof(key) == "number" and key >= 1 and key % 1 == 0 then
					maxIndex = math.max(maxIndex, key)
				end
			end
			local out = {}
			if count > 0 and maxIndex == count then
				for index = 1, count do
					local inner = plain(v[index], depth + 1)
					out[index] = if inner == nil then false else inner
				end
			else
				for key, inner in v do
					local name = if typeof(key) == "string" then key elseif typeof(key) == "number" or typeof(key) == "boolean" then tostring(key) else nil
					if name then
						out[name] = plain(inner, depth + 1)
					end
				end
			end
			seen[v] = nil
			return out
		elseif kind == "Instance" then
			local ok, name = pcall(function()
				return v:GetFullName()
			end)
			return if ok then name else "Instance"
		elseif kind == "function" or kind == "thread" or kind == "userdata" or kind == "buffer" then
			return kind
		end
		local ok, text = pcall(tostring, v)
		return if ok then text else kind
	end
	return plain(value, 0)
end

-- Running commands ---------------------------------------------------------------------------------------------------

local function takeToken(): boolean
	local now = deps.clock()
	local rate = (Constants.RD_COMMANDS_PER_MINUTE or 30) / 60
	state.tokens = math.min(Constants.RD_COMMANDS_BURST or 10, state.tokens + (now - state.tokensAt) * rate)
	state.tokensAt = now
	if state.tokens < 1 then
		return false
	end
	state.tokens -= 1
	return true
end

local function clean(text: any, max: number): string
	local value = string.gsub(tostring(text), "%c", " ")
	return string.sub(value, 1, max)
end

-- Who asked, as the ops see it: { kind, userId?, owner = true, via }. nil = refused (not an owner).
local function callerOf(by: any)
	if typeof(by) ~= "table" then
		return nil
	end
	if by.kind == "token" then
		return { kind = "token", owner = true, via = "admin token" }
	end
	if by.kind == "roblox" and typeof(by.userId) == "number" and by.userId > 0 and by.userId % 1 == 0 then
		local ok, owner = pcall(deps.isOwner, by.userId)
		if ok and owner == true then
			return { kind = "roblox", userId = by.userId, owner = true, via = "roblox" }
		end
	end
	return nil
end

-- One command -> one answer { id, ok, json?, error?, ms, redacted? } (nil when it has no usable id).
function RemoteDebug.run(command: any)
	if typeof(command) ~= "table" or typeof(command.id) ~= "string" or #command.id > 64 or not string.match(command.id, "^[%w_%-]+$") then
		return nil
	end
	local id, op = command.id, command.op
	local started = deps.clock()
	local function refuse(why: string)
		stats.refused += 1
		return { id = id, ok = false, error = why, ms = 0 }
	end
	if typeof(op) ~= "string" or not (KERNEL_OPS[op] or FRAMEWORK_OPS[op]) then
		return refuse(`op_not_allowed: {clean(op, 40)} (read-only ops only)`)
	end
	if typeof(command.exp) == "number" and command.exp / 1000 < deps.time() - 30 then
		return refuse("expired")
	end
	if not takeToken() then
		return refuse("rate_limited: too many commands this minute")
	end
	local caller = callerOf(command.by)
	if not caller then
		return refuse("owners_only")
	end
	local args = if typeof(command.args) == "table" then command.args else {}
	stats.commands += 1
	stats.lastCommandAt = deps.time()
	stats.lastOp = op
	local ok, result
	if KERNEL_OPS[op] then
		local handler = deps.ops[op]
		if not handler then
			return refuse(`not_supported: {op} is missing from this kernel`)
		end
		ok, result = pcall(handler, args, caller)
	else
		local handler = deps.framework()
		if typeof(handler) ~= "function" then
			return refuse("not_supported: the running build has no remote debug hook (framework 0.5.0+ with devtools on), or nothing runs")
		end
		ok, result = pcall(handler, op, args, caller)
	end
	local ms = math.floor((deps.clock() - started) * 1000 + 0.5)
	local secrets = currentSecrets()
	if not ok then
		stats.failed += 1
		local text = RemoteDebug.scrub(clean(result, 300), secrets)
		return { id = id, ok = false, error = text, ms = ms }
	end
	local plainOk, plainResult = pcall(RemoteDebug.toPlain, result)
	local encodedOk, encoded = false, nil
	if plainOk then
		encodedOk, encoded = pcall(deps.encode, if plainResult == nil then {} else plainResult)
	end
	if not encodedOk or typeof(encoded) ~= "string" then
		stats.failed += 1
		return { id = id, ok = false, error = "the answer can't be encoded as JSON", ms = ms }
	end
	local scrubbed, redacted = RemoteDebug.scrub(encoded, secrets)
	if #scrubbed > (Constants.RD_RESULT_MAX or 200000) then
		stats.failed += 1
		return { id = id, ok = false, error = `the answer is too large ({math.ceil(#scrubbed / 1024)} KB, at most {math.floor((Constants.RD_RESULT_MAX or 200000) / 1024)} KB): ask for less`, ms = ms }
	end
	stats.answered += 1
	stats.redacted += redacted
	local who = if caller.kind == "roblox" then `owner {caller.userId}` else "the admin token"
	deps.print(`[TypeTorch] remote debug: {op} by {who} ({ms} ms{if redacted > 0 then `, {redacted} secret(s) redacted` else ""})`)
	return { id = id, ok = true, json = scrubbed, ms = ms, redacted = if redacted > 0 then redacted else nil }
end

-- Runs a poll's commands at once, each on a kernel thread; waits for all (at most RD_OP_TIMEOUT s). Answers, in order.
function RemoteDebug.runAll(commands: { any })
	local answers = {}
	local pending = 0
	local slots = {}
	for index, command in commands do
		if index > 16 then
			break
		end
		pending += 1
		slots[index] = { done = false, command = command }
		deps.spawn(function()
			local ok, answer = pcall(RemoteDebug.run, command)
			slots[index].answer = if ok then answer else { id = if typeof(command) == "table" then command.id else nil, ok = false, error = "internal error" }
			slots[index].done = true
		end)
	end
	local deadline = deps.clock() + (Constants.RD_OP_TIMEOUT or 10)
	while deps.clock() < deadline do
		local open = false
		for _, slot in slots do
			if not slot.done then
				open = true
				break
			end
		end
		if not open then
			break
		end
		deps.wait(0.05)
	end
	for index = 1, #slots do
		local slot = slots[index]
		if slot.done then
			if slot.answer and typeof(slot.answer.id) == "string" then
				table.insert(answers, slot.answer)
			end
		elseif typeof(slot.command) == "table" and typeof(slot.command.id) == "string" then
			stats.timeouts += 1
			table.insert(answers, { id = slot.command.id, ok = false, error = `timeout: the op took over {Constants.RD_OP_TIMEOUT or 10} s` })
		end
	end
	return answers
end

-- The session ---------------------------------------------------------------------------------------------------------

local function noteError(text: string)
	stats.lastError = clean(text, 200)
	stats.lastErrorAt = deps.time()
end

-- One request (yields): (ok, status code?, body?).
local function request(method: string, url: string, body: string?, target)
	local headers = { ["Authorization"] = "Bearer " .. target.token, ["X-TT-Job"] = deps.jobId }
	if body then
		headers["Content-Type"] = "application/json"
	end
	local ok, response = pcall(deps.http.RequestAsync, deps.http, { Url = url, Method = method, Headers = headers, Body = body })
	if not ok then
		local text = clean(response, 200)
		if target.token ~= "" then
			text = RemoteDebug.scrub(text, { target.token })
		end
		noteError(text)
		return false, nil, nil
	end
	if typeof(response) ~= "table" then
		noteError("no response")
		return false, nil, nil
	end
	if response.Success ~= true then
		noteError(`HTTP {tostring(response.StatusCode)}`)
		return false, response.StatusCode, nil
	end
	return true, response.StatusCode, response.Body
end

local function postResults(target, answers)
	if #answers == 0 then
		return
	end
	local okEncode, body = pcall(deps.encode, { j = deps.jobId, results = answers })
	if not okEncode then
		noteError("the answers can't be encoded")
		return
	end
	local ok, code = request("POST", target.url .. (Constants.RD_RESULTS_PATH or "/v1/fleet/results"), body, target)
	if not ok and (code == nil or (typeof(code) == "number" and code >= 500)) then
		deps.wait(1)
		request("POST", target.url .. (Constants.RD_RESULTS_PATH or "/v1/fleet/results"), body, target)
	end
end

local function sessionLoop()
	state.running = true
	stats.sessions += 1
	local first = deps.target()
	deps.print(`[TypeTorch] remote debug: the explorer is watching this server; polling {if first then first.host else "?"}`)
	local failures = 0
	local why = "not watched any more"
	while not state.closed do
		if not deps.active then
			why = "not a live server"
			break
		end
		if deps.clock() >= state.watchUntil then
			why = "not watched any more"
			break
		end
		local target = deps.target()
		if not target then
			why = "no backend in the settings"
			break
		end
		local startedAt = deps.clock()
		local url = `{target.url}{Constants.RD_COMMANDS_PATH or "/v1/fleet/commands"}?wait={Constants.RD_POLL_WAIT or 8}`
		local ok, code, body = request("GET", url, nil, target)
		stats.polls += 1
		stats.lastPollAt = deps.time()
		if not ok then
			failures += 1
			if code == 401 or code == 403 or code == 404 then
				state.holdUntil = deps.clock() + (Constants.RD_AUTH_HOLD or 300)
				why = `the backend refused the poll (HTTP {code})`
				break
			end
			if failures >= (Constants.RD_FAILURES_MAX or 3) then
				why = `{failures} failed polls in a row ({stats.lastError or "?"})`
				break
			end
			local wait = (Constants.RD_RETRY_SECONDS or 5) * (0.75 + 0.5 * deps.random())
			deps.wait(wait)
			continue
		end
		failures = 0
		local decodedOk, decoded = pcall(deps.decode, body or "")
		if not decodedOk or typeof(decoded) ~= "table" then
			noteError("the poll's answer is not JSON")
			decoded = {}
		end
		if decoded.watch == true then
			state.watchUntil = deps.clock() + (Constants.RD_IDLE_SECONDS or 60)
		elseif decoded.watch == false then
			state.watchUntil = 0
		end
		local commands = if typeof(decoded.commands) == "table" then decoded.commands else {}
		if #commands > 0 then
			postResults(target, RemoteDebug.runAll(commands))
		elseif decoded.watch ~= false then
			local elapsed = deps.clock() - startedAt
			if elapsed < (Constants.RD_POLL_GAP or 2) then
				deps.wait((Constants.RD_POLL_GAP or 2) - elapsed)
			end
		end
	end
	state.running = false
	deps.print(`[TypeTorch] remote debug: stopped polling ({why})`)
end

-- A heartbeat reply (Fleet.luau): `rd = 1` starts (or extends) a session.
function RemoteDebug.wake(reply: any)
	if typeof(reply) ~= "table" or (reply.rd ~= 1 and reply.rd ~= true) then
		return
	end
	if not deps.active or state.closed or deps.clock() < state.holdUntil or not deps.target() then
		return
	end
	state.watchUntil = math.max(state.watchUntil, deps.clock() + (Constants.RD_IDLE_SECONDS or 60))
	if not state.running then
		state.running = true
		deps.spawn(sessionLoop)
	end
end

-- BindToClose: no new polls.
function RemoteDebug.close()
	state.closed = true
end

-- For status().remoteDebug (no command contents, no URL, never the key).
function RemoteDebug.info()
	return {
		state = if state.running then "polling" elseif deps.clock() < state.holdUntil then "held" else "off",
		sessions = stats.sessions,
		polls = stats.polls,
		commands = stats.commands,
		answered = stats.answered,
		refused = stats.refused,
		failed = stats.failed,
		timeouts = stats.timeouts,
		redacted = stats.redacted,
		lastPollAt = stats.lastPollAt,
		lastCommandAt = stats.lastCommandAt,
		lastOp = stats.lastOp,
		lastError = stats.lastError,
		lastErrorAt = stats.lastErrorAt,
	}
end

-- Tests: start over.
function RemoteDebug._reset()
	state.running, state.closed, state.watchUntil, state.holdUntil = false, false, 0, 0
	state.tokens, state.tokensAt = Constants.RD_COMMANDS_BURST or 10, deps.clock()
	for key in stats do
		stats[key] = if typeof(stats[key]) == "number" then 0 else nil
	end
	table.clear(pendingLogs)
end

return RemoteDebug
