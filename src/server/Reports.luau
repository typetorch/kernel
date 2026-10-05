--!nonstrict
-- 0.3.2 (audit P-O1): this server's heartbeat in the universe's server list, and one report per deploy outcome.
-- The kernel writes both (never the generation), so a broken or missing generation still shows up.
--
-- Contract, shared with the CLI (`typetorch servers`, `deploy --wait`) and the framework's Admin > Servers. Keep it
-- exact; plans/01 "Heartbeat and deploy reports".
--   * MemoryStore SortedMap "TypeTorchServers", key = JobId, TTL 150 s. Written every 60 s +- 10 s (also while no
--     generation runs), once more shortly after each swap, and removed on BindToClose:
--       { t = server type, b = branch, c = effective channel?, a = artifact id?, n = players, m = max players,
--         s = server start (unix s), u = written at (unix s), p = place id, k = reserved access code?, x = 1 during an
--         A/B experiment?, v = kernel version, q = applied seq, g = generation number (0 = none),
--         h = "ok" | "failed" | "unverified" | "degraded", e = last error (<= 200 bytes)?, sv = 2 }
--   * MemoryStore SortedMap "TypeTorchReports", key = "<seq zero-padded to 10 digits>/<JobId>", TTL 7 days. One entry
--     per deploy outcome per server; a later outcome of the same seq on the same server overwrites it:
--       { s = seq, b = branch, a = artifact id, j = JobId, r = "swapped" | "failed" | "rolled_back" | "skipped" |
--         "booted", e = error (<= 300 bytes)?, d = seconds?, t = unix s, g = generation number, k = kernel version,
--         p = players }
-- Writes never block a swap: each runs on its own thread, retried after WRITE_RETRY_DELAYS, then dropped (counted in
-- info()). Studio sessions (no JobId) write nothing. `k` (an access code) is server-only data: game servers read it
-- for Admin > Servers joins; it is never sent to a client.

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Reports = {}

local deps = {
	memory = nil, -- MemoryStoreService
	jobId = "",
	studio = false,
	entry = function()
		return {}
	end,
	players = function()
		return 0
	end,
	warn = warn,
}

local maps: { [string]: any } = {}
local started = false
local closed = false
local lastHeartbeatAt = -math.huge
local heartbeatScheduled = false
local warnedAt: { [string]: number } = {}

local function newStats()
	return { writes = 0, failures = 0, dropped = 0, lastOkAt = nil, lastError = nil, lastErrorAt = nil, failing = false }
end
local stats = { heartbeat = newStats(), reports = newStats() }

-- `text` cut to at most `max` bytes without splitting a UTF-8 character (invalid UTF-8 can't be stored). nil stays nil.
function Reports.clip(text: any, max: number): string?
	if text == nil then
		return nil
	end
	text = string.gsub(tostring(text), "%c", " ")
	if #text <= max then
		return if utf8.len(text) then text else string.sub(string.gsub(text, "[\128-\255]", "?"), 1, max)
	end
	local cut = string.sub(text, 1, max)
	while #cut > 0 and not utf8.len(cut) do
		cut = string.sub(cut, 1, -2)
	end
	return cut
end

function Reports.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

-- Whether this server writes at all (a live server with a JobId; never Studio).
function Reports.enabled(): boolean
	return deps.memory ~= nil and typeof(deps.jobId) == "string" and deps.jobId ~= "" and not deps.studio
end

local function map(name: string)
	local handle = maps[name]
	if not handle then
		handle = deps.memory:GetSortedMap(name)
		maps[name] = handle
	end
	return handle
end

-- One warning per kind per minute: a MemoryStore outage must not flood the logs.
local function warnOnce(kind: string, text: string)
	local now = os.clock()
	if warnedAt[kind] and now - warnedAt[kind] < 60 then
		return
	end
	warnedAt[kind] = now
	deps.warn(text)
end

-- Runs `write` (yields) with bounded retries on its own thread; `stat` counts the outcome.
local function attempt(stat, kind: string, write: () -> ())
	task.spawn(function()
		local delays = Constants.WRITE_RETRY_DELAYS
		for try = 1, #delays + 1 do
			local ok, err = pcall(write)
			if ok then
				stat.writes += 1
				stat.lastOkAt = os.time()
				stat.failing = false
				return
			end
			stat.failures += 1
			stat.lastError = Reports.clip(err, 200)
			stat.lastErrorAt = os.time()
			stat.failing = true
			if try > #delays or closed then
				stat.dropped += 1
				warnOnce(kind, `[TypeTorch] {kind} write failed {try} times, dropped: {stat.lastError}`)
				return
			end
			task.wait(delays[try])
		end
	end)
end

-- Heartbeat ---------------------------------------------------------------------------------------------------------

-- Writes this server's entry now (on its own thread).
function Reports.heartbeat()
	if not Reports.enabled() or closed then
		return
	end
	lastHeartbeatAt = os.clock()
	local ok, entry = pcall(deps.entry)
	if not ok or typeof(entry) ~= "table" then
		warnOnce("heartbeat-entry", `[TypeTorch] heartbeat entry failed: {entry}`)
		return
	end
	entry.e = Reports.clip(entry.e, 200)
	entry.sv = 2
	local jobId = deps.jobId
	attempt(stats.heartbeat, "heartbeat", function()
		map(Constants.SERVERS_MAP):SetAsync(jobId, entry, Constants.SERVERS_TTL)
	end)
end

-- An extra heartbeat soon (after a swap): at once, or when HEARTBEAT_MIN_GAP has passed since the last one.
function Reports.poke()
	if not Reports.enabled() or closed or heartbeatScheduled then
		return
	end
	local wait = lastHeartbeatAt + Constants.HEARTBEAT_MIN_GAP - os.clock()
	if wait <= 0 then
		Reports.heartbeat()
		return
	end
	heartbeatScheduled = true
	task.delay(wait, function()
		heartbeatScheduled = false
		Reports.heartbeat()
	end)
end

-- The loop: first entry after `firstDelay` seconds, then every HEARTBEAT_SECONDS +- HEARTBEAT_JITTER.
function Reports.startHeartbeat(firstDelay: number?)
	if started or not Reports.enabled() then
		return
	end
	started = true
	task.spawn(function()
		task.wait(firstDelay or 1)
		while not closed do
			if os.clock() - lastHeartbeatAt >= Constants.HEARTBEAT_MIN_GAP then
				Reports.heartbeat()
			end
			task.wait(Constants.HEARTBEAT_SECONDS + (math.random() * 2 - 1) * Constants.HEARTBEAT_JITTER)
		end
	end)
end

-- BindToClose: stop writing and remove this server's entry (yields; one try, the 150 s TTL covers a failure).
function Reports.close()
	if closed then
		return
	end
	closed = true
	if not Reports.enabled() then
		return
	end
	local ok, err = pcall(function()
		map(Constants.SERVERS_MAP):RemoveAsync(deps.jobId)
	end)
	if not ok then
		deps.warn(`[TypeTorch] heartbeat remove failed: {err}`)
	end
end

-- Reports -----------------------------------------------------------------------------------------------------------

local RESULTS = { swapped = true, failed = true, rolled_back = true, skipped = true, booted = true }

-- The report key: "<seq zero-padded to 10 digits>/<JobId>".
function Reports.key(seq: number, jobId: string): string
	return string.format("%010d/%s", seq, jobId)
end

-- One deploy outcome: fields = { s, b, a, r, e?, d?, g }. Adds j, t, k, p. Non-blocking.
function Reports.report(fields)
	if not Reports.enabled() or typeof(fields) ~= "table" then
		return
	end
	local seq = fields.s
	if typeof(seq) ~= "number" or seq ~= seq or seq < 0 or seq % 1 ~= 0 or seq >= 1e10 or not RESULTS[fields.r] then
		return
	end
	local value = {
		s = seq,
		b = Reports.clip(fields.b, 100),
		a = Reports.clip(fields.a, 100),
		j = deps.jobId,
		r = fields.r,
		e = Reports.clip(fields.e, 300),
		d = if typeof(fields.d) == "number" and fields.d == fields.d then math.floor(fields.d * 1000 + 0.5) / 1000 else nil,
		t = os.time(),
		g = if typeof(fields.g) == "number" then fields.g else 0,
		k = Constants.KERNEL_VERSION,
		p = deps.players(),
	}
	local key = Reports.key(seq, deps.jobId)
	attempt(stats.reports, "report", function()
		map(Constants.REPORTS_MAP):SetAsync(key, value, Constants.REPORTS_TTL)
	end)
end

-- For status(): { enabled, heartbeat = stats, reports = stats } (copies). `failing` = the last write failed.
function Reports.info()
	return {
		enabled = Reports.enabled(),
		map = Constants.SERVERS_MAP,
		reportsMap = Constants.REPORTS_MAP,
		heartbeat = table.clone(stats.heartbeat),
		reports = table.clone(stats.reports),
	}
end

return Reports
