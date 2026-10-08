--!nonstrict
-- Errors.luau under Lune (`lune run scripts/test-errors.luau` from kernel/), 0.4.0 (problem 19): templating (players'
-- names, display names and UserIds as whole words), the generation in mount paths, fingerprints (known vectors, same
-- kind across swaps, the top stack line counts), per-minute counting with pids, bounded memory (kinds, items, counts,
-- pids, the per-second gate), batching limits (items, bytes, template and stack sizes, the stack sent once, old items),
-- the sender (202, retries and backoff, 401 hold, 429 Retry-After, 413 halving, 400 dropped, items kept across a
-- failure), client batches (the per-player gap, caps) and the LogService / ScriptContext dedup. A fake clock and a fake
-- HttpService; the key never shows in a line.
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
local nowMs = 1791547200000 -- 2026-10-09
local output = {}
local requests = {} -- { at, url, headers, body (decoded), compress }
local answers = {} -- scripted answers for the next requests: "netfail" | number | { status, body?, headers? }; then 202
local KEY = "backend-key-0123456789abcdef"
local target = { url = "https://backend.example.test", token = KEY, host = "backend.example.test" }

local Constants = luau.load(fs.readFile("src/shared/Constants.luau"), { debugName = "Constants.luau" })()
local http = {
	RequestAsync = function(_, request)
		table.insert(requests, { at = clock, url = request.Url, headers = request.Headers, body = serde.decode("json", request.Body), compress = request.Compress, size = #request.Body })
		local answer = table.remove(answers, 1)
		if answer == "netfail" then
			error("HttpError: NetFail", 0)
		elseif typeof(answer) == "number" then
			return { Success = answer >= 200 and answer < 300, StatusCode = answer, Body = "", Headers = {} }
		elseif typeof(answer) == "table" then
			return { Success = answer.status >= 200 and answer.status < 300, StatusCode = answer.status, Body = answer.body or "", Headers = answer.headers or {} }
		end
		local accepted = #(serde.decode("json", request.Body).errors)
		return { Success = true, StatusCode = 202, Body = serde.encode("json", { accepted = accepted, rejected = 0 }), Headers = {} }
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
	os = { clock = function()
		return clock
	end, time = function()
		return math.floor(nowMs / 1000)
	end },
}, { __index = getfenv(0) })
local Errors = luau.load(fs.readFile("src/server/Errors.luau"), { debugName = "Errors.luau", environment = env })()

local randomValue = 0.5
local function configure()
	Errors.configure({
		active = true,
		jobId = "job-1",
		http = http,
		encode = function(value)
			return serde.encode("json", value)
		end,
		decode = function(text)
			return serde.decode("json", text)
		end,
		gzip = "GZIP",
		target = function()
			return target
		end,
		context = function()
			return { branch = "prod", build = "prod-a1b2c3d" }
		end,
		nowMs = function()
			return nowMs
		end,
		clock = function()
			return clock
		end,
		random = function()
			return randomValue
		end,
		print = function(...)
			table.insert(output, table.concat({ ... }, " "))
		end,
		warn = function(...)
			table.insert(output, "warn: " .. table.concat({ ... }, " "))
		end,
	})
end
configure()

local function said(fragment: string): number
	local count = 0
	for _, line in output do
		if string.find(line, fragment, 1, true) then
			count += 1
		end
	end
	return count
end
local function reset()
	Errors._reset()
	configure()
	table.clear(requests)
	table.clear(answers)
	table.clear(output)
end
local function advance(seconds: number)
	clock += seconds
	nowMs += math.floor(seconds * 1000)
end
-- Runs the sender for `seconds` of fake time (Errors.step every 0.5 s, like its thread).
local function run(seconds: number)
	local stop = clock + seconds
	while clock < stop do
		Errors.step()
		advance(0.5)
	end
end

local BOB = { UserId = 123456789, Name = "Bob", DisplayName = "Bobby" }
local ALICE = { UserId = 987654321, Name = "Alice", DisplayName = "player" } -- a display name that is also a token word
local SAME = { UserId = 55555555, Name = "Carol", DisplayName = "Carol" }
local STUDIO = { UserId = -1, Name = "Player1", DisplayName = "Player1" }

-- 1. Templating ------------------------------------------------------------------------------------------------------
do
	local list = Errors.needles({
		{ name = "Bob", display = "Bobby", id = "123456789", userId = 1 },
		{ name = "Alice", display = "player", id = "987654321", userId = 2 },
		{ name = "Carol", display = "Carol", id = "55555555", userId = 3 },
	})
	local text, named = Errors.template("Bob hit Bobby (123456789) near Bobcat, xBob, Bob_1 and Bob.", list)
	check("names, display names and ids become tokens", text == "<player.name> hit <player.display_name> (<player.user_id>) near Bobcat, xBob, Bob_1 and <player.name>.", text)
	check("only whole words (Bobcat, xBob, Bob_1 stay)", string.find(text, "Bobcat", 1, true) ~= nil and string.find(text, "xBob", 1, true) ~= nil and string.find(text, "Bob_1", 1, true) ~= nil)
	check("the named player is noted", named[1] == true and named[2] == nil)
	text = Errors.template("Alice gave the player 5 coins as player", list)
	check("a display name that is a common word never breaks a token", text == "<player.name> gave the <player.display_name> 5 coins as <player.display_name>", text)
	text = Errors.template("Carol left", list)
	check("a display name equal to the name is the name", text == "<player.name> left", text)
	text = Errors.template("user 123456789: id1234567890 and 9123456789", list)
	check("a UserId only as a whole number", text == "user <player.user_id>: id1234567890 and 9123456789", text)
	check("a token in the message is never replaced again", Errors.template("<player.name>", list) == "<player.name>")
end

-- 2. Generations in paths, fingerprints ------------------------------------------------------------------------------
do
	local a = Errors.describe("ServerStorage.TypeTorch.Generations.prod-a1b2c3d#3.Server.round:42: attempt to index nil", "ServerStorage.TypeTorch.Generations.prod-a1b2c3d#3.Server.round:42 function tick\nServerScriptService.TypeTorchEntries.Entry:5", {})
	local b = Errors.describe("ServerStorage.TypeTorch.Generations.prod-a1b2c3d#4.Server.round:42: attempt to index nil", "ServerStorage.TypeTorch.Generations.prod-a1b2c3d#4.Server.round:42 function tick\n", {})
	local c = Errors.describe("ServerStorage.TypeTorch.Generations.dev-ffff000-dirty-abc123#9.Server.round:42: attempt to index nil", "ServerStorage.TypeTorch.Generations.dev-ffff000-dirty-abc123#9.Server.round:43 function tick", {})
	check("the generation in mount paths becomes <gen>", a.template == "ServerStorage.TypeTorch.Generations.<gen>.Server.round:42: attempt to index nil", a.template)
	check("same error after a swap: same fingerprint", a.fp == b.fp, `{a.fp} {b.fp}`)
	check("the top stack line counts (another line: another kind)", a.fp ~= c.fp)
	check("top line = the first non-empty stack line", a.top == "ServerStorage.TypeTorch.Generations.<gen>.Server.round:42 function tick", a.top)
	check("fp: 16 hex characters (the backend's 1-64 of A-Za-z0-9_.:-)", string.match(a.fp, "^[0-9a-f]+$") ~= nil and #a.fp == 16, a.fp)
	check("fingerprint vectors: FNV-1a + djb2 of \"\" and \"a\"", Errors.fingerprint("") == "811c9dc500001505" and Errors.fingerprint("a") == "e40c292c0002b606", `{Errors.fingerprint("")} {Errors.fingerprint("a")}`)
	local long = Errors.fingerprint(string.rep("TypeTorch error ", 500))
	check("fingerprints stay 32-bit exact on long text", #long == 16 and long == Errors.fingerprint(string.rep("TypeTorch error ", 500)))
	local client = Errors.describe("Players.Bob.PlayerScripts.TypeTorchRetry.prod-a1b2c3d#2.Client.ui:9: boom", "Players.Bob.PlayerScripts.TypeTorchRetry.prod-a1b2c3d#2.Client.ui:9", Errors.needles({ { name = "Bob", display = "Bobby", id = "123456789", userId = 1 } }))
	check("client paths: the player and the retry copy's generation are templated", client.template == "Players.<player.name>.PlayerScripts.TypeTorchRetry.<gen>.Client.ui:9: boom" and client.named[1] == true, client.template)
	check("control characters are flattened in a template (lines kept in a stack)", Errors.describe("a\tb\nc", "x\r\ny", {}).template == "a b c" and Errors.describe("a", "x\r\ny", {}).stack == "x\ny")
end

-- 3. Recording: per minute, pids, realms -----------------------------------------------------------------------------
reset()
Errors.playerAdded(BOB)
Errors.playerAdded(ALICE)
Errors.playerAdded(STUDIO)
check("setPid takes a pid", Errors.setPid(BOB, "0123456789abcdef0123456789abcdef") and Errors.setPid(ALICE, "fedcba9876543210fedcba9876543210"))
check("setPid refuses a bad pid", not Errors.setPid(BOB, "bad pid!") and not Errors.setPid(BOB, string.rep("a", 65)))
local fp = Errors.record("server", "Round failed for Bob: no spawn", "ServerStorage.TypeTorch.Generations.prod-a1b2c3d#1.Server.round:10", 1, { branch = "prod", build = "prod-a1b2c3d" })
Errors.record("server", "Round failed for Bob: no spawn", "ServerStorage.TypeTorch.Generations.prod-a1b2c3d#1.Server.round:10", 2, { branch = "prod", build = "prod-a1b2c3d" })
Errors.record("server", "Player1 is -1", nil, 1, {})
local body = Errors.buildBatch()
local item = nil
for _, entry in body.errors do
	if entry.fp == fp then
		item = entry
	end
end
check("one item per kind and minute, counts added", item ~= nil and item.count == 3, item and item.count)
check("the template has no name", item and item.template == "Round failed for <player.name>: no spawn", item and item.template)
check("pids: the player the message named (not a name, not a UserId)", item and item.pids and #item.pids == 1 and item.pids[1] == "0123456789abcdef0123456789abcdef")
check("branch, build, realm, times (unix ms, first <= last)", item and item.branch == "prod" and item.build == "prod-a1b2c3d" and item.realm == "server" and item.firstAt <= item.lastAt and item.firstAt == nowMs)
local studio = nil
for _, entry in body.errors do
	if entry.fp ~= fp then
		studio = entry
	end
end
check("Studio's negative UserIds are not replaced ('-1' is too common)", studio and studio.template == "<player.name> is -1", studio and studio.template)
advance(60)
Errors.record("server", "Round failed for Bob: no spawn", "ServerStorage.TypeTorch.Generations.prod-a1b2c3d#1.Server.round:10", 1, { branch = "prod", build = "prod-a1b2c3d" })
check("a new minute: a new item", #Errors.buildBatch().errors == 3)
check("info: kinds, waiting, seen", Errors.info().kinds == 2 and Errors.info().waiting == 3 and Errors.info().seen.server == 5)

-- 4. Bounded memory --------------------------------------------------------------------------------------------------
reset()
for index = 1, Constants.ERRORS_KINDS_MAX + 30 do
	Errors.record("server", `kind {index}`, nil, 1, {})
end
local info = Errors.info()
check("at most ERRORS_KINDS_MAX kinds; the rest dropped and counted", info.kinds == Constants.ERRORS_KINDS_MAX and info.dropped.kinds == 30, `{info.kinds} {info.dropped.kinds}`)
reset()
for index = 1, Constants.ERRORS_ITEMS_MAX + 10 do
	-- 6 kinds, one item per minute each
	Errors.record("server", `item kind {index % 6}`, nil, 1, {})
	if index % 6 == 0 then
		advance(60)
	end
end
info = Errors.info()
check("at most ERRORS_ITEMS_MAX items wait; the rest dropped and counted", info.waiting == Constants.ERRORS_ITEMS_MAX and info.dropped.items == 10, `{info.waiting} {info.dropped.items}`)
reset()
Errors.record("server", "big", nil, Constants.ERRORS_COUNT_MAX - 1, {})
Errors.record("server", "big", nil, 5, {})
body = Errors.buildBatch()
check("a count stays <= 1e6 (the excess is counted as dropped)", body.errors[1].count == Constants.ERRORS_COUNT_MAX and Errors.info().dropped.items == 4)
reset()
for index = 1, 60 do
	local player = { UserId = 1000000 + index, Name = `Runner{index}`, DisplayName = `Runner{index}` }
	Errors.playerAdded(player)
	Errors.setPid(player, string.format("%032x", index))
	Errors.record("client", "lag spike", nil, 1, { pid = string.format("%032x", index) })
end
body = Errors.buildBatch()
check("at most ERRORS_PIDS_MAX (10) pids per item", #body.errors[1].pids == Constants.ERRORS_PIDS_MAX)
reset()
for _ = 1, Constants.ERRORS_RECORD_PER_SECOND + 20 do
	Errors.record("server", "flood", nil, 1, {})
end
check("at most ERRORS_RECORD_PER_SECOND errors a second are looked at", Errors.info().dropped.rate == 20 and Errors.buildBatch().errors[1].count == Constants.ERRORS_RECORD_PER_SECOND)

-- 5. Batch limits ----------------------------------------------------------------------------------------------------
reset()
local bigStack = string.rep("ServerStorage.TypeTorch.Generations.prod-a1b2c3d#1.Server.deep.module:123 function call\n", 80)
for index = 1, 300 do
	Errors.record("server", `{index} ` .. string.rep("x", 1500), `line {index}\n` .. bigStack, 1, {})
end
body = Errors.buildBatch()
local encoded = serde.encode("json", body)
check("a batch holds at most ERRORS_BATCH_MAX items", #body.errors <= Constants.ERRORS_BATCH_MAX)
check("a batch stays under ERRORS_BATCH_BYTES of JSON (the backend: 512 KB gzip, 2 MB inflated)", #encoded <= Constants.ERRORS_BATCH_BYTES + 100, #encoded)
check("templates <= 1000, stacks <= 4000 bytes", #body.errors[1].template <= Constants.ERRORS_TEMPLATE_MAX and #body.errors[1].stack <= Constants.ERRORS_STACK_MAX, `{#body.errors[1].template} {#(body.errors[1].stack or "")}`)
check("UTF-8 is never cut in half", Errors.cut("ab" .. "\u{e9}", 3) == "ab")

-- 6. The sender ------------------------------------------------------------------------------------------------------
reset()
Errors.playerAdded(BOB)
Errors.setPid(BOB, "c0ffee00c0ffee00c0ffee00c0ffee00")
Errors.record("server", "Bob broke it", "Workspace.Script:1", 1, { branch = "prod", build = "prod-a1b2c3d" })
run(1)
check("one POST to <url>/v1/errors with the key as a Bearer header", #requests == 1 and requests[1].url == "https://backend.example.test/v1/errors" and requests[1].headers.Authorization == "Bearer " .. KEY)
check("the body: { v = 1, j = JobId, errors }", requests[1].body.v == 1 and requests[1].body.j == "job-1" and #requests[1].body.errors == 1)
check("no name and no UserId in the body", not string.find(serde.encode("json", requests[1].body), "Bob", 1, true) and not string.find(serde.encode("json", requests[1].body), "123456789", 1, true))
check("202: sent, nothing waits", Errors.info().sent == 1 and Errors.info().waiting == 0)
check("the first batch of a kind carries its stack", requests[1].body.errors[1].stack == "Workspace.Script:1")
Errors.record("server", "Bob broke it", "Workspace.Script:1", 1, { branch = "prod", build = "prod-a1b2c3d" })
run(Constants.ERRORS_FLUSH_SECONDS * 1.3)
check("later batches leave the stack out", #requests == 2 and requests[2].body.errors[1].stack == nil, #requests)
run(60)
check("nothing waiting: no requests", #requests == 2)
-- gzip only for bodies over 1 KB
Errors.record("server", string.rep("long ", 400), nil, 1, {})
run(Constants.ERRORS_FLUSH_SECONDS * 1.3)
check("gzip (Compress) for bodies over 1 KB, plain below", requests[3].compress == "GZIP" and requests[1].compress == nil)

-- Network failure: retries jittered, items kept and merged, then backoff; one line a minute, never the key.
reset()
for _ = 1, 30 do
	table.insert(answers, "netfail")
end
Errors.record("server", "kept", nil, 2, {})
run(1)
Errors.record("server", "kept", nil, 3, {})
run(20)
local tries = #requests
check("a failed POST is retried (1, 3, 9 s, jittered) then backs off", tries == 4, tries)
check("items survive a failure and merge with new ones", Errors.info().waiting == 1 and Errors.buildBatch().errors[1].count == 5)
info = Errors.info()
check("info: failures in a row and retryIn while backing off", info.failures == 4 and typeof(info.retryIn) == "number" and info.retryIn > 0, `{info.failures} {info.retryIn}`)
check("one warning line, with the reason", said("error reports: backend backend.example.test unreachable") == 1 and said("the connection broke mid-request") == 1)
table.clear(answers)
run(400)
check("after the outage: posted, one 'works again' line, failures 0", Errors.info().sent >= 1 and said("posting works again") == 1 and Errors.info().failures == 0)
check("the key never shows in a line", said(KEY) == 0)

-- 401: held off about 5 minutes, no retries.
reset()
table.insert(answers, 401)
Errors.record("server", "auth", nil, 1, {})
run(200)
check("401: one request, held off (no retries within 200 s)", #requests == 1 and Errors.info().retryIn ~= nil)
check("401: the line names the backend key", said("the backend key is wrong") == 1)
run(200)
check("401 fixed: posted after the hold", #requests == 2 and Errors.info().waiting == 0)

-- 429 with Retry-After: waits that long.
reset()
table.insert(answers, { status = 429, headers = { ["Retry-After"] = "42" } })
Errors.record("server", "busy", nil, 1, {})
run(1)
check("429: waits its Retry-After (42 s)", Errors.info().retryIn ~= nil and Errors.info().retryIn >= 41 and Errors.info().retryIn <= 42, Errors.info().retryIn)
run(45)
check("429: posted after the wait", #requests == 2 and Errors.info().waiting == 0)

-- 413: the batch is halved and goes again at once.
reset()
table.insert(answers, 413)
for index = 1, 10 do
	Errors.record("server", `many {index}`, nil, 1, {})
end
run(Constants.ERRORS_FLUSH_SECONDS * 1.3)
check("413: the next batch is half the size", #requests >= 2 and #requests[1].body.errors == 10 and #requests[2].body.errors == 5, `{#requests} {requests[2] and #requests[2].body.errors}`)

-- 400: dropped, counted as rejected, no backoff.
reset()
table.insert(answers, 400)
Errors.record("server", "bad", nil, 1, {})
run(1)
check("400: the batch is dropped and counted as rejected, no backoff", Errors.info().rejected == 1 and Errors.info().waiting == 0 and Errors.info().retryIn == nil)

-- 202 with rejected items: counted, one line.
reset()
table.insert(answers, { status = 202, body = serde.encode("json", { accepted = 1, rejected = 1, errors = { "fp: bad" } }) })
Errors.record("server", "a", nil, 1, {})
Errors.record("server", "b", nil, 1, {})
run(1)
check("202 with rejected items: counted and said once", Errors.info().sent == 1 and Errors.info().rejected == 1 and said("refused 1 item(s): fp: bad") == 1)

-- Rate: at most ERRORS_RATE_PER_MINUTE requests a minute.
reset()
for index = 1, 600 do
	Errors.record("server", `rate {index}`, nil, 1, {})
	if index % 20 == 0 then
		run(5)
	end
end
local from = clock
local before = #requests
run(120)
check("at most ERRORS_RATE_PER_MINUTE requests a minute", #requests - before <= 2 * Constants.ERRORS_RATE_PER_MINUTE + 2, #requests - before)

-- Old items are dropped unsent (the backend refuses anything older than 7 days).
reset()
Errors.record("server", "ancient", nil, 1, {})
advance(Constants.ERRORS_MAX_AGE + 60)
check("items older than ERRORS_MAX_AGE are dropped as old", #Errors.buildBatch().errors == 0 and Errors.info().dropped.old == 1)

-- Not a live server (Studio), or no backend settings: counted, never posted.
reset()
Errors.configure({ active = false })
Errors.record("server", "studio", nil, 1, {})
run(30)
check("Studio: counted, nothing posted", #requests == 0 and Errors.info().waiting == 1 and Errors.info().enabled == false)
reset()
target = nil
Errors.record("server", "no settings", nil, 1, {})
run(30)
check("no backend settings: nothing posted", #requests == 0)
target = { url = "https://backend.example.test", token = KEY, host = "backend.example.test" }

-- 7. Client batches --------------------------------------------------------------------------------------------------
reset()
Errors.playerAdded(BOB)
Errors.setPid(BOB, "0123456789abcdef0123456789abcdef")
local entries = {}
for index = 1, 15 do
	table.insert(entries, { m = `Bob's UI {index} failed` .. string.rep("!", 2000), s = "Players.Bob.PlayerScripts.TypeTorchRetry.prod-a1b2c3d#2.Client.ui:9", n = 5000, g = "prod-a1b2c3d#2" })
end
local taken = Errors.fromClient(BOB, { e = entries, d = 3 })
check("a client batch: at most ERRORS_CLIENT_BATCH entries; the rest and the client's own drops counted", taken == Constants.ERRORS_CLIENT_BATCH and Errors.info().dropped.client == 3 + 5)
body = Errors.buildBatch()
local first = body.errors[1]
check("client entries: realm client, the sender's pid, the build from the generation name, counts capped", first.realm == "client" and first.pids[1] == "0123456789abcdef0123456789abcdef" and first.build == "prod-a1b2c3d" and first.count == Constants.ERRORS_CLIENT_COUNT_MAX, `{first.realm} {first.build} {first.count}`)
check("client messages are cut and templated on the server", #first.template <= Constants.ERRORS_CLIENT_MESSAGE_MAX and string.find(first.template, "<player.name>'s UI", 1, true) ~= nil and string.find(first.stack, "Players.<player.name>.", 1, true) ~= nil)
advance(2)
check("a second batch within ERRORS_CLIENT_SERVER_GAP s is dropped (counted)", Errors.fromClient(BOB, { e = { { m = "again", n = 1 } } }) == 0 and Errors.info().dropped.client == 9)
advance(Constants.ERRORS_CLIENT_SERVER_GAP)
check("after the gap: taken", Errors.fromClient(BOB, { e = { { m = "again", n = 1 } } }) == 1)
check("junk from a client is ignored", Errors.fromClient(ALICE, "junk") == 0 and Errors.fromClient(ALICE, { e = { 1, { m = 5 }, { m = "" } } }) == 0)

-- A player who left is still templated for a while, then forgotten.
reset()
Errors.configure({ active = false })
Errors.playerAdded(BOB)
Errors.playerRemoving(BOB)
Errors.record("server", "Bob left early", nil, 1, {})
advance(Constants.ERRORS_LEFT_SECONDS + 5)
Errors.step()
Errors.record("server", "Bob left late", nil, 1, {})
body = Errors.buildBatch()
local early, late = false, false
for _, entry in body.errors do
	early = early or entry.template == "<player.name> left early"
	late = late or entry.template == "Bob left late"
end
check("a player who just left is still templated, then forgotten", early and late)

-- 8. ScriptContext / LogService dedup --------------------------------------------------------------------------------
reset()
Errors.noteLogError("Workspace.Script:3: boom") -- the log line first
Errors.noteScriptError("Workspace.Script:3: boom", "Workspace.Script:3", nil)
Errors.noteScriptError("Workspace.Other:1: bang", "Workspace.Other:1", nil)
Errors.noteLogError("Workspace.Other:1: bang") -- the log line after
Errors.noteLogError("Requested module experienced an error while loading") -- a log-only error
advance(1)
Errors.step()
info = Errors.info()
check("a script error is counted once (ScriptContext and its log line, either order); log-only errors count", info.seen.server == 3 and info.kinds == 3, `{info.seen.server} {info.kinds}`)

print(`errors: {passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
