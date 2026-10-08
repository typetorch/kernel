--!nonstrict
-- 0.3.2 (user decision): the kernel sends this server's fleet data itself to the dev's fleet API, so it is live and
-- survives a broken (or missing) generation. Off unless the signed settings (0.3.8, Settings.luau; before: the
-- ConfigService key "TypeTorchFleet") hold `fleet` = { url = "https://...", token = "..." } (`typetorch fleet setup`;
-- taken on every new settings copy and every FLEET_SETTINGS_SECONDS; the token authorizes fleet
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
--
-- 0.3.9 (problem 23, "NetFail errors"): an unreachable API (a restarting or dead quick tunnel) no longer gets ~4 POSTs
-- per 30 s from every server in lockstep. Every wait is jittered (FLEET_JITTER); after a request's retries all failed
-- the sender backs off exponentially (FLEET_HEARTBEAT_SECONDS doubling up to FLEET_BACKOFF_MAX); a 401/403/404 holds it
-- off FLEET_AUTH_HOLD s; one success resets it. One warning line a minute at most, with the reason (NetFail: the
-- connection broke mid-request; DnsResolve / 530: a stale trycloudflare URL; 401/403: the wrong token), and one line
-- when it works again. Fleet.info() has `failures` (failed requests in a row) and `retryIn` (seconds, while waiting).
--
-- 0.4.0 (plans/21 C, one backend): the settings' `backend` = { url, key, analytics? } is read first (`fleet` = { url,
-- token } only while `backend` is missing; Fleet.info().source says which). The same URL and key serve the error
-- reports (Errors.luau, through Fleet.target()). Heartbeats carry the budget summary under `bu` (deps.heartbeatExtra).

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Fleet = {}

local deps = {
	http = nil, -- HttpService
	jobId = "",
	active = false, -- a live server (JobId, not Studio)
	-- () -> (ok, value, source): ok = false until the settings were read; value = { url, key } or { url, token } (or
	-- JSON); source = "backend" | "fleet".
	readSettings = function()
		return false, nil, nil
	end,
	status = function()
		return {}
	end,
	-- 0.4.0: () -> table?: extra heartbeat fields (the kernel adds the budget summary `bu`).
	heartbeatExtra = function()
		return nil
	end,
	encode = nil, -- (table) -> string
	decode = nil, -- (string) -> any
	warn = warn,
	print = print,
}

-- "unknown" (the settings not read yet: keep the last good), "absent", "ok", "invalid".
local settingsState = "unknown"
local settings = nil -- { url, token, host }
local settingsError = nil
local settingsSource = nil -- 0.4.0: "backend" | "fleet" (the settings field the URL and key came from)
local settingsReadAt = -math.huge

local queue = {} -- { path, body, attempts, nextAt }, oldest first
local heartbeat = { due = false, attempts = 0, nextAt = 0, lastAt = -math.huge, lastPlayersAt = -math.huge }
local started = false
local closed = false
local tokens, tokensAt = 10, os.clock()
local stats = { sent = 0, failed = 0, dropped = 0, lastOkAt = nil, lastError = nil, lastErrorAt = nil, lastStatus = nil, alerts = 0 }
local alertAt: { [string]: number } = {}
local warnedAt: { [string]: number } = {}
-- 0.3.9: the current outage: failed requests and failed cycles in a row, when the sender may try again, since when.
local outage = { failures = 0, cycles = 0, untilAt = 0, since = nil, reason = nil, loggedAt = -math.huge }

function Fleet.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

-- No settings, or not a live server: nothing is queued or sent.
function Fleet.enabled(): boolean
	return deps.active and settingsState == "ok"
end

-- Things worth keeping while the settings aren't known yet (a boot report before the settings read lands).
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

-- { url, key } (0.4.0: settings.backend) or { url, token } (settings.fleet), as a table or a JSON string. The url must
-- be https (no trailing slash kept). The key is kept as `token` here.
local function parseSettings(value): (any?, string?)
	if typeof(value) == "string" and deps.decode then
		local ok, decoded = pcall(deps.decode, value)
		value = if ok then decoded else nil
	end
	if typeof(value) ~= "table" then
		return nil, "not a { url, key } table"
	end
	local url = value.url
	local token = if value.key ~= nil then value.key else value.token
	if typeof(url) ~= "string" or #url > 300 or not string.match(url, "^https://[%w%.%-]+[%w:%-%./_]*$") then
		return nil, "url must be https://host[/path]"
	end
	if typeof(token) ~= "string" or #token < 8 or #token > 1000 or string.find(token, "[%c%s]") then
		return nil, "the key must be 8-1000 visible characters"
	end
	url = string.gsub(url, "/+$", "")
	return { url = url, token = token, host = string.match(url, "^https://([^/]+)") }, nil
end

-- Takes the settings' `backend` (0.4.0; else `fleet`) from the kernel's copy in memory (no web call). Not read yet:
-- keep the last good ones.
function Fleet.refreshSettings()
	if not deps.active then
		return
	end
	settingsReadAt = os.clock()
	local ok, value, source = deps.readSettings()
	source = if source == "fleet" then "fleet" else "backend"
	if not ok then
		return
	end
	if value == nil then
		if settingsState ~= "absent" then
			settingsState, settings, settingsError, settingsSource = "absent", nil, nil, nil
			table.clear(queue)
			heartbeat.due = false
		end
		return
	end
	local parsed, why = parseSettings(value)
	if not parsed then
		if settingsState ~= "invalid" then
			warnOnce("settings", `[TypeTorch] backend settings (settings.{source}) ignored: {why}`)
		end
		settingsState, settings, settingsError, settingsSource = "invalid", nil, why, source
		table.clear(queue)
		heartbeat.due = false
		return
	end
	local first = settingsState ~= "ok" or settingsSource ~= source or (settings and settings.host) ~= parsed.host
	settingsState, settings, settingsError, settingsSource = "ok", parsed, nil, source
	if first then
		deps.print(`[TypeTorch] backend: {parsed.host} (settings.{source})`)
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

-- 0.3.9: `seconds` +-FLEET_JITTER, so servers that failed together don't retry together.
local function jittered(seconds: number): number
	local spread = Constants.FLEET_JITTER or 0.25
	return seconds * (1 - spread + 2 * spread * math.random())
end

-- 0.3.9: what a failure means, in words a person can act on.
local function hintFor(code: number?, errorText: string?): string
	local text = errorText or ""
	if code == 401 or code == 403 then
		return if settingsSource == "fleet" then "the fleet token is wrong (settings.fleet.token: run typetorch backend setup)" else "the backend key is wrong (settings.backend.key: run typetorch backend setup)"
	elseif code == 404 then
		return `no fleet API at this URL (check settings.{settingsSource or "backend"}.url: typetorch backend setup)`
	elseif code == 530 or string.find(text, "DnsResolve", 1, true) then
		return "the host doesn't resolve: a stale trycloudflare URL? (restart the backend, then typetorch backend setup)"
	elseif string.find(text, "NetFail", 1, true) then
		return "the connection broke mid-request (a restarting quick tunnel?)"
	elseif code == 429 then
		return "the fleet API rate-limits this server"
	elseif typeof(code) == "number" and code >= 500 then
		return "the fleet API failed"
	elseif typeof(code) == "number" then
		return "the fleet API refused the request"
	end
	return "no answer"
end

-- 0.3.9: one warning line per FLEET_LOG_GAP s at most.
local function outageLine(text: string)
	local now = os.clock()
	if now - outage.loggedAt < (Constants.FLEET_LOG_GAP or 60) then
		return
	end
	outage.loggedAt = now
	deps.warn(text)
end

-- 0.3.9: a request answered: an outage (if any) is over.
local function noteSuccess()
	if outage.failures > 0 then
		local seconds = if outage.since then math.floor(os.clock() - outage.since + 0.5) else 0
		deps.print(`[TypeTorch] fleet API: heartbeats work again (after {outage.failures} failed request(s) in {seconds} s)`)
	end
	outage.failures, outage.cycles, outage.untilAt, outage.since, outage.reason = 0, 0, 0, nil, nil
end

-- 0.3.9: a request failed (each try counts).
local function noteFailure(reason: string)
	outage.failures += 1
	outage.since = outage.since or os.clock()
	outage.reason = reason
end

-- 0.3.9: a request and all its retries failed (or a 401/403/404, `hold`): nothing is sent until the backoff ends.
local function noteFailedCycle(code: number?, errorText: string?)
	local hold = code == 401 or code == 403 or code == 404
	local host = if settings then settings.host else "?"
	if typeof(code) == "number" and code >= 400 and code < 500 and not hold and code ~= 429 then
		-- Another 4xx (a body the API refused): the API is up, so no backoff; the request was dropped.
		outageLine(`[TypeTorch] fleet API {host} answered {code}: {hintFor(code, errorText)}; that request was dropped`)
		return
	end
	outage.cycles += 1
	local wait = if hold
		then jittered(Constants.FLEET_AUTH_HOLD or 300)
		else jittered(math.min(Constants.FLEET_BACKOFF_MAX or 300, Constants.FLEET_HEARTBEAT_SECONDS * 2 ^ (outage.cycles - 1)))
	outage.untilAt = os.clock() + wait
	outageLine(`[TypeTorch] fleet API {host} {if hold then "refused" else "unreachable"} ({outage.reason or "?"}): {hintFor(code, errorText)}; {outage.failures} failed request(s) in a row, next try in {math.ceil(wait)} s`)
end

-- One POST (yields). Returns (ok, retry, code?, errorText?): retry = worth trying again (no answer, 429, 5xx).
local function post(path: string, body): (boolean, boolean, number?, string?)
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
		noteSuccess()
		return true, false
	end
	stats.failed += 1
	stats.lastErrorAt = os.time()
	if not ok then
		stats.lastError = scrub(response, 200)
		stats.lastStatus = nil
		noteFailure(stats.lastError)
		return false, true, nil, stats.lastError
	end
	local code = if typeof(response) == "table" then response.StatusCode else nil
	stats.lastStatus = code
	stats.lastError = `HTTP {tostring(code)}`
	noteFailure(`{path}: HTTP {tostring(code)}`)
	local retry = code == 429 or (typeof(code) == "number" and code >= 500)
	return false, retry, if typeof(code) == "number" then code else nil, stats.lastError
end

-- The heartbeat body: the fleet status without `k` (a reserved server's access code stays in the universe), plus j.
local function heartbeatBody()
	local ok, status = pcall(deps.status)
	local body = if ok and typeof(status) == "table" then table.clone(status) else { sv = 2 }
	body.k = nil
	body.j = deps.jobId
	-- 0.4.0: the budget summary (`bu`) and anything else the kernel adds; only on what goes to the backend (the roll
	-- call and the analytics engine use api:fleetStatus() without it).
	local extraOk, extra = pcall(deps.heartbeatExtra)
	if extraOk and typeof(extra) == "table" then
		for key, value in extra do
			if body[key] == nil then
				body[key] = value
			end
		end
	end
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
	if now < outage.untilAt then
		return false -- 0.3.9: backing off (an outage) or held off (a 401/403/404)
	end
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
		local ok, retry, code, errorText = post(item.path, item.body)
		local still = table.find(queue, item)
		if ok or not retry or item.attempts >= #Constants.FLEET_RETRY_DELAYS then
			if still then
				table.remove(queue, still)
			end
			if not ok then
				stats.dropped += 1
				noteFailedCycle(code, errorText) -- 0.3.9
			end
		else
			item.attempts += 1
			item.nextAt = os.clock() + jittered(Constants.FLEET_RETRY_DELAYS[item.attempts])
		end
		return true
	end
	heartbeat.due = false
	heartbeat.lastAt = now
	local ok, retry, code, errorText = post("/v1/fleet/heartbeat", heartbeatBody())
	if ok or not retry or heartbeat.attempts >= #Constants.FLEET_RETRY_DELAYS then
		heartbeat.attempts, heartbeat.nextAt = 0, 0
		if not ok then
			noteFailedCycle(code, errorText) -- 0.3.9: back off (or hold off) before the next one
		end
	else
		heartbeat.attempts += 1
		heartbeat.nextAt = os.clock() + jittered(Constants.FLEET_RETRY_DELAYS[heartbeat.attempts])
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
		-- 0.3.9: failed requests in a row (0 once one works), and the seconds until the next try while backing off.
		failures = outage.failures,
		retryIn = if outage.untilAt > os.clock() then math.ceil(outage.untilAt - os.clock()) else nil,
		-- 0.4.0: "backend" | "fleet": the settings field the URL and key came from (nil without settings).
		source = settingsSource,
	}
end

-- 0.4.0: the backend's { url, token (the key), host } for the other senders (Errors.luau), or nil (no usable settings,
-- or not a live server). Never logged.
function Fleet.target()
	if not Fleet.enabled() or not settings then
		return nil
	end
	return settings
end

return Fleet
