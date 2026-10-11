--!nonstrict
-- Bundle.luau under Lune (`lune run scripts/test-bundle.luau` from kernel/), 0.5.3 (debug bundles). A fake clock and a
-- tiny scheduler drive the delayed sends; a fake HttpService plays the backend; every snapshot is a stub. Checks: a
-- critical alert returns a bundle id at once (warnings don't) and the bundle follows BUNDLE_DELAY s later with that id;
-- triggers while one waits join it; one bundle per code per 60 s and 10 per server; the body has the contract's shape
-- (summary fields, failure, server, deploy with the swap reports, fallback, the last 10 alerts, players present and
-- left with their client status, the server log, player logs: present clients asked in parallel with a timeout, the
-- kept error lines for the others); the JSON is cut to ~200 KB dropping player logs first; the backend key and the
-- settings' secrets are scrubbed (also JSON-escaped); a 404 stops bundles for good; no answer and 5xx are retried;
-- BindToClose sends one only after a failure in the last 10 minutes (or flushes the waiting one), once.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local passed, failed = 0, 0
local function check(name: string, ok: any, detail: any?)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}{if detail ~= nil then `  ({tostring(detail)})` else ""}`)
	end
end

local clock = 1000
local output = {}
local KEY = "backend-key-0123456789abcdef0123/45678\"9abcdef"
local OTHER = "analytics-token-zyxwvutsrqponmlkjihg"
local BASE = "https://backend.example.test/api"

-- A tiny scheduler: spawned threads run when their time comes; wait(s) yields s seconds of fake time.
local threads = {}
local function spawn(fn, ...)
	table.insert(threads, { co = coroutine.create(fn), at = clock, args = table.pack(...), started = false })
end
local function wait(seconds)
	coroutine.yield(seconds or 0.03)
	return seconds
end
local function tick()
	local index = 1
	while index <= #threads do
		local thread = threads[index]
		if thread.at <= clock then
			local ok, waited
			if thread.started then
				ok, waited = coroutine.resume(thread.co)
			else
				thread.started = true
				ok, waited = coroutine.resume(thread.co, table.unpack(thread.args, 1, thread.args.n))
			end
			assert(ok, waited)
			if coroutine.status(thread.co) == "dead" then
				table.remove(threads, index)
				continue
			end
			thread.at = clock + (waited or 0.03)
		end
		index += 1
	end
end
local function advance(seconds: number)
	local stop = clock + seconds
	repeat
		tick()
		clock += 0.05
	until clock >= stop
	tick()
end

-- The backend: answers with `statuses` (then 202); records every request.
local requests = {}
local statuses = {}
local http = {
	RequestAsync = function(_, request)
		local scripted = table.remove(statuses, 1)
		table.insert(requests, { at = clock, method = request.Method, url = request.Url, headers = request.Headers, raw = request.Body, body = serde.decode("json", request.Body) })
		if scripted == "netfail" then
			error(`HttpError: NetFail (key {KEY})`, 0)
		end
		local code = scripted or 202
		return { Success = code >= 200 and code < 300, StatusCode = code, Body = "{}" }
	end,
}

local Constants = luau.load(fs.readFile("src/shared/Constants.luau"), { debugName = "Constants.luau" })()
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
}, { __index = getfenv(0) })
local Bundle = luau.load(fs.readFile("src/server/Bundle.luau"), { debugName = "Bundle.luau", environment = env })()

-- Stubbed snapshots ----------------------------------------------------------------------------------------------------
local target = { url = BASE, token = KEY, host = "backend.example.test" }
local present = {}
local logsOf = {} -- userId -> { delay, entries } | { delay, fail = true } | nil (never answers)
local asked = {} -- { userId, at }
local serverLines = {}
local function setServerLines(count: number, text: string?)
	table.clear(serverLines)
	for index = 1, count do
		table.insert(serverLines, { i = index, t = 1700000000 + index, kind = if index % 7 == 0 then "error" else "output", text = text or `line {index}` })
	end
end
setServerLines(400)
serverLines[400].text = `the key {KEY} in a log line`
local function player(userId: number, name: string)
	return { UserId = userId, Name = name }
end

local function configure(overrides)
	local base = {
		active = true,
		jobId = "job-bundle-1",
		http = http,
		encode = function(value)
			return serde.encode("json", value)
		end,
		target = function()
			return target
		end,
		secrets = function()
			return { OTHER, "short" }
		end,
		summary = function()
			return { b = "prod", a = "aaaaaaa-111111", s = 5, g = 2 }
		end,
		server = function()
			return { jobId = "job-bundle-1", kernelVersion = Constants.KERNEL_VERSION, note = `settings key {KEY} and {OTHER}`, generation = { name = "aaaaaaa-111111#2", number = 2 } }
		end,
		deploy = function()
			return { appliedSeq = 5, history = { { name = "aaaaaaa-111111#2", seq = 5 } }, failing = { seq = 6, attempts = 1 }, failedHere = { { assetId = 1006, why = "start: boom" } }, busy = false, restoring = false, refusals = {} }
		end,
		fallback = function()
			return { moving = { active = false } }
		end,
		serverLog = function(limit)
			local out = {}
			for index = math.max(1, #serverLines - limit + 1), #serverLines do
				table.insert(out, serverLines[index])
			end
			return out
		end,
		players = function()
			return present
		end,
		playerInfo = function(p)
			return { ping = 40 + p.UserId % 10, client = { generation = "aaaaaaa-111111#2", ok = p.UserId ~= 12 } }
		end,
		clientLogs = function(p, since)
			table.insert(asked, { u = p.UserId, at = clock, since = since })
			local plan = logsOf[p.UserId]
			if not plan then
				wait(1e6) -- never answers (RemoteDebug's own timeout is the module's business; the bundle doesn't wait)
				return {}
			end
			wait(plan.delay or 0.1)
			if plan.fail then
				error("no_reply", 0)
			end
			return plan.entries
		end,
		clock = function()
			return clock
		end,
		time = function()
			return math.floor(1700000000 + clock)
		end,
		wait = wait,
		spawn = spawn,
		warn = function(text)
			table.insert(output, text)
		end,
		print = function(text)
			table.insert(output, text)
		end,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	Bundle.configure(base)
end

local function reset(overrides)
	Bundle._reset()
	table.clear(requests)
	table.clear(statuses)
	table.clear(threads)
	table.clear(asked)
	table.clear(present)
	table.clear(logsOf)
	clock += 10000 -- every rate-limit window of an earlier test is over
	configure(overrides)
end

local function bundles()
	local list = {}
	for _, request in requests do
		if request.url == BASE .. Constants.BUNDLE_PATH then
			table.insert(list, request)
		end
	end
	return list
end

-- 1. A critical alert: an id now, the bundle BUNDLE_DELAY s later with it ------------------------------------------------
reset()
local alice, bob, carol = player(11, "Alice"), player(12, "Bob"), player(13, "Carol")
Bundle.playerAdded(alice)
Bundle.playerAdded(bob)
Bundle.playerAdded(carol)
present = { alice, bob }
-- Carol's client sent two error batches, then she left (her lines and client status stay 10 minutes).
Bundle.fromClient(carol, { e = { { m = "client boom", n = 3 }, { m = `leaky {KEY}` }, { s = "no message" } } })
advance(1)
Bundle.playerRemoving(carol, { generation = "aaaaaaa-111111#2", ok = false, error = "client start failed" })
logsOf[11] = { delay = 1, entries = { { i = 1, t = 1700000001, kind = "output", text = "alice hello" }, { i = 2, t = 1700000002, kind = "error", text = "alice error" } } }
logsOf[12] = { delay = 1, entries = { { i = 9, t = 1700000003, kind = "warning", text = "bob warning" } } }
Bundle.noteSwap({ report = { ok = false, stage = "start", error = "boom", artifactId = "fffffff-666666" }, seq = 6, at = 1700000000 })
check("a warning alert triggers nothing", Bundle.alert("warning", "error_spike", "20 errors", nil) == nil)
local id = Bundle.alert("critical", "deploy_failed", "deploy #6 (fffffff-666666) failed (start): boom", { stage = "start", error = "boom", attempts = 1 })
check("a critical alert returns a bundle id at once (32 lowercase hex)", typeof(id) == "string" and #id == 32 and string.match(id, "^[0-9a-f]+$") ~= nil, id)
check("nothing is sent before BUNDLE_DELAY", #bundles() == 0 and Constants.BUNDLE_DELAY == 3)
-- A start failure right after joins the waiting bundle (one incident, one bundle).
local joined = Bundle.trigger("start_failed", "critical", "fffffff-666666#3 failed to start: boom", { stage = "start", report = { ok = false } })
check("a trigger while one waits joins it (same id)", joined == id)
advance(2.5)
check("still nothing at 2.5 s", #bundles() == 0)
local startedAt = clock
advance(0.8)
-- Both clients answer after 1 s each, in parallel.
advance(1.5)
local list = bundles()
check("one bundle about 3 s after the trigger (plus the client logs)", #list == 1, #list)
local request = list[1]
local body = request and request.body or {}
check("POST <url>/v1/fleet/bundle with the backend key, JSON", request ~= nil and request.method == "POST" and request.headers.Authorization == "Bearer " .. KEY and request.headers["Content-Type"] == "application/json")
check("the bundle carries the alert's id", body.id == id)
check("client logs were asked in parallel (both at once, the bundle waited ~1 s, not 2)", #asked == 2 and asked[1].at == asked[2].at and request ~= nil and request.at - asked[1].at < 1.6 and request.at - startedAt < 2.5)
check("top level: v, id, j, t, k, b, a, s, g, code, level, message, closing", body.v == 1 and body.j == "job-bundle-1" and typeof(body.t) == "number" and body.k == Constants.KERNEL_VERSION and body.b == "prod" and body.a == "aaaaaaa-111111" and body.s == 5 and body.g == 2 and body.code == "deploy_failed" and body.level == "critical" and typeof(body.message) == "string" and body.closing == false)
check("failure: stage, error, the alert's details, and the joined triggers", body.failure ~= nil and body.failure.stage == "start" and body.failure.error == "boom" and body.failure.details.attempts == 1 and body.failure.report ~= nil and #body.failure.triggers == 2 and body.failure.triggers[2].code == "start_failed")
check("server, deploy (with the swap reports), fallback sections", body.server ~= nil and body.server.jobId == "job-bundle-1" and body.deploy ~= nil and body.deploy.appliedSeq == 5 and #body.deploy.history == 1 and body.deploy.failing.seq == 6 and #body.deploy.reports == 1 and body.deploy.reports[1].report.stage == "start" and body.fallback.moving.active == false)
check("alerts: the ones raised here (warning and critical)", #body.alerts == 2 and body.alerts[1].code == "error_spike" and body.alerts[2].code == "deploy_failed" and body.alerts[2].level == "critical" and typeof(body.alerts[2].t) == "number")
local byUser = {}
for _, entry in body.players or {} do
	byUser[entry.u] = entry
end
check("players: present ones with join time, ping and client status", byUser[11] ~= nil and byUser[11].n == "Alice" and typeof(byUser[11].joinedAt) == "number" and byUser[11].leftAt == nil and byUser[11].ping == 41 and byUser[11].client.ok == true and byUser[12].client.ok == false)
check("players: the one who left, with her leave time and client status", byUser[13] ~= nil and byUser[13].n == "Carol" and typeof(byUser[13].leftAt) == "number" and byUser[13].client.error == "client start failed")
check("serverLog: the last 300 lines { i, t, kind, text }", #body.serverLog == 300 and body.serverLog[300].i == 400 and body.serverLog[1].i == 101 and body.serverLog[1].kind == "output" and typeof(body.serverLog[1].t) == "number")
local logs = body.playerLogs or {}
check("playerLogs: each present client's ring, keyed by user id", logs["11"] ~= nil and #logs["11"] == 2 and logs["11"][2].text == "alice error" and logs["11"][2].kind == "error" and logs["12"][1].text == "bob warning")
check("playerLogs: the left player's kept error lines", logs["13"] ~= nil and #logs["13"] == 2 and logs["13"][1].text == "client boom (x3)" and logs["13"][1].kind == "error")
check("the backend key appears nowhere in the posted text (log lines, client lines, sections)", request ~= nil and not string.find(request.raw, KEY, 1, true) and string.find(request.raw, "<key>", 1, true) ~= nil)
local escapedKey = string.gsub(KEY, '[\\"]', function(char)
	return "\\" .. char
end)
check("not even JSON-escaped", request ~= nil and not string.find(request.raw, escapedKey, 1, true) and not string.find(request.raw, (string.gsub(escapedKey, "/", "\\/")), 1, true))
check("the settings' other secrets are scrubbed too", request ~= nil and not string.find(request.raw, OTHER, 1, true))
check("info(): sent, last id and code", Bundle.info().sent == 1 and Bundle.info().lastId == id and Bundle.info().lastCode == "deploy_failed" and Bundle.info().pending == nil)

-- 2. Limits: one per code per 60 s, 10 per server -------------------------------------------------------------------------
local again, why = Bundle.trigger("deploy_failed", "critical", "again", nil)
check("the same code within 60 s: no bundle (and says why)", again == nil and typeof(why) == "string" and string.find(why, "60", 1, true) ~= nil)
local other = Bundle.alert("critical", "health_rollback", "x failed its health check", nil)
check("another code: a new bundle", typeof(other) == "string" and other ~= id)
advance(5)
check("it is sent", #bundles() == 2 and bundles()[2].body.code == "health_rollback")
advance(61)
local later = Bundle.trigger("deploy_failed", "critical", "after the gap", nil)
check("the same code after 60 s: a bundle again", typeof(later) == "string" and later ~= id)
advance(5)
local codes = { "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8" }
local made = 3
for _, code in codes do
	if Bundle.trigger(code, "critical", code, nil) then
		made += 1
	end
	advance(5)
end
local eleventh, whyMax = Bundle.trigger("a9", "critical", "one too many", nil)
check("at most 10 bundles per server", made == 10 and #bundles() == 10 and eleventh == nil and string.find(whyMax or "", "10", 1, true) ~= nil, #bundles())
check("info(): triggered 10, skipped counted", Bundle.info().triggered == 10 and Bundle.info().skipped >= 2)

-- 3. Clients that don't answer: the bundle waits BUNDLE_LOGS_TIMEOUT, then uses the kept error lines ----------------------
reset()
local dave, erin = player(21, "Dave"), player(22, "Erin")
Bundle.playerAdded(dave)
Bundle.playerAdded(erin)
present = { dave, erin }
logsOf[21] = { delay = 0.2, entries = { { i = 1, t = 1, kind = "output", text = "dave ok" } } }
Bundle.fromClient(erin, { e = { { m = "erin's error" } } })
local slow = Bundle.trigger("start_failed", "critical", "boom", nil)
local triggeredAt = clock
advance(Constants.BUNDLE_DELAY + Constants.BUNDLE_LOGS_TIMEOUT + 1)
local slowBundle = bundles()[1]
check("a client that never answers: sent after the timeout (~5 s), not later", slowBundle ~= nil and slowBundle.body.id == slow and slowBundle.at - triggeredAt >= Constants.BUNDLE_DELAY + Constants.BUNDLE_LOGS_TIMEOUT - 0.1 and slowBundle.at - triggeredAt <= Constants.BUNDLE_DELAY + Constants.BUNDLE_LOGS_TIMEOUT + 0.3)
check("its kept error lines stand in; the answering client's ring is there", slowBundle ~= nil and slowBundle.body.playerLogs["22"][1].text == "erin's error" and slowBundle.body.playerLogs["21"][1].text == "dave ok")
-- At most 20 clients are asked.
reset()
for userId = 100, 129 do
	local p = player(userId, `P{userId}`)
	Bundle.playerAdded(p)
	table.insert(present, p)
	logsOf[userId] = { delay = 0.1, entries = { { i = 1, t = 1, kind = "output", text = `hi {userId}` } } }
end
Bundle.trigger("players_moved", "critical", "moving", nil)
advance(5)
check("at most 20 clients are asked; all 30 players are listed", #asked == 20 and bundles()[1] ~= nil and #bundles()[1].body.players == 30)

-- 4. Trimming: ~200 KB, player logs first ------------------------------------------------------------------------------
reset()
local big = string.rep("x", 1500)
for userId = 200, 205 do
	local p = player(userId, `Big{userId}`)
	Bundle.playerAdded(p)
	table.insert(present, p)
	local entries = {}
	for index = 1, 150 do
		table.insert(entries, { i = index, t = index, kind = "output", text = big })
	end
	logsOf[userId] = { delay = 0.1, entries = entries }
end
setServerLines(300, string.rep("s", 200))
Bundle.trigger("deploy_failed", "critical", "big", nil)
advance(5)
local trimmed = bundles()[1]
check("a bundle over 200 KB is cut to at most 200 KB", trimmed ~= nil and #trimmed.raw <= Constants.BUNDLE_BYTES and Constants.BUNDLE_BYTES == 200000, trimmed and #trimmed.raw)
check("player logs went first (halved, newest kept); the server log stays whole", trimmed ~= nil and table.find(trimmed.body.server.trimmed, "playerLogs") ~= nil and table.find(trimmed.body.server.trimmed, "serverLog") == nil and #trimmed.body.serverLog == 300)
local someLog = trimmed and trimmed.body.playerLogs["200"]
check("the newest client lines are the ones kept", someLog ~= nil and #someLog > 0 and #someLog < 150 and someLog[#someLog].t == 150)
-- Order: with a tiny limit, player logs go, then the server log, then the deploy history.
local sample = Bundle.build({ id = string.rep("a", 32), code = "manual", level = "info", message = "m", failure = {}, triggers = {} }, false, 0)
sample.playerLogs = { ["1"] = { { t = 1, kind = "output", text = string.rep("p", 3000) } } }
local text = Bundle.encode(sample, 6000)
check("Bundle.encode: player logs, then the server log, then deploy history", text ~= nil and #text <= 6000 and sample.server.trimmed[1] == "playerLogs" and sample.server.trimmed[2] == "serverLog", sample.server.trimmed and table.concat(sample.server.trimmed, ","))
setServerLines(400)

-- 5. Scrub ------------------------------------------------------------------------------------------------------------
do
	local secret = 'abc/def"ghi\\jkl-12345'
	local encoded = serde.encode("json", { a = `x {secret} y`, b = secret })
	local scrubbed, count = Bundle.scrub(encoded, { secret })
	check("Bundle.scrub: plain and JSON-escaped copies are replaced", not string.find(scrubbed, "ghi", 1, true) and count >= 2 and serde.decode("json", scrubbed).b == "<key>", scrubbed)
end

-- 6. Retries and the 404 stop ---------------------------------------------------------------------------------------------
reset()
statuses = { "netfail", 503 }
local retried = Bundle.trigger("deploy_failed", "critical", "retry me", nil)
advance(Constants.BUNDLE_DELAY + 10)
local tries = bundles()
check("no answer, then 503: retried until it goes through (same id)", #tries == 3 and tries[3].body.id == retried and Bundle.info().sent == 1)
check("the failure lines never carry the key", (function()
	for _, line in output do
		if string.find(line, KEY, 1, true) then
			return false
		end
	end
	return true
end)())
reset()
statuses = { 404 }
Bundle.trigger("deploy_failed", "critical", "old backend", nil)
advance(Constants.BUNDLE_DELAY + 3)
local after404, why404 = Bundle.trigger("health_rollback", "critical", "after the 404", nil)
advance(Constants.BUNDLE_DELAY + 3)
check("a 404 stops bundles for the server's lifetime", #bundles() == 1 and after404 == nil and string.find(why404 or "", "404", 1, true) ~= nil and Bundle.info().stopped == true and Bundle.info().enabled == false)
local closedAfter404 = nil
spawn(function()
	closedAfter404 = Bundle.closing(10)
end)
advance(1)
check("... and nothing at close either", closedAfter404 == false and #bundles() == 1)

-- 7. BindToClose: only after a failure in the last 10 minutes ---------------------------------------------------------------
local function close(): boolean?
	local result = nil
	spawn(function()
		result = Bundle.closing(10)
	end)
	advance(3)
	return result
end
reset()
check("a clean close: no bundle", close() == false and #bundles() == 0)
reset()
Bundle.trigger("manual", "info", "/tt bundle", nil)
advance(Constants.BUNDLE_DELAY + 1)
check("a /tt bundle is sent (code manual) ...", #bundles() == 1 and bundles()[1].body.code == "manual" and bundles()[1].body.level == "info")
check("... but is not a failure: the close sends nothing", close() == false and #bundles() == 1)
reset()
Bundle.trigger("deploy_failed", "critical", "boom", nil)
advance(Constants.BUNDLE_DELAY + 1)
advance(601)
check("a failure 10+ minutes before the close: no closing bundle", close() == false and #bundles() == 1)
reset()
Bundle.trigger("deploy_failed", "critical", "deploy #9 failed", nil)
advance(Constants.BUNDLE_DELAY + 1)
advance(120)
local sentClose = close()
local closingBundle = bundles()[2]
check("a close 2 minutes after a failure: one closing bundle (code closing, closing = true)", sentClose == true and #bundles() == 2 and closingBundle.body.code == "closing" and closingBundle.body.closing == true and closingBundle.body.id ~= bundles()[1].body.id and string.find(closingBundle.body.message, "deploy_failed", 1, true) ~= nil)
check("only one closing bundle; no triggers after the close", close() == false and Bundle.trigger("x", "critical", "late", nil) == nil and #bundles() == 2)
reset()
local waiting = Bundle.alert("critical", "no_trusted_head", "branch prod: no trusted prod head", nil)
local closeStart = clock
local flushed = nil
spawn(function()
	flushed = Bundle.closing(10)
end)
advance(1)
check("the close flushes the waiting bundle at once (its id, closing = true)", flushed == true and #bundles() == 1 and bundles()[1].body.id == waiting and bundles()[1].body.closing == true and bundles()[1].at - closeStart < 0.5)
advance(Constants.BUNDLE_DELAY + 1)
check("... and its timer sends nothing more", #bundles() == 1)

-- 8. Left players are forgotten after 10 minutes; nothing without a backend or outside a live server ----------------------
reset()
local frank = player(31, "Frank")
Bundle.playerAdded(frank)
Bundle.fromClient(frank, { e = { { m = "frank's error" } } })
Bundle.playerRemoving(frank, nil)
advance(601)
Bundle.trigger("deploy_failed", "critical", "x", nil)
advance(Constants.BUNDLE_DELAY + 1)
check("a player who left over 10 minutes ago is gone (and his lines)", bundles()[1] ~= nil and #bundles()[1].body.players == 0 and bundles()[1].body.playerLogs["31"] == nil)
reset({ target = function()
	return nil
end })
local noTarget, whyNoTarget = Bundle.alert("critical", "deploy_failed", "x", nil)
advance(Constants.BUNDLE_DELAY + 1)
check("no backend in the settings: no id, nothing sent", noTarget == nil and whyNoTarget == nil and #requests == 0)
reset({ active = false })
local studio, whyStudio = Bundle.trigger("deploy_failed", "critical", "x", nil)
advance(Constants.BUNDLE_DELAY + 1)
check("not a live server: nothing", studio == nil and string.find(whyStudio or "", "Studio", 1, true) ~= nil and #requests == 0)

print(`bundle: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
