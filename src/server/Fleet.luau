--!nonstrict
-- 0.3.2 (user decision): the kernel sends this server's fleet data itself to the dev's fleet API, so it is live and
-- survives a broken (or missing) generation. Off unless the server-only ConfigService key "TypeTorchFleet" holds
-- { url = "https://...", token = "..." } (read at boot and every FLEET_SETTINGS_SECONDS; the token authorizes fleet
-- writes only and is never logged, printed or sent anywhere but the Authorization header). Studio sends nothing.
--
-- Requests (HttpService:RequestAsync, POST, JSON, `Authorization: Bearer <token>`); contract in plans/01 "Fleet API":
--   /v1/fleet/heartbeat  the fleet status { t, b, c?, a?, n, m, s, u, p, x?, v, q, g, h, e?, sv = 2 } plus j = JobId
--                        (never `k`, the reserved access code), every FLEET_HEARTBEAT_SECONDS and right after a change
--   /v1/fleet/report     each deploy report { s, b, a, j, r, e?, d?, t, g, k, p }, at once
--   /v1/fleet/alert      { level = "critical" | "warning", code, message (<= 300 bytes), j, b, a, s, t, g, k }, at once
--   /v1/fleet/closing    the heartbeat body, from BindToClose (a clean close, not a lost server)
-- Nothing here ever blocks a swap: one sender thread, a bounded queue (reports, alerts), one coalesced heartbeat slot
-- (its body is built when it is sent, so it is always current), retries after FLEET_RETRY_DELAYS for no answer, 429 and
-- 5xx, and a FLEET_RATE_PER_MINUTE token bucket.

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Fleet = {}

local deps = {
	http = nil, -- HttpService
	jobId = "",
	active = false, -- a live server (JobId, not Studio)
	readSettings = function()
		return false, nil
	end,
	status = function()
		return {}
	end,
	encode = nil, -- (table) -> string
	decode = nil, -- (string) -> any
	warn = warn,
	print = print,
}

-- "unknown" (not read yet, or ConfigService unavailable: keep the last good), "absent", "ok", "invalid".
local settingsState = "unknown"
local settings = nil -- { url, token, host }
local settingsError = nil
local settingsReadAt = -math.huge

local queue = {} -- { path, body, attempts, nextAt }, oldest first
local heartbeat = { due = false, attempts = 0, nextAt = 0, lastAt = -math.huge, lastPlayersAt = -math.huge }
local started = false
local closed = false
local tokens, tokensAt = 10, os.clock()
local stats = { sent = 0, failed = 0, dropped = 0, lastOkAt = nil, lastError = nil, lastErrorAt = nil, lastStatus = nil, alerts = 0 }
local alertAt: { [string]: number } = {}
local warnedAt: { [string]: number } = {}

function Fleet.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

-- No settings, or not a live server: nothing is queued or sent.
function Fleet.enabled(): boolean
	return deps.active and settingsState == "ok"
end

-- Things worth keeping while the settings aren't known yet (a boot report before ConfigService answers).
local function accepting(): boolean
	return deps.active and not closed and (settingsState == "ok" or settingsState == "unknown")
end

local function warnOnce(kind: string, text: string)
	local now = os.clock()
	if warnedAt[kind] and now - warnedAt[kind] < 60 then
		return
	end
	warnedAt[kind] = now
	deps.warn(text)
end

-- `text` without the token, cut to `max` bytes.
local function scrub(text: any, max: number): string
	local value = tostring(text)
	local token = settings and settings.token
	if token and token ~= "" then
		local from = 1
		while true do
			local first, last = string.find(value, token, from, true)
			if not first then
				break
			end
			value = string.sub(value, 1, first - 1) .. "<token>" .. string.sub(value, last + 1)
			from = first + 7
		end
	end
	value = string.gsub(value, "%c", " ")
	return string.sub(value, 1, max)
end

-- { url, token } as a table or a JSON string. The url must be https (no trailing slash kept).
local function parseSettings(value): (any?, string?)
	if typeof(value) == "string" and deps.decode then
		local ok, decoded = pcall(deps.decode, value)
		value = if ok then decoded else nil
	end
	if typeof(value) ~= "table" then
		return nil, "not a { url, token } table"
	end
	local url, token = value.url, value.token
	if typeof(url) ~= "string" or #url > 300 or not string.match(url, "^https://[%w%.%-]+[%w:%-%./_]*$") then
		return nil, "url must be https://host[/path]"
	end
	if typeof(token) ~= "string" or #token < 8 or #token > 1000 or string.find(token, "[%c%s]") then
		return nil, "token must be 8-1000 visible characters"
	end
	url = string.gsub(url, "/+$", "")
	return { url = url, token = token, host = string.match(url, "^https://([^/]+)") }, nil
end

-- Re-reads the settings (ConfigService snapshot, no web call). Unavailable: keep the last good ones.
function Fleet.refreshSettings()
	if not deps.active then
		return
	end
	settingsReadAt = os.clock()
	local ok, value = deps.readSettings()
	if not ok then
		return
	end
	if value == nil then
		if settingsState ~= "absent" then
			settingsState, settings, settingsError = "absent", nil, nil
			table.clear(queue)
			heartbeat.due = false
		end
		return
	end
	local parsed, why = parseSettings(value)
	if not parsed then
		if settingsState ~= "invalid" then
			warnOnce("settings", `[TypeTorch] fleet settings ({Constants.FLEET_KEY}) ignored: {why}`)
		end
		settingsState, settings, settingsError = "invalid", nil, why
		table.clear(queue)
		heartbeat.due = false
		return
	end
	local first = settingsState ~= "ok"
	settingsState, settings, settingsError = "ok", parsed, nil
	if first then
		deps.print(`[TypeTorch] fleet API: {parsed.host}`)
		heartbeat.due = true
	end
end

-- Takes one request from the rate bucket, or says when one is free.
local function takeToken(): (boolean, number)
	local now = os.clock()
	local rate = Constants.FLEET_RATE_PER_MINUTE / 60
	tokens = math.min(10, tokens + (now - tokensAt) * rate)
	tokensAt = now
	if tokens >= 1 then
		tokens -= 1
		return true, 0
	end
	return false, (1 - tokens) / rate
end

-- One POST (yields). Returns (ok, retry): retry = worth trying again (no answer, 429, 5xx).
local function post(path: string, body): (boolean, boolean)
	local current = settings
	if not current then
		return false, false
	end
	local encodedOk, encoded = pcall(deps.encode, body)
	if not encodedOk then
		stats.dropped += 1
		warnOnce("encode", `[TypeTorch] fleet {path}: the body can't be encoded: {scrub(encoded, 200)}`)
		return false, false
	end
	local ok, response = pcall(deps.http.RequestAsync, deps.http, {
		Url = current.url .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. current.token },
		Body = encoded,
	})
	if ok and typeof(response) == "table" and response.Success == true then
		stats.sent += 1
		stats.lastOkAt = os.time()
		stats.lastStatus = response.StatusCode
		return true, false
	end
	stats.failed += 1
	stats.lastErrorAt = os.time()
	if not ok then
		stats.lastError = scrub(response, 200)
		stats.lastStatus = nil
		warnOnce("network", `[TypeTorch] fleet {path}: {stats.lastError}`)
		return false, true
	end
	local code = if typeof(response) == "table" then response.StatusCode else nil
	stats.lastStatus = code
	stats.lastError = `HTTP {tostring(code)}`
	local retry = code == 429 or (typeof(code) == "number" and code >= 500)
	if not retry then
		warnOnce(`http{tostring(code)}`, `[TypeTorch] fleet API answered {tostring(code)} to {path}{if code == 401 or code == 403 then ` (check {Constants.FLEET_KEY}.token)` else ""}; dropped`)
	end
	return false, retry
end

-- The heartbeat body: the fleet status without `k` (a reserved server's access code stays in the universe), plus j.
local function heartbeatBody()
	local ok, status = pcall(deps.status)
	local body = if ok and typeof(status) == "table" then table.clone(status) else { sv = 2 }
	body.k = nil
	body.j = deps.jobId
	return body
end

local function enqueue(path: string, body)
	if not accepting() then
		return
	end
	table.insert(queue, { path = path, body = body, attempts = 0, nextAt = 0 })
	while #queue > Constants.FLEET_QUEUE_MAX do
		table.remove(queue, 1)
		stats.dropped += 1
	end
end

-- One step of the sender: the first due queued request (reports and alerts first), else a due heartbeat. Returns
-- whether it sent (or tried) something.
local function step(): boolean
	if not Fleet.enabled() then
		return false
	end
	local now = os.clock()
	local index = nil
	for position, item in queue do
		if item.nextAt <= now then
			index = position
			break
		end
	end
	local periodic = now - heartbeat.lastAt >= Constants.FLEET_HEARTBEAT_SECONDS
	local heartbeatReady = (heartbeat.due or periodic) and heartbeat.nextAt <= now
	if not index and not heartbeatReady then
		return false
	end
	local free = takeToken()
	if not free then
		return false
	end
	if index then
		local item = queue[index]
		local ok, retry = post(item.path, item.body)
		local still = table.find(queue, item)
		if ok or not retry or item.attempts >= #Constants.FLEET_RETRY_DELAYS then
			if still then
				table.remove(queue, still)
			end
			if not ok then
				stats.dropped += 1
			end
		else
			item.attempts += 1
			item.nextAt = os.clock() + Constants.FLEET_RETRY_DELAYS[item.attempts]
		end
		return true
	end
	heartbeat.due = false
	heartbeat.lastAt = now
	local ok, retry = post("/v1/fleet/heartbeat", heartbeatBody())
	if ok or not retry or heartbeat.attempts >= #Constants.FLEET_RETRY_DELAYS then
		heartbeat.attempts, heartbeat.nextAt = 0, 0
	else
		heartbeat.attempts += 1
		heartbeat.nextAt = os.clock() + Constants.FLEET_RETRY_DELAYS[heartbeat.attempts]
		heartbeat.due = true
	end
	return true
end

-- The sender thread: settings, heartbeats and the queue. Started once at boot.
function Fleet.start()
	if started or not deps.active then
		return
	end
	started = true
	Fleet.refreshSettings()
	task.spawn(function()
		while not closed do
			if os.clock() - settingsReadAt >= Constants.FLEET_SETTINGS_SECONDS or settingsState == "unknown" and os.clock() - settingsReadAt >= 5 then
				Fleet.refreshSettings()
			end
			if not step() then
				task.wait(0.25)
			end
		end
	end)
end

-- A heartbeat now (coalesced). `reason` "players": at most once per FLEET_PLAYERS_GAP seconds.
function Fleet.heartbeat(reason: string?)
	if not accepting() then
		return
	end
	if reason == "players" then
		local now = os.clock()
		if now - heartbeat.lastPlayersAt < Constants.FLEET_PLAYERS_GAP then
			return
		end
		heartbeat.lastPlayersAt = now
	end
	heartbeat.due = true
end

function Fleet.report(report)
	if typeof(report) == "table" then
		enqueue("/v1/fleet/report", table.clone(report))
	end
end

-- `level`: "critical", "warning" or (0.3.4) "info". `fields` = { s?, a?, b?, g? } (the kernel fills them). One alert per code per FLEET_ALERT_GAP seconds
-- (error_spike: FLEET_SPIKE_GAP), so a flood (forged messages, a crash loop) can't flood the API. `force` (0.3.3): no gap,
-- for alerts a person caused on purpose (branch_switch, build_load; the kernel limits those requests itself).
function Fleet.alert(level: string, code: string, message: string, fields, force: boolean?)
	if not accepting() or (level ~= "critical" and level ~= "warning" and level ~= "info") then
		return
	end
	local now = os.clock()
	local gap = if code == "error_spike" then Constants.FLEET_SPIKE_GAP else Constants.FLEET_ALERT_GAP
	if not force and alertAt[code] and now - alertAt[code] < gap then
		return
	end
	alertAt[code] = now
	stats.alerts += 1
	fields = fields or {}
	enqueue("/v1/fleet/alert", {
		level = level,
		code = code,
		message = scrub(message, 300),
		j = deps.jobId,
		b = fields.b,
		a = fields.a,
		s = fields.s,
		t = os.time(),
		g = fields.g,
		k = Constants.KERNEL_VERSION,
	})
	heartbeat.due = true
end

-- BindToClose: no more queueing; the closing request goes out now (yields up to `deadline` seconds, one retry).
function Fleet.closing(deadline: number?)
	if not Fleet.enabled() or closed then
		closed = true
		return
	end
	closed = true
	local stop = os.clock() + (deadline or 3)
	local body = heartbeatBody()
	body.closing = true
	local ok, retry = post("/v1/fleet/closing", body)
	if not ok and retry and os.clock() + 1 < stop then
		task.wait(1)
		post("/v1/fleet/closing", body)
	end
end

-- For status().fleet: never the token (the host only).
function Fleet.info()
	return {
		enabled = Fleet.enabled(),
		settings = settingsState,
		settingsError = settingsError,
		host = settings and settings.host,
		queued = #queue,
		sent = stats.sent,
		failed = stats.failed,
		dropped = stats.dropped,
		alerts = stats.alerts,
		lastOkAt = stats.lastOkAt,
		lastError = stats.lastError,
		lastErrorAt = stats.lastErrorAt,
		lastStatus = stats.lastStatus,
	}
end

return Fleet
