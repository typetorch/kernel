--!nonstrict
-- TypeTorch kernel 0.5.3: DEBUG BUNDLES. When this server fails (or shuts down after a failure) it sends the backend,
-- by itself, everything an owner needs to see what happened without having watched: the players (present and those who
-- left in the last BUNDLE_LEFT_SECONDS), their client logs, the server log, the failure, and the deploy, swap and
-- fallback state. Contract: POST <url>/v1/fleet/bundle (Constants.BUNDLE_PATH) with the settings' backend key
-- (Fleet.target(), like Errors.luau and RemoteDebug.luau): { v = 1, id, j, t, k, b, a, s, g, code, level, message,
-- closing, failure, server, deploy, fallback, alerts, players, serverLog, playerLogs } -> 202 { ok, id }.
--
-- Triggers (the kernel calls them): every critical alert (Bundle.alert, from the kernel's fleetAlert: deploy_failed,
-- no_trusted_head, artifact_refused, kernel_api_mismatch, booted_unverified, health_rollback, lkg_exhausted, ...), a
-- generation that fails to start ("start_failed"), Fallback moving players off the server ("players_moved") and a dev's
-- `/tt bundle` ("manual"). A trigger returns the bundle's id at once (the alert carries it as d.bundle); the bundle
-- itself is built and sent BUNDLE_DELAY s later, so the state that follows the failure (the rollback, the alerts after
-- it) is in it. Triggers while one waits join it (same id; listed in failure.triggers). Limits: one bundle per trigger
-- code per BUNDLE_CODE_GAP s, BUNDLE_MAX per server lifetime, plus one closing bundle: BindToClose (Bundle.closing)
-- sends one ONLY when a failure trigger (not "manual") fired in the last BUNDLE_CLOSE_WINDOW s (user decision), or
-- flushes the bundle still waiting, at once, inside the close deadline.
--
-- Player logs: present players' client log rings come over the remote-debug channel (deps.clientLogs =
-- RemoteDebug.clientLogs; at most BUNDLE_PLAYERS_MAX players, in parallel, BUNDLE_LOGS_TIMEOUT s); for a client that
-- doesn't answer, and for players who already left, the error lines their client sent (Bundle.fromClient, beside
-- Errors.fromClient) are kept here, BUNDLE_CLIENT_LINES per player, for BUNDLE_LEFT_SECONDS after they leave.
-- Size: the JSON is cut to BUNDLE_BYTES, dropping player logs first, then the server log, then the deploy history
-- (server.trimmed says what went). Secrets: the backend key (and every secret deps.secrets lists) is replaced with
-- "<key>" in the encoded text, so no field can carry it. A 404 (an older backend without the route) stops bundles for
-- the server's lifetime; no answer, 429 and 5xx are retried (BUNDLE_RETRY_DELAYS). Nothing is sent from Studio or
-- without backend settings, and nothing here ever yields the caller of a trigger.

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Bundle = {}

local deps = {
	active = false, -- a live server (a JobId, not Studio)
	jobId = "",
	http = nil, -- HttpService (the kernel passes a Budget proxy)
	encode = nil, -- (table) -> string
	gzip = nil, -- Enum.HttpCompression.Gzip (nil: plain bodies)
	-- () -> { url, token, host }? : the backend (Fleet.target()).
	target = function()
		return nil
	end,
	-- () -> { string }: more secrets to scrub (the settings' keys and tokens); the backend key is always scrubbed.
	secrets = function()
		return {}
	end,
	-- Snapshots, each pcall'd (a failing one becomes { error = "..." }):
	summary = function() -- { b?, a?, s?, g? }: branch, artifact id, applied seq, generation number
		return {}
	end,
	server = function()
		return {}
	end,
	deploy = function()
		return {}
	end,
	fallback = function()
		return nil
	end,
	serverLog = function(_limit) -- the newest log ring entries { i, t, kind, text }, oldest first
		return {}
	end,
	players = function() -- { Player }: the players here now
		return {}
	end,
	playerInfo = function(_player) -- { ping? (ms), client? (its generation start status) }
		return {}
	end,
	clientLogs = function(_player, _since) -- yields; the client's log ring { { i, t, kind, text } } or an error
		error("no client logs", 0)
	end,
	newId = nil, -- () -> 32 hex characters (the kernel uses HttpService:GenerateGUID)
	clock = os.clock,
	time = os.time,
	wait = function(seconds)
		return task.wait(seconds)
	end,
	spawn = function(fn, ...)
		task.spawn(fn, ...)
	end,
	random = math.random,
	warn = warn,
	print = print,
}

function Bundle.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

-- State ---------------------------------------------------------------------------------------------------------------

local state = { stopped = false, closed = false, triggered = 0, lastFailureAt = nil, lastFailure = nil }
local pending = nil -- the bundle waiting for its BUNDLE_DELAY: { id, code, level, message, failure, at, triggers }
local codeAt: { [string]: number } = {}
local alerts = {} -- the last BUNDLE_ALERTS alerts raised here, oldest first
local swaps = {} -- the last BUNDLE_REPORTS swap reports, oldest first
local roster: { [number]: any } = {} -- UserId -> { u, n, joinedAt, leftAt?, client?, lines }
local stats = { sent = 0, failed = 0, skipped = 0, trimmed = 0, lastId = nil, lastCode = nil, lastAt = nil, lastBytes = nil, lastError = nil, lastStatus = nil, closingId = nil }
local warnedAt: { [string]: number } = {}

local LEVELS = { info = 1, warning = 2, critical = 3 }

local function warnOnce(kind: string, text: string)
	local now = deps.clock()
	if warnedAt[kind] and now - warnedAt[kind] < 60 then
		return
	end
	warnedAt[kind] = now
	deps.warn(text)
end

-- `text` cut to at most `max` bytes without splitting a UTF-8 character (JSON needs valid UTF-8).
local function cut(text: any, max: number): string
	local value = tostring(text)
	if #value <= max then
		return value
	end
	local result = string.sub(value, 1, max)
	for _ = 1, 3 do
		if utf8.len(result) then
			return result
		end
		result = string.sub(result, 1, #result - 1)
	end
	return (string.gsub(result, "[\128-\255]", "?"))
end

-- `value` as data JSON can carry (like RemoteDebug.toPlain, smaller): finite numbers, strings, booleans, arrays and
-- string-keyed tables; NaN and infinities become nil, other datatypes their tostring, cycles "<cycle>", deeper than 12
-- "...". Numeric keys of a table that isn't an array become strings.
local function plain(value: any, depth: number?, seen: any?)
	depth = depth or 0
	seen = seen or {}
	local kind = typeof(value)
	if kind == "nil" or kind == "boolean" then
		return value
	elseif kind == "string" then
		return cut(value, 4000)
	elseif kind == "number" then
		return if value == value and value ~= math.huge and value ~= -math.huge then value else nil
	elseif kind == "table" then
		if seen[value] then
			return "<cycle>"
		end
		if depth > 12 then
			return "..."
		end
		seen[value] = true
		local count, maxIndex = 0, 0
		for key in value do
			count += 1
			if typeof(key) == "number" and key >= 1 and key % 1 == 0 then
				maxIndex = math.max(maxIndex, key)
			end
		end
		local out = {}
		if count > 0 and maxIndex == count then
			for index = 1, count do
				local inner = plain(value[index], depth + 1, seen)
				out[index] = if inner == nil then false else inner
			end
		else
			for key, inner in value do
				local name = if typeof(key) == "string" then key elseif typeof(key) == "number" or typeof(key) == "boolean" then tostring(key) else nil
				if name then
					out[name] = plain(inner, depth + 1, seen)
				end
			end
		end
		seen[value] = nil
		return out
	elseif kind == "Instance" then
		local ok, name = pcall(function()
			return value:GetFullName()
		end)
		return if ok then name else "Instance"
	elseif kind == "function" or kind == "thread" or kind == "userdata" or kind == "buffer" then
		return kind
	end
	local ok, text = pcall(tostring, value)
	return if ok then text else kind
end

local function snapshot(fn, ...)
	local ok, value = pcall(fn, ...)
	if ok then
		return plain(value)
	end
	return { error = cut(value, 300) }
end

local function newId(): string
	if deps.newId then
		local ok, id = pcall(deps.newId)
		if ok and typeof(id) == "string" then
			id = string.lower((string.gsub(id, "[^%x]", "")))
			if #id == 32 then
				return id
			end
		end
	end
	local parts = {}
	for index = 1, 8 do
		parts[index] = string.format("%04x", deps.random(0, 65535))
	end
	return table.concat(parts)
end

local function cleanCode(code: any): string
	local text = string.lower(tostring(code))
	text = string.gsub(text, "[^a-z0-9_%.%-]", "_")
	return string.sub(if text == "" then "unknown" else text, 1, 64)
end

-- Players who left more than BUNDLE_LEFT_SECONDS ago are forgotten (and at most 200 who left are kept).
local function purgeRoster()
	local now = deps.time()
	local left = {}
	for userId, entry in roster do
		if entry.leftAt then
			if now - entry.leftAt > Constants.BUNDLE_LEFT_SECONDS then
				roster[userId] = nil
			else
				table.insert(left, entry)
			end
		end
	end
	if #left > 200 then
		table.sort(left, function(a, b)
			return a.leftAt < b.leftAt
		end)
		for index = 1, #left - 200 do
			roster[left[index].u] = nil
		end
	end
end

-- Players -------------------------------------------------------------------------------------------------------------

local function userOf(player): (number?, string?)
	local ok, userId, name = pcall(function()
		return player.UserId, player.Name
	end)
	if ok and typeof(userId) == "number" then
		return userId, if typeof(name) == "string" then name else tostring(userId)
	end
	return nil, nil
end

function Bundle.playerAdded(player)
	local userId, name = userOf(player)
	if not userId then
		return
	end
	purgeRoster()
	local entry = roster[userId]
	if entry and entry.leftAt then
		entry.leftAt, entry.client = nil, nil -- a rejoin: their lines stay
		entry.joinedAt = deps.time()
	elseif not entry then
		roster[userId] = { u = userId, n = name, joinedAt = deps.time(), lines = {} }
	end
end

-- `client` (optional): the player's client start status as the kernel last had it (kept with the player who left).
function Bundle.playerRemoving(player, client)
	local userId, name = userOf(player)
	if not userId then
		return
	end
	local entry = roster[userId] or { u = userId, n = name, lines = {} }
	roster[userId] = entry
	entry.leftAt = deps.time()
	entry.client = if client ~= nil then plain(client) else nil
	purgeRoster()
end

-- The kernel client's error batch (CHANNEL_ERRORS, the same payload Errors.fromClient takes; untrusted): its lines are
-- kept per player (BUNDLE_CLIENT_LINES, the newest), so a bundle has them after the player left.
function Bundle.fromClient(player, payload)
	if typeof(payload) ~= "table" or typeof(payload.e) ~= "table" then
		return
	end
	local userId, name = userOf(player)
	if not userId then
		return
	end
	local entry = roster[userId]
	if not entry then
		entry = { u = userId, n = name, joinedAt = deps.time(), lines = {} }
		roster[userId] = entry
	end
	local now = deps.time()
	for index = 1, math.min(#payload.e, 20) do
		local raw = payload.e[index]
		if typeof(raw) == "table" and typeof(raw.m) == "string" and #raw.m > 0 then
			local text = cut(raw.m, 600)
			if typeof(raw.n) == "number" and raw.n == raw.n and raw.n > 1 then
				text ..= ` (x{math.floor(math.min(raw.n, 1e6))})`
			end
			table.insert(entry.lines, { t = now, kind = "error", text = text })
		end
	end
	while #entry.lines > Constants.BUNDLE_CLIENT_LINES do
		table.remove(entry.lines, 1)
	end
end

-- Rings the kernel feeds ----------------------------------------------------------------------------------------------

-- A swap report (swapTo's, after the swap): the last BUNDLE_REPORTS go in deploy.reports.
function Bundle.noteSwap(report)
	if typeof(report) ~= "table" then
		return
	end
	local copy = plain(report)
	copy.at = copy.at or deps.time()
	table.insert(swaps, copy)
	while #swaps > Constants.BUNDLE_REPORTS do
		table.remove(swaps, 1)
	end
end

-- Triggers ------------------------------------------------------------------------------------------------------------

function Bundle.enabled(): boolean
	return deps.active == true and not state.stopped and deps.target() ~= nil
end

local send -- (entry, closing, deadline?) -> boolean, below

-- A trigger: returns the id of the bundle that will carry it (a new one, or the one waiting), or (nil, why). Never
-- yields. `failure` (optional): { stage?, error?, report? } (any plain data).
function Bundle.trigger(code: string, level: string, message: any, failure: any?): (string?, string?)
	code = cleanCode(code)
	level = if LEVELS[level] then level else "critical"
	local text = cut(message or code, 2000)
	local now = deps.clock()
	if code ~= "manual" then
		state.lastFailureAt = now
		state.lastFailure = { code = code, level = level, message = cut(text, 300), t = deps.time() }
	end
	if state.closed then
		return nil, "the server is closing"
	end
	if not deps.active then
		return nil, "not a live server (Studio)"
	end
	if state.stopped then
		return nil, "the backend has no bundle route (404): bundles are off for this server"
	end
	if deps.target() == nil then
		return nil, "no backend in the settings"
	end
	local trigger = { code = code, level = level, message = cut(text, 300), t = deps.time() }
	if pending then
		-- Joins the bundle that waits: one bundle for one incident.
		if #pending.triggers < 10 then
			table.insert(pending.triggers, trigger)
		end
		if LEVELS[level] > LEVELS[pending.level] then
			pending.level = level
		end
		if typeof(failure) == "table" then
			for key, value in failure do
				if pending.failure[key] == nil then
					pending.failure[key] = value
				end
			end
		end
		return pending.id, nil
	end
	if state.triggered >= Constants.BUNDLE_MAX then
		stats.skipped += 1
		return nil, `this server already sent {Constants.BUNDLE_MAX} bundles`
	end
	if codeAt[code] and now - codeAt[code] < Constants.BUNDLE_CODE_GAP then
		stats.skipped += 1
		return nil, `one {code} bundle per {Constants.BUNDLE_CODE_GAP} s`
	end
	codeAt[code] = now
	state.triggered += 1
	local failureCopy = {}
	if typeof(failure) == "table" then
		for key, value in failure do
			failureCopy[key] = value
		end
	end
	local entry = { id = newId(), code = code, level = level, message = text, failure = failureCopy, at = deps.time(), triggers = { trigger } }
	pending = entry
	deps.spawn(function()
		deps.wait(Constants.BUNDLE_DELAY)
		if pending == entry then
			pending = nil
			send(entry, false, nil)
		end
	end)
	return entry.id, nil
end

-- An alert the kernel raised (its fleetAlert): kept for the bundle's `alerts`; a critical one triggers a bundle.
-- Returns the bundle id (the alert's d.bundle) or nil.
function Bundle.alert(level: string, code: string, message: any, details: any?): string?
	table.insert(alerts, { code = cleanCode(code), level = tostring(level), message = cut(message, 300), t = deps.time() })
	while #alerts > Constants.BUNDLE_ALERTS do
		table.remove(alerts, 1)
	end
	if level ~= "critical" then
		return nil
	end
	local failure = nil
	if typeof(details) == "table" then
		failure = { stage = details.stage, error = details.error, details = details }
	end
	return (Bundle.trigger(code, "critical", message, failure))
end

-- Building ------------------------------------------------------------------------------------------------------------

local function logEntry(raw): any?
	if typeof(raw) ~= "table" or typeof(raw.text) ~= "string" then
		return nil
	end
	return {
		i = if typeof(raw.i) == "number" then raw.i else nil,
		t = if typeof(raw.t) == "number" then raw.t else nil,
		kind = if typeof(raw.kind) == "string" then cut(raw.kind, 16) else "output",
		text = cut(raw.text, 2000),
	}
end

-- The players section and the players whose client logs to ask for (present, at most BUNDLE_PLAYERS_MAX).
local function playersSection()
	purgeRoster()
	local list, ask, seen = {}, {}, {}
	local ok, present = pcall(deps.players)
	present = if ok and typeof(present) == "table" then present else {}
	local now = deps.time()
	for _, player in present do
		local userId, name = userOf(player)
		if userId and not seen[userId] then
			seen[userId] = true
			local entry = roster[userId]
			local infoOk, info = pcall(deps.playerInfo, player)
			info = if infoOk and typeof(info) == "table" then info else {}
			table.insert(list, {
				u = userId,
				n = name,
				joinedAt = entry and entry.joinedAt,
				ping = if typeof(info.ping) == "number" and info.ping == info.ping then info.ping else nil,
				client = if info.client ~= nil then plain(info.client) else nil,
			})
			if #ask < Constants.BUNDLE_PLAYERS_MAX then
				table.insert(ask, { player = player, u = userId })
			end
		end
	end
	for userId, entry in roster do
		if entry.leftAt and not seen[userId] and now - entry.leftAt <= Constants.BUNDLE_LEFT_SECONDS then
			table.insert(list, { u = userId, n = entry.n, joinedAt = entry.joinedAt, leftAt = entry.leftAt, client = entry.client })
		end
	end
	return list, ask
end

-- Asks every client in `ask` for its log ring at once; waits at most `timeout` s. { [userId string] = entries }.
local function collectLogs(ask, timeout: number)
	local logs = {}
	local slots = {}
	for _, item in ask do
		local slot = { done = false, u = item.u }
		table.insert(slots, slot)
		deps.spawn(function()
			local ok, entries = pcall(deps.clientLogs, item.player, 0)
			slot.ok, slot.entries = ok, entries
			slot.done = true
		end)
	end
	local stop = deps.clock() + timeout
	while deps.clock() < stop do
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
	local answered = {}
	for _, slot in slots do
		if slot.done and slot.ok and typeof(slot.entries) == "table" then
			local list = {}
			for _, raw in slot.entries do
				local entry = logEntry(raw)
				if entry then
					entry.i = nil
					table.insert(list, entry)
				end
			end
			while #list > Constants.BUNDLE_PLAYER_LINES do
				table.remove(list, 1)
			end
			logs[tostring(slot.u)] = list
			answered[slot.u] = true
		end
	end
	-- No answer (a left player, a client that didn't answer in time): the error lines the server kept for them.
	for userId, entry in roster do
		if not answered[userId] and #entry.lines > 0 then
			local list = table.clone(entry.lines)
			for index, line in list do
				list[index] = table.clone(line)
			end
			logs[tostring(userId)] = list
		end
	end
	return logs
end

-- The bundle's body (yields: the client logs). Exported for the tests.
function Bundle.build(entry, closing: boolean?, logsTimeout: number?)
	local summary = snapshot(deps.summary)
	summary = if typeof(summary) == "table" then summary else {}
	local failure = plain(entry.failure or {})
	failure = if typeof(failure) == "table" then failure else {}
	if #entry.triggers > 1 then
		failure.triggers = plain(entry.triggers)
	end
	local deploy = snapshot(deps.deploy)
	deploy = if typeof(deploy) == "table" then deploy else {}
	deploy.reports = plain(swaps)
	local server = snapshot(deps.server)
	server = if typeof(server) == "table" then server else {}
	local serverLog = {}
	local logOk, lines = pcall(deps.serverLog, Constants.BUNDLE_LOG_LINES)
	if logOk and typeof(lines) == "table" then
		for _, raw in lines do
			local line = logEntry(raw)
			if line then
				table.insert(serverLog, line)
			end
		end
		while #serverLog > Constants.BUNDLE_LOG_LINES do
			table.remove(serverLog, 1)
		end
	end
	local players, ask = playersSection()
	local playerLogs = collectLogs(ask, logsTimeout or Constants.BUNDLE_LOGS_TIMEOUT)
	return {
		v = 1,
		id = entry.id,
		j = deps.jobId,
		t = deps.time(),
		k = Constants.KERNEL_VERSION,
		b = if typeof(summary.b) == "string" then summary.b else nil,
		a = if typeof(summary.a) == "string" then summary.a else nil,
		s = if typeof(summary.s) == "number" then summary.s else nil,
		g = if typeof(summary.g) == "number" then summary.g else nil,
		code = entry.code,
		level = entry.level,
		message = cut(entry.message, 2000),
		closing = closing == true,
		failure = failure,
		server = server,
		deploy = deploy,
		fallback = snapshot(deps.fallback),
		alerts = plain(alerts),
		players = players,
		serverLog = serverLog,
		playerLogs = playerLogs,
	}
end

-- Encoding: scrubbed, at most BUNDLE_BYTES -------------------------------------------------------------------------------

local function secretsNow(): { string }
	local list = {}
	local ok, extra = pcall(deps.secrets)
	if ok and typeof(extra) == "table" then
		for _, secret in extra do
			if typeof(secret) == "string" and #secret >= 8 then
				table.insert(list, secret)
			end
		end
	end
	local target = deps.target()
	if target and typeof(target.token) == "string" and #target.token >= 8 then
		table.insert(list, target.token)
	end
	table.sort(list, function(a, b)
		return #a > #b
	end)
	return list
end

-- `text` with every copy of each secret (as written, and as a JSON encoder escapes it) replaced with "<key>".
function Bundle.scrub(text: string, secrets: { string }): (string, number)
	local count = 0
	for _, secret in secrets do
		local escaped = string.gsub(secret, '[\\"]', function(char)
			return "\\" .. char
		end)
		local forms = { secret, escaped, (string.gsub(escaped, "/", "\\/")) }
		for _, form in forms do
			local from = 1
			while true do
				local first, last = string.find(text, form, from, true)
				if not first then
					break
				end
				text = string.sub(text, 1, first - 1) .. "<key>" .. string.sub(text, last + 1)
				count += 1
				from = first + 5
			end
		end
	end
	return text, count
end

-- Halves a list in place (the oldest half goes). Returns whether anything went.
local function halve(list): boolean
	if typeof(list) ~= "table" or #list == 0 then
		return false
	end
	local drop = math.max(1, math.ceil(#list / 2))
	for _ = 1, drop do
		table.remove(list, 1)
	end
	return true
end

-- The body as JSON of at most BUNDLE_BYTES (or `max`): player logs go first, then the server log, then the deploy
-- history and reports, then the rest of the large sections; server.trimmed lists what went. Returns (text?, why?).
function Bundle.encode(body, max: number?): (string?, string?)
	max = max or Constants.BUNDLE_BYTES
	local secrets = secretsNow()
	local function encodeNow(): (string?, string?)
		local ok, text = pcall(deps.encode, body)
		if not ok or typeof(text) ~= "string" then
			return nil, `the bundle can't be encoded: {cut(text, 200)}`
		end
		return (Bundle.scrub(text, secrets))
	end
	local text, why = encodeNow()
	if not text then
		return nil, why
	end
	if #text <= max then
		return text
	end
	if typeof(body.server) ~= "table" then
		body.server = {}
	end
	local trimmed = {}
	body.server.trimmed = trimmed
	local function note(what: string)
		if not table.find(trimmed, what) then
			table.insert(trimmed, what)
		end
	end
	local steps = {
		function()
			-- Player logs: every list halved (the newest stay), until they are empty.
			local any = false
			for key, list in body.playerLogs or {} do
				if halve(list) then
					any = true
				end
				if #list == 0 then
					body.playerLogs[key] = nil
				end
			end
			if any then
				note("playerLogs")
			end
			return any
		end,
		function()
			if halve(body.serverLog) then
				note("serverLog")
				return true
			end
			return false
		end,
		function()
			local deploy = body.deploy
			if typeof(deploy) ~= "table" then
				return false
			end
			for _, key in { "history", "reports", "refusals" } do
				if halve(deploy[key]) then
					note(`deploy.{key}`)
					return true
				end
			end
			return false
		end,
		function()
			for _, key in { "fallback", "deploy", "failure" } do
				if body[key] ~= nil and next(body[key]) ~= nil then
					body[key] = { trimmed = true }
					note(key)
					return true
				end
			end
			return false
		end,
		function()
			for _, key in { "alerts", "players" } do
				if halve(body[key]) then
					note(key)
					return true
				end
			end
			if typeof(body.server) == "table" then
				for key in body.server do
					if key ~= "trimmed" and typeof(body.server[key]) == "table" then
						body.server[key] = nil
						note(`server.{key}`)
						return true
					end
				end
			end
			return false
		end,
	}
	for _, step in steps do
		while #text > max do
			if not step() then
				break
			end
			text, why = encodeNow()
			if not text then
				return nil, why
			end
		end
		if #text <= max then
			stats.trimmed += 1
			return text
		end
	end
	return nil, `the bundle is still {#text} bytes after trimming`
end

-- Sending -------------------------------------------------------------------------------------------------------------

-- One POST. Returns (ok, code?, errorText?).
local function post(text: string): (boolean, number?, string?)
	local target = deps.target()
	if not target then
		return false, nil, "no backend settings"
	end
	local request = {
		Url = target.url .. Constants.BUNDLE_PATH,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. target.token },
		Body = text,
	}
	if deps.gzip and #text > 1024 then
		request.Compress = deps.gzip
	end
	local ok, response = pcall(deps.http.RequestAsync, deps.http, request)
	if not ok then
		local message = Bundle.scrub(cut(string.gsub(tostring(response), "%c", " "), 200), secretsNow())
		return false, nil, message
	end
	local code = if typeof(response) == "table" and typeof(response.StatusCode) == "number" then response.StatusCode else nil
	if typeof(response) == "table" and response.Success == true then
		return true, code, nil
	end
	return false, code, `HTTP {tostring(code)}`
end

send = function(entry, closing: boolean, deadline: number?)
	local logsTimeout = Constants.BUNDLE_LOGS_TIMEOUT
	if closing then
		logsTimeout = Constants.BUNDLE_CLOSE_LOGS_TIMEOUT
		if deadline then
			logsTimeout = math.max(0, math.min(logsTimeout, (deadline - deps.clock()) / 2))
		end
	end
	local built, body = pcall(Bundle.build, entry, closing, logsTimeout)
	if not built then
		stats.failed += 1
		stats.lastError = cut(body, 200)
		warnOnce("build", `[TypeTorch] debug bundle {entry.id}: building it failed: {stats.lastError}`)
		return false
	end
	local text, why = Bundle.encode(body)
	if not text then
		stats.failed += 1
		stats.lastError = why
		warnOnce("encode", `[TypeTorch] debug bundle {entry.id} not sent: {why}`)
		return false
	end
	local attempt = 0
	while not state.stopped do
		local ok, code, errorText = post(text)
		stats.lastStatus = code
		if ok then
			stats.sent += 1
			stats.lastId, stats.lastCode, stats.lastAt, stats.lastBytes = entry.id, entry.code, deps.time(), #text
			deps.print(`[TypeTorch] debug bundle {entry.id} sent ({entry.code}{if closing then ", closing" else ""}, {math.ceil(#text / 1024)} KB)`)
			return true
		end
		stats.lastError = errorText
		if code == 404 then
			state.stopped = true
			pending = nil
			deps.warn("[TypeTorch] debug bundles: the backend has no /v1/fleet/bundle (HTTP 404, an older backend): no more bundles from this server")
			return false
		end
		attempt += 1
		local delay = Constants.BUNDLE_RETRY_DELAYS[attempt]
		local again = code == nil or code == 429 or code >= 500
		if not again or not delay or (deadline and deps.clock() + delay >= deadline) then
			break
		end
		deps.wait(delay)
	end
	stats.failed += 1
	warnOnce("send", `[TypeTorch] debug bundle {entry.id} not sent: {stats.lastError or "?"}`)
	return false
end

-- BindToClose: sends the bundle still waiting at once, else one closing bundle when a failure trigger fired in the last
-- BUNDLE_CLOSE_WINDOW s; nothing otherwise. Yields at most about `deadline` s. Returns whether one was sent.
function Bundle.closing(deadline: number?): boolean
	if state.closed then
		return false
	end
	state.closed = true
	local entry = pending
	pending = nil
	if not Bundle.enabled() then
		return false
	end
	local now = deps.clock()
	if entry == nil then
		if state.lastFailureAt == nil or now - state.lastFailureAt > Constants.BUNDLE_CLOSE_WINDOW then
			return false -- a clean close: nothing failed lately
		end
		local last = state.lastFailure
		entry = {
			id = newId(),
			code = "closing",
			level = last.level,
			message = cut(`the server is closing {math.floor(now - state.lastFailureAt + 0.5)} s after a failure ({last.code}): {last.message}`, 2000),
			failure = { stage = "closing", error = last.message, last = last },
			at = deps.time(),
			triggers = {},
		}
	end
	stats.closingId = entry.id
	return send(entry, true, now + (deadline or 10))
end

-- For status().bundles: counters, never the URL or the key.
function Bundle.info()
	return {
		enabled = Bundle.enabled(),
		stopped = state.stopped or nil,
		triggered = state.triggered,
		max = Constants.BUNDLE_MAX,
		pending = pending and pending.id,
		sent = stats.sent,
		failed = stats.failed,
		skipped = stats.skipped,
		trimmed = stats.trimmed,
		lastId = stats.lastId,
		lastCode = stats.lastCode,
		lastAt = stats.lastAt,
		lastBytes = stats.lastBytes,
		lastError = stats.lastError,
		lastStatus = stats.lastStatus,
		closingId = stats.closingId,
		lastFailureAt = state.lastFailure and state.lastFailure.t,
	}
end

-- Tests: start over.
function Bundle._reset()
	state.stopped, state.closed, state.triggered, state.lastFailureAt, state.lastFailure = false, false, 0, nil, nil
	pending = nil
	table.clear(codeAt)
	table.clear(alerts)
	table.clear(swaps)
	table.clear(roster)
	table.clear(warnedAt)
	for key, value in stats do
		stats[key] = if typeof(value) == "number" then 0 else nil
	end
end

return Bundle
