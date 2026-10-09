--!nonstrict
-- Fleet.luau's sender under Lune (`lune run scripts/test-fleet.luau` from kernel/), 0.3.9 (problem 23, "NetFail
-- errors"): a fake clock drives the sender thread, a fake HttpService answers. Checks: retries are jittered; after a
-- request's retries all failed the sender backs off exponentially (30 s doubling, at most 300 s, +-25%); a 401 holds it
-- off ~300 s; one success resets everything and says so once; at most one warning line a minute, with the reason;
-- Fleet.info() has `failures` (failed requests in a row) and `retryIn`; the token is never in a line. 0.4.2: a "seq"
-- heartbeat goes ahead of the queued reports.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local passed, failed = 0, 0
local function check(name: string, ok: boolean, detail: any?)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}{if detail ~= nil then `  ({tostring(detail)})` else ""}`)
	end
end

local clock = 1000
local output = {}
local requests = {} -- { at, path }
local answer = "netfail" -- "netfail" | "dns" | "ok" | number (an HTTP status)
local TOKEN = "fleet-token-0123456789"

local Constants = luau.load(fs.readFile("src/shared/Constants.luau"), { debugName = "Constants.luau" })()
local http = {
	RequestAsync = function(_, request)
		table.insert(requests, { at = clock, path = string.sub(request.Url, #"https://fleet.example.test" + 1), url = request.Url, auth = request.Headers.Authorization, body = request.Body })
		if answer == "netfail" then
			error("HttpError: NetFail", 0)
		elseif answer == "dns" then
			error("HttpError: DnsResolve", 0)
		elseif answer == "ok" then
			return { Success = true, StatusCode = 200 }
		end
		return { Success = false, StatusCode = answer }
	end,
}

-- The sender thread: task.spawn keeps it, task.wait yields to the test, which advances the clock.
local sender = nil
local fakeTask = {
	spawn = function(fn, ...)
		sender = coroutine.create(fn)
		coroutine.resume(sender, ...)
		return sender
	end,
	wait = function(seconds)
		coroutine.yield(seconds or 0.03)
		return seconds
	end,
}
local game = {
	GetService = function(_, name)
		if name == "ReplicatedStorage" then
			return { WaitForChild = function()
				return { WaitForChild = function()
					return "Constants"
				end }
			end }
		end
		error(`unexpected service {name}`)
	end,
}
local env = setmetatable({
	game = game,
	require = function(target)
		if target == "Constants" then
			return Constants
		end
		error(`unexpected require {tostring(target)}`)
	end,
	typeof = function(value)
		return type(value)
	end,
	task = fakeTask,
	os = { clock = function()
		return clock
	end, time = function()
		return math.floor(clock)
	end },
}, { __index = getfenv(0) })
local Fleet = luau.load(fs.readFile("src/server/Fleet.luau"), { debugName = "Fleet.luau", environment = env })()

Fleet.configure({
	http = http,
	jobId = "job-1",
	active = true,
	readSettings = function()
		return true, { url = "https://fleet.example.test", token = TOKEN }
	end,
	status = function()
		return { sv = 2, t = "public" }
	end,
	encode = function(value)
		return serde.encode("json", value)
	end,
	print = function(...)
		table.insert(output, table.concat({ ... }, " "))
	end,
	warn = function(...)
		table.insert(output, "warn: " .. table.concat({ ... }, " "))
	end,
})

-- Runs the sender for `seconds` of fake time (each yield is one task.wait).
local function advance(seconds: number)
	local stop = clock + seconds
	while clock < stop do
		local ok, waited = coroutine.resume(sender)
		assert(ok, waited)
		clock += waited or 0.25
	end
end
local function heartbeatsBetween(from: number, to: number): { number }
	local list = {}
	for _, request in requests do
		if request.path == "/v1/fleet/heartbeat" and request.at >= from and request.at < to then
			table.insert(list, request.at)
		end
	end
	return list
end
local function warnings(fragment: string?): number
	local count = 0
	for _, line in output do
		if string.sub(line, 1, 6) == "warn: " and (fragment == nil or string.find(line, fragment, 1, true)) then
			count += 1
		end
	end
	return count
end
local function said(fragment: string): number
	local count = 0
	for _, line in output do
		if string.find(line, fragment, 1, true) then
			count += 1
		end
	end
	return count
end
-- Groups heartbeat times into cycles (a request and its retries: gaps of at most ~12 s).
local function cycles(times: { number }): { number }
	local starts = {}
	local last = nil
	for _, at in times do
		if last == nil or at - last > 13 then
			table.insert(starts, at)
		end
		last = at
	end
	return starts
end

Fleet.start()
check("the first heartbeat goes out at once", #requests == 1 and requests[1].path == "/v1/fleet/heartbeat", #requests)

-- 1. A dead quick tunnel: every request fails with NetFail, for 10 minutes.
local outageStart = clock - 0.25
advance(600)
local times = heartbeatsBetween(outageStart, clock)
local starts = cycles(times)
check("NetFail for 10 min: far fewer requests than 4 per 30 s (backoff)", #times <= 24 and #times >= 12, #times)
local gaps = {}
for index = 2, #starts do
	gaps[index - 1] = starts[index] - starts[index - 1]
end
local expected = { 30, 60, 120, 240, 300 }
local growing = #gaps >= 4
for index, gap in gaps do
	-- the next cycle starts after the last retry (about 13 s into a cycle) plus the jittered backoff
	local low, high = 13 + expected[index] * 0.75 - 1, 13 + expected[index] * 1.25 + 1
	if gap < low or gap > high then
		growing = false
	end
end
check("cycles back off: 30 s, 60 s, 120 s, 240 s (+-25%, after the retries)", growing, table.concat(gaps, ", "))
local first, second = times[1], times[2]
check("the first retry is jittered around 1 s (0.75-1.25 s)", second - first >= 0.5 and second - first <= 1.5, second - first)
local info = Fleet.info()
check("info: failures = failed requests in a row; retryIn while backing off", info.failures == #times and typeof(info.retryIn) == "number" and info.retryIn > 0 and info.retryIn <= 376, `{info.failures} {info.retryIn}`)
check("at most one warning line a minute, with the reason (NetFail: the connection broke mid-request)", warnings() <= 11 and warnings() >= 1 and warnings("the connection broke mid-request") == warnings(), warnings())
check("the token never appears in a line", said(TOKEN) == 0)

-- 2. The tunnel comes back: the next try works, one "work again" line, the counters reset, heartbeats every ~30 s.
answer = "ok"
local before = #requests
advance(400)
check("after the outage the next try works, one 'heartbeats work again' line", said("heartbeats work again") == 1 and #requests > before)
info = Fleet.info()
check("info: failures 0 and no retryIn after a success", info.failures == 0 and info.retryIn == nil, `{info.failures} {info.retryIn}`)
local okTimes = heartbeatsBetween(clock - 200, clock)
check("then a heartbeat about every 30 s again", #okTimes >= 6 and #okTimes <= 8, #okTimes)

-- 3. A stale trycloudflare URL (DnsResolve): the hint says so.
answer = "dns"
advance(70)
check("DnsResolve: the line says a stale trycloudflare URL", said("a stale trycloudflare URL") >= 1)
answer = "ok"
advance(400)

-- 4. A 401 (the wrong token): no retries, held off about 5 minutes.
answer = 401
local holdStart = clock
advance(31)
local held = heartbeatsBetween(holdStart, clock)
check("401: one request, no retries", #held == 1, #held)
info = Fleet.info()
check("401: held off about 5 minutes (225-375 s)", typeof(info.retryIn) == "number" and info.retryIn >= 225 - 31 and info.retryIn <= 375, info.retryIn)
check("401: the line says the key is wrong (settings.backend.key)", said("the backend key is wrong (settings.backend.key") >= 1)
advance(180)
check("401: nothing more within 3 minutes", #heartbeatsBetween(holdStart, clock) == 1)
answer = "ok"
advance(240)
check("401 fixed: heartbeats resume after the hold", #heartbeatsBetween(holdStart + 200, clock) >= 1 and Fleet.info().failures == 0)

-- 5. Two servers that fail together don't retry together (jitter): two senders' backoffs differ.
local function backoffSample(): number
	answer = "netfail"
	local from = clock
	advance(120)
	local list = cycles(heartbeatsBetween(from, clock))
	answer = "ok"
	advance(400)
	return if #list >= 2 then list[2] - list[1] else -1
end
local a, b, c = backoffSample(), backoffSample(), backoffSample()
check("the backoff is jittered (three outages, not all the same wait)", a > 0 and b > 0 and c > 0 and not (a == b and b == c), `{a} {b} {c}`)

-- 6. 0.4.0 (plans/21 C): settings.backend = { url, key } first; settings.fleet = { url, token } while backend is missing;
-- Fleet.target() hands the same URL and key to the error reports; heartbeats carry `bu`.
answer = "ok"
local BACKEND_KEY = "backend-key-0123456789abcdef"
Fleet.configure({
	readSettings = function()
		return true, { url = "https://backend.example.test/", key = BACKEND_KEY, analytics = { flushSeconds = 20 } }, "backend"
	end,
	heartbeatExtra = function()
		return { bu = { p = 3, h = { r = 2, l = 500 } }, j = "not-overwritten" }
	end,
})
Fleet.refreshSettings()
info = Fleet.info()
local target = Fleet.target()
check("backend { url, key }: taken, source backend, the trailing slash dropped", info.enabled and info.source == "backend" and target and target.url == "https://backend.example.test" and target.token == BACKEND_KEY and target.host == "backend.example.test")
check("a new host is said once (no key)", said("backend: backend.example.test (settings.backend)") == 1 and said(BACKEND_KEY) == 0)
local mark = #requests
Fleet.heartbeat()
advance(1)
local beat = requests[mark + 1]
local decoded = beat and serde.decode("json", beat.body)
check("heartbeats go to <url>/v1/fleet/heartbeat with the key", beat ~= nil and beat.url == "https://backend.example.test/v1/fleet/heartbeat" and beat.auth == "Bearer " .. BACKEND_KEY)
check("heartbeats carry the budget summary `bu`; extras never overwrite the status (j stays the JobId)", decoded and decoded.bu and decoded.bu.p == 3 and decoded.j == "job-1")
Fleet.configure({
	readSettings = function()
		return true, { url = "https://fleet.example.test", token = TOKEN }, "fleet"
	end,
})
Fleet.refreshSettings()
check("fleet { url, token } (old settings): taken, source fleet", Fleet.info().source == "fleet" and Fleet.target().token == TOKEN)

-- 7. 0.4.2: a "seq" heartbeat (the applied seq moved) goes before the queued report, so the backend's row has the new
-- `q` when `deploy --wait` sees the report; any other heartbeat still waits behind the queue.
advance(40)
local function order(): { string }
	local list = {}
	for index = mark + 1, #requests do
		table.insert(list, requests[index].path)
	end
	return list
end
mark = #requests
Fleet.report({ s = 65, r = "swapped" })
Fleet.heartbeat("seq")
advance(2)
local sent = order()
check("seq heartbeat: sent ahead of the queued report", sent[1] == "/v1/fleet/heartbeat" and sent[2] == "/v1/fleet/report", table.concat(sent, ", "))
advance(40)
mark = #requests
Fleet.report({ s = 66, r = "swapped" })
Fleet.heartbeat("swap")
advance(2)
sent = order()
check("other heartbeats: the queue (reports, alerts) first, as before", sent[1] == "/v1/fleet/report" and sent[2] == "/v1/fleet/heartbeat", table.concat(sent, ", "))
Fleet.configure({
	readSettings = function()
		return true, { url = "http://insecure.example.test", key = BACKEND_KEY }, "backend"
	end,
})
Fleet.refreshSettings()
check("a non-https backend is refused (no target)", Fleet.info().settings == "invalid" and Fleet.target() == nil and said("settings.backend) ignored") == 1)

print(`fleet: {passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
