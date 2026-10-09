--!nonstrict
-- RemoteDebug.luau under Lune (`lune run scripts/test-remote-debug.luau` from kernel/), 0.5.0 (plans/25). A fake clock
-- and a tiny scheduler drive the session thread; a fake HttpService plays the backend. Checks: no request until a
-- heartbeat reply says rd = 1; the poll goes only to the settings' backend with its key and the JobId; commands run on
-- the allow-list only (no write op), owners only (a Roblox non-owner is refused, the admin token counts as an owner),
-- rate-limited, expired ones refused; framework ops go to the generation's handler (none: not supported); answers are
-- plain JSON, scrubbed of every secret (whole, JSON-escaped, or a 12+ character piece), refused when too large; the
-- session ends when the backend says "not watched", after 3 failed polls, or at once (and holds off) on a 401; client
-- logs come only from the asked player, once, cleaned; the key never appears in any line or answer. 0.5.1 (instant wake):
-- a wake message for this JobId starts the poll within a tick, other JobIds and malformed wakes do nothing, one wake per
-- RD_WAKE_GAP s, a forged wake costs one poll, no backend (or not a live server) means no poll.
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
local KEY = "backend-key-0123456789abcdef0123456789abcdef"
local ANALYTICS_TOKEN = "analytics-token-zyxwvutsrqponmlkjihg"
local BASE = "https://backend.example.test"

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

-- The backend: answers polls from `queue` (a list of { watch, commands } or a status code); records every request.
local requests = {}
local pollAnswers = {}
local resultsStatus = 202
local http = {
	RequestAsync = function(_, request)
		local body = if request.Body then serde.decode("json", request.Body) else nil
		table.insert(requests, { at = clock, method = request.Method, url = request.Url, headers = request.Headers, body = body, raw = request.Body })
		if request.Method == "GET" then
			local answer = table.remove(pollAnswers, 1) or { watch = true, commands = {} }
			if answer == "netfail" then
				error("HttpError: NetFail", 0)
			elseif typeof(answer) == "number" then
				return { Success = false, StatusCode = answer, Body = "" }
			end
			return { Success = true, StatusCode = 200, Body = serde.encode("json", answer) }
		end
		return { Success = resultsStatus < 300, StatusCode = resultsStatus, Body = "{}" }
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
		if type(value) == "table" and value.__instance then
			return "Instance"
		end
		return type(value)
	end,
}, { __index = getfenv(0) })
local RemoteDebug = luau.load(fs.readFile("src/server/RemoteDebug.luau"), { debugName = "RemoteDebug.luau", environment = env })()

local OWNER, STRANGER = 1001, 2002
local target = { url = BASE, token = KEY, host = "backend.example.test" }
local frameworkHandler = nil
local frameworkCalls = {}
local sent = {} -- kernelSend calls
local playerA = { Name = "Rider", UserId = 77 }
local playerB = { Name = "Other", UserId = 88 }
local settingsCopy = {
	defaultBranch = "prod",
	backend = { url = BASE, key = KEY, analytics = { flushSeconds = 10 } },
	fleet = { url = "https://old.example.test", token = "old-fleet-token-123456789" },
	analytics = { events = "https://events.example.test", token = ANALYTICS_TOKEN },
	game = { webhookSecret = "game-webhook-secret-abcdef", motd = "hello world, this is not a secret" },
	access = { members = { ["1001"] = "owner" } },
}

RemoteDebug.configure({
	http = http,
	jobId = "job-rd-1",
	active = true,
	target = function()
		return target
	end,
	encode = function(value)
		return serde.encode("json", value)
	end,
	decode = function(text)
		return serde.decode("json", text)
	end,
	secrets = function()
		return RemoteDebug.collectSecrets(settingsCopy, {})
	end,
	ops = {
		status = function(_, caller)
			return { branch = "prod", caller = caller }
		end,
		logs = function(args)
			return { entries = { { i = 1, t = 1, kind = "output", text = `key is {KEY}` } }, since = args.since }
		end,
		budget = function()
			return { big = string.rep("x", 250000) }
		end,
		errors = function()
			error(`failed while holding {KEY}`, 0)
		end,
		players = function()
			return { nan = 0 / 0, inf = math.huge, fn = print, list = { 1, 2, 3 }, mixed = { 1, 2, x = 3 } }
		end,
		builds = function()
			local loop = {}
			loop.self = loop
			return loop
		end,
	},
	framework = function()
		return frameworkHandler
	end,
	isOwner = function(userId)
		return userId == OWNER
	end,
	spawn = spawn,
	kernelSend = function(player, channel, payload)
		table.insert(sent, { player = player, channel = channel, payload = payload })
	end,
	clock = function()
		return clock
	end,
	time = function()
		return math.floor(clock)
	end,
	wait = wait,
	random = function()
		return 0.5
	end,
	print = function(...)
		table.insert(output, table.concat({ ... }, " "))
	end,
	warn = function(...)
		table.insert(output, "warn: " .. table.concat({ ... }, " "))
	end,
})

local function answerOf(id: string)
	for index = #requests, 1, -1 do
		local request = requests[index]
		if request.method == "POST" and request.body and request.body.results then
			for _, result in request.body.results do
				if result.id == id then
					return result, request
				end
			end
		end
	end
	return nil
end
local function polls(): number
	local n = 0
	for _, request in requests do
		if request.method == "GET" then
			n += 1
		end
	end
	return n
end
local function cmd(id: string, op: string, args: any?, by: any?)
	return { id = id, op = op, args = args or {}, by = by or { kind = "token" }, exp = (clock + 20) * 1000 }
end

-- 1. Secrets ----------------------------------------------------------------------------------------------------------
do
	local secrets = RemoteDebug.collectSecrets(settingsCopy, {})
	local found = {}
	for _, secret in secrets do
		found[secret] = true
	end
	check("collectSecrets: backend.key, fleet.token, analytics.token and the game's *Secret fields", found[KEY] and found[ANALYTICS_TOKEN] and found["old-fleet-token-123456789"] and found["game-webhook-secret-abcdef"])
	check("collectSecrets: URLs, branch names and plain game values are not secrets", not found[BASE] and not found["prod"] and not found["hello world, this is not a secret"] and not found["owner"])
	local text, count = RemoteDebug.scrub(`a {KEY} b "{string.sub(KEY, 1, 20)}..." c {string.sub(KEY, 1, 11)}`, { KEY })
	check("scrub: the whole key and a 20-character piece go, an 11-character piece stays", count == 2 and not string.find(text, string.sub(KEY, 1, 12), 1, true) and string.find(text, string.sub(KEY, 1, 11), 1, true) ~= nil, text)
	local escaped = 'x/y"z-0123456789abcdef'
	local jsonText = serde.encode("json", { v = escaped })
	local cleaned, n = RemoteDebug.scrub(jsonText, { escaped })
	check("scrub: the JSON-escaped form of a secret goes too", n >= 1 and not string.find(cleaned, "0123456789abcdef", 1, true), cleaned)
	local _, none = RemoteDebug.scrub("short abc", { "abc", "1234567" })
	check("scrub: secrets under 8 characters are not looked for", none == 0)
end

-- 2. Plain data -------------------------------------------------------------------------------------------------------
do
	local loop = { name = "x" }
	loop.self = loop
	local plain = RemoteDebug.toPlain({ nan = 0 / 0, inf = -math.huge, n = 5, loop = loop, f = print, arr = { "a", "b" }, [7] = "seven", inst = { __instance = true, GetFullName = function()
		return "Workspace.Part"
	end } })
	check("toPlain: NaN and infinities dropped, cycles named, functions named, numeric keys as strings, Instances as paths", plain.nan == nil and plain.inf == nil and plain.n == 5 and plain.loop.self == "<cycle>" and plain.f == "function" and plain.arr[2] == "b" and plain["7"] == "seven" and plain.inst == "Workspace.Part")
	check("toPlain: the result encodes as JSON", pcall(serde.encode, "json", plain))
end

-- 3. Running commands -------------------------------------------------------------------------------------------------
do
	local a = RemoteDebug.run(cmd("c1", "status"))
	check("run: a kernel op by the admin token (an owner via the admin token)", a.ok == true and serde.decode("json", a.json).caller.via == "admin token" and serde.decode("json", a.json).caller.owner == true)
	local b = RemoteDebug.run(cmd("c2", "status", nil, { kind = "roblox", userId = OWNER }))
	check("run: a Roblox owner", b.ok == true and serde.decode("json", b.json).caller.userId == OWNER)
	local c = RemoteDebug.run(cmd("c3", "status", nil, { kind = "roblox", userId = STRANGER }))
	check("run: a Roblox user who isn't an owner is refused", c.ok == false and c.error == "owners_only")
	local d = RemoteDebug.run(cmd("c4", "status", nil, { kind = "admin" }))
	check("run: an unknown caller kind is refused", d.ok == false and d.error == "owners_only")
	for index, op in { "kick", "ban", "reload", "rollback", "pin", "switch", "run_luau", "dex.set", "explorer.destroy", "__index" } do
		local refused = RemoteDebug.run(cmd(`w{index}`, op))
		check(`run: no write op exists ({op})`, refused.ok == false and string.find(refused.error, "op_not_allowed", 1, true) ~= nil)
	end
	local stale = cmd("c5", "status")
	stale.exp = (clock - 60) * 1000
	check("run: an expired command is refused", RemoteDebug.run(stale).error == "expired")
	check("run: a command without a usable id gets no answer", RemoteDebug.run({ id = "bad id!", op = "status" }) == nil and RemoteDebug.run({ op = "status" }) == nil)
	local logs = RemoteDebug.run(cmd("c6", "logs", { since = 4 }))
	check("run: the key is scrubbed out of an answer, and counted", logs.ok and not string.find(logs.json, KEY, 1, true) and string.find(logs.json, "<redacted>", 1, true) ~= nil and logs.redacted == 1 and serde.decode("json", logs.json).since == 4)
	local err = RemoteDebug.run(cmd("c7", "errors"))
	check("run: an op's error text is scrubbed too", err.ok == false and not string.find(err.error, KEY, 1, true) and string.find(err.error, "<redacted>", 1, true) ~= nil)
	local big = RemoteDebug.run(cmd("c8", "budget"))
	check("run: an answer over 200 KB is refused, not cut", big.ok == false and string.find(big.error, "too large", 1, true) ~= nil and big.json == nil)
	local odd = RemoteDebug.run(cmd("c9", "players"))
	check("run: non-JSON values become plain data", odd.ok and serde.decode("json", odd.json).fn == "function" and serde.decode("json", odd.json).nan == nil)
	local cyc = RemoteDebug.run(cmd("c10", "builds"))
	check("run: a cycle doesn't break the answer", cyc.ok and serde.decode("json", cyc.json).self == "<cycle>")
	clock += 60 -- the burst is spent: the rate refills
	local none = RemoteDebug.run(cmd("c11", "state", { queries = {} }))
	check("run: a framework op without the generation's hook says not supported", none.ok == false and string.find(none.error, "not_supported", 1, true) ~= nil)
	frameworkHandler = function(op, args, caller)
		table.insert(frameworkCalls, { op = op, args = args, caller = caller })
		if op == "dex.props" then
			return { props = { { name = "Value", text = ANALYTICS_TOKEN } } }
		end
		return { op = op }
	end
	local fw = RemoteDebug.run(cmd("c12", "dex.props", { id = 3 }, { kind = "roblox", userId = OWNER }))
	check("run: framework ops go to the running generation's handler with the owner caller", fw.ok and frameworkCalls[1].op == "dex.props" and frameworkCalls[1].args.id == 3 and frameworkCalls[1].caller.userId == OWNER and frameworkCalls[1].caller.owner == true)
	check("run: secrets in a framework answer are scrubbed", not string.find(fw.json, ANALYTICS_TOKEN, 1, true) and fw.redacted == 1)
	-- Rate: the burst (10) is spent by now; one more is refused until tokens come back.
	local refusedRate = false
	for index = 1, 12 do
		local r = RemoteDebug.run(cmd(`r{index}`, "status"))
		refusedRate = refusedRate or (r.ok == false and string.find(r.error, "rate_limited", 1, true) ~= nil)
	end
	check("run: at most RD_COMMANDS_PER_MINUTE commands (burst RD_COMMANDS_BURST)", refusedRate)
	clock += 60
	check("run: the rate refills", RemoteDebug.run(cmd("r-after", "status")).ok == true)
end

-- 4. The session --------------------------------------------------------------------------------------------------------
RemoteDebug._reset()
do
	advance(5)
	check("session: nothing is requested before a heartbeat reply says rd", #requests == 0)
	RemoteDebug.wake({ ok = true })
	advance(2)
	check("session: a reply without rd starts nothing", #requests == 0 and RemoteDebug.info().state == "off")
	table.insert(pollAnswers, { watch = true, commands = { cmd("s1", "status", nil, { kind = "roblox", userId = OWNER }), cmd("s2", "kick") } })
	RemoteDebug.wake({ ok = true, rd = 1 })
	advance(1)
	local first = requests[1]
	check("session: rd = 1 starts a long-poll to the settings' backend", first ~= nil and first.method == "GET" and first.url == BASE .. "/v1/fleet/commands?wait=8")
	check("session: the poll carries the backend key and the JobId", first and first.headers.Authorization == "Bearer " .. KEY and first.headers["X-TT-Job"] == "job-rd-1")
	local s1, post = answerOf("s1")
	local s2 = answerOf("s2")
	check("session: answers go to POST <url>/v1/fleet/results with j", s1 ~= nil and s1.ok == true and post.url == BASE .. "/v1/fleet/results" and post.body.j == "job-rd-1" and post.headers.Authorization == "Bearer " .. KEY)
	check("session: a write op in a poll is refused, the rest answered", s2 ~= nil and s2.ok == false)
	check("session: status().remoteDebug says polling", RemoteDebug.info().state == "polling" and RemoteDebug.info().commands >= 1)
	-- Empty answers: at least RD_POLL_GAP between polls.
	local before = polls()
	advance(10)
	local gap = polls() - before
	check("session: an empty poll waits RD_POLL_GAP before the next (no tight loop)", gap >= 3 and gap <= 6, gap)
	-- The backend says not watched: the session ends at once.
	table.insert(pollAnswers, { watch = false, commands = {} })
	advance(3)
	local after = polls()
	advance(10)
	check("session: 'not watched' ends the session; no more requests", polls() == after and RemoteDebug.info().state == "off")
end

-- 5. Failures and a refused key ------------------------------------------------------------------------------------------
do
	table.clear(requests)
	table.insert(pollAnswers, "netfail")
	table.insert(pollAnswers, 503)
	table.insert(pollAnswers, "netfail")
	RemoteDebug.wake({ rd = 1 })
	advance(30)
	check("session: 3 failed polls in a row end it", polls() == 3 and RemoteDebug.info().state == "off")
	table.clear(requests)
	table.insert(pollAnswers, 401)
	RemoteDebug.wake({ rd = 1 })
	advance(2)
	check("session: a 401 ends it and holds new sessions off", polls() == 1 and RemoteDebug.info().state == "held")
	RemoteDebug.wake({ rd = 1 })
	advance(5)
	check("session: wake is ignored while held", polls() == 1)
	clock += (Constants.RD_AUTH_HOLD or 300) + 1
	table.insert(pollAnswers, { watch = false, commands = {} })
	RemoteDebug.wake({ rd = 1 })
	advance(2)
	check("session: after the hold a watched heartbeat starts one again", polls() == 2)
	-- No backend in the settings: nothing.
	table.clear(requests)
	local saved = target
	target = nil
	RemoteDebug.wake({ rd = 1 })
	advance(3)
	check("session: no backend in the signed settings, no poll", #requests == 0)
	target = saved
end

-- 6. A slow op times out; the others still answer ------------------------------------------------------------------------------
do
	table.clear(requests)
	frameworkHandler = function(op)
		if op == "assets" then
			wait(30)
		end
		return { op = op }
	end
	clock += 120
	table.insert(pollAnswers, { watch = true, commands = { cmd("t1", "assets"), cmd("t2", "modules") } })
	table.insert(pollAnswers, { watch = false, commands = {} })
	RemoteDebug.wake({ rd = 1 })
	advance(15)
	local t1, t2 = answerOf("t1"), answerOf("t2")
	check("session: an op over RD_OP_TIMEOUT answers timeout; the other one answers", t1 ~= nil and t1.ok == false and string.find(t1.error, "timeout", 1, true) ~= nil and t2 ~= nil and t2.ok == true)
end

-- 7. Client logs ---------------------------------------------------------------------------------------------------------
do
	local result = nil
	spawn(function()
		local ok, value = pcall(RemoteDebug.clientLogs, playerA, 5)
		result = { ok = ok, value = value }
	end)
	advance(0.2)
	local request = sent[#sent]
	check("client logs: the asked player gets { id, since } on __tt/rdlogs", request ~= nil and request.player == playerA and request.channel == "__tt/rdlogs" and request.payload.since == 5)
	local id = request.payload.id
	RemoteDebug.onClientLogs(playerB, { id = id, logs = { { i = 1, t = 1, kind = "output", text = "forged" } } })
	advance(0.2)
	check("client logs: another player's answer is ignored", result == nil)
	local many = {}
	for index = 1, 300 do
		table.insert(many, { i = index, t = 1, kind = if index == 300 then "weird" else "output", text = string.rep("y", 700) })
	end
	table.insert(many, "junk")
	RemoteDebug.onClientLogs(playerA, { id = id, logs = many })
	advance(0.2)
	local entries = result and result.value
	check("client logs: the asked player's answer, cleaned (cut texts, unknown kinds, junk dropped, newest kept, capped)", result ~= nil and result.ok and #entries <= 200 and #entries[1].text == 600 and entries[#entries].i == 300 and entries[#entries].kind == "output")
	RemoteDebug.onClientLogs(playerA, { id = id, logs = {} })
	check("client logs: a second answer to the same id changes nothing", #entries > 0)
	local late = nil
	spawn(function()
		local ok, value = pcall(RemoteDebug.clientLogs, playerB, 0)
		late = { ok = ok, value = value }
	end)
	advance(6)
	check("client logs: no answer in RD_CLIENT_LOGS_TIMEOUT s is an error", late ~= nil and late.ok == false and string.find(tostring(late.value), "no_reply", 1, true) ~= nil)
end

-- 8. Instant wake (0.5.1; plans/25 "Instant wake") ------------------------------------------------------------------------
-- The backend publishes { k = "rd", j = JobId } on TypeTorch/deploy when a watch starts; the kernel hands the decoded
-- message to RemoteDebug.onWake.
RemoteDebug._reset()
do
	clock += (Constants.RD_AUTH_HOLD or 300) + 1
	table.clear(requests)
	table.clear(pollAnswers)
	local other = RemoteDebug.onWake({ k = "rd", j = "another-job" })
	local bad = {
		RemoteDebug.onWake(nil),
		RemoteDebug.onWake("job-rd-1"),
		RemoteDebug.onWake({ k = "rd" }),
		RemoteDebug.onWake({ k = "rd", j = 5 }),
		RemoteDebug.onWake({ k = "rd", j = "" }),
		RemoteDebug.onWake({ k = "rd", j = string.rep("a", 65) }),
		RemoteDebug.onWake({ k = "rd", j = { "job-rd-1" } }),
	}
	advance(3)
	local anyBad = false
	for _, result in bad do
		anyBad = anyBad or result ~= false
	end
	check("wake: another JobId's wake is ignored (no request)", other == false and #requests == 0)
	check("wake: malformed wakes are ignored (no request, nothing counted)", not anyBad and #requests == 0 and RemoteDebug.info().wakes == 0 and RemoteDebug.info().wakesIgnored == 0)
	check("wake: no session runs before a wake for this JobId", RemoteDebug.info().state == "off")

	-- This server's wake: the long-poll starts at once (on the same tick), like a heartbeat reply's rd = 1.
	table.insert(pollAnswers, { watch = true, commands = { cmd("w1", "status") } })
	table.insert(pollAnswers, { watch = false, commands = {} })
	local wokeAt = clock
	local woke = RemoteDebug.onWake({ k = "rd", j = "job-rd-1" })
	tick()
	local first = requests[1]
	check("wake: this JobId's wake starts the long-poll within a tick", woke == true and first ~= nil and first.method == "GET" and first.at == wokeAt and first.url == BASE .. "/v1/fleet/commands?wait=8")
	check("wake: the poll goes to the settings' backend with its key and the JobId (the same poll as rd = 1)", first and first.headers.Authorization == "Bearer " .. KEY and first.headers["X-TT-Job"] == "job-rd-1")
	local info = RemoteDebug.info()
	check("wake: info() counts it (wakes, lastWakeAt) and says polling", info.wakes == 1 and info.wakesIgnored == 0 and info.lastWakeAt == math.floor(wokeAt) and info.state == "polling")
	advance(3)
	check("wake: the session answers commands like any other", answerOf("w1") ~= nil and answerOf("w1").ok == true)
	check("wake: the backend's 'not watched' still ends the session", RemoteDebug.info().state == "off")

	-- At most one wake per RD_WAKE_GAP s is acted on.
	local before = polls()
	local again = RemoteDebug.onWake({ k = "rd", j = "job-rd-1" })
	advance(3)
	check("wake: a second wake inside RD_WAKE_GAP is ignored (counted, no poll)", again == false and polls() == before and RemoteDebug.info().wakesIgnored == 1 and RemoteDebug.info().wakes == 1)

	-- A forged wake (the job isn't watched): exactly one poll, then nothing.
	clock += Constants.RD_WAKE_GAP or 10
	table.insert(pollAnswers, { watch = false, commands = {} })
	before = polls()
	local forged = RemoteDebug.onWake({ k = "rd", j = "job-rd-1" })
	advance(10)
	check("wake: a forged wake (job not watched) costs one poll, then stops", forged == true and polls() == before + 1 and RemoteDebug.info().state == "off" and RemoteDebug.info().wakes == 2)

	-- No backend in the signed settings: no effect.
	clock += Constants.RD_WAKE_GAP or 10
	table.clear(requests)
	local saved = target
	target = nil
	local none = RemoteDebug.onWake({ k = "rd", j = "job-rd-1" })
	advance(3)
	check("wake: no backend in the settings, no poll (counted as ignored)", none == false and #requests == 0 and RemoteDebug.info().wakesIgnored == 2)
	target = saved

	-- Not a live server (Studio): no effect.
	clock += Constants.RD_WAKE_GAP or 10
	RemoteDebug.configure({ active = false })
	local studio = RemoteDebug.onWake({ k = "rd", j = "job-rd-1" })
	advance(3)
	check("wake: a server that isn't live (Studio) never polls", studio == false and #requests == 0)
	RemoteDebug.configure({ active = true })
end

-- 9. The key never leaks -------------------------------------------------------------------------------------------------
do
	local leaked = false
	for _, line in output do
		leaked = leaked or string.find(line, KEY, 1, true) ~= nil
	end
	for _, request in requests do
		if request.raw then
			leaked = leaked or string.find(request.raw, KEY, 1, true) ~= nil
		end
	end
	check("the key never appears in a line or a posted answer", not leaked)
	check("info() carries counters, never the URL or the key", not string.find(serde.encode("json", RemoteDebug.info()), KEY, 1, true) and not string.find(serde.encode("json", RemoteDebug.info()), BASE, 1, true))
end

print(`remote debug: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
