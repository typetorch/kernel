--!nonstrict
-- LiveDebug.luau with Fleet.luau, RemoteDebug.luau and Api.luau under Lune (`lune run scripts/test-live-debug.luau` from
-- kernel/), 0.5.7 (plans/34). A fake clock and a tiny scheduler drive every thread (the fleet sender, the poll, the
-- sampler, the posts); a fake HttpService plays the backend. Checks: the API's declarations (names, limits, cuts, the
-- hash: stable, changes with any field); heartbeats carry xh every time, x on the first, after a change and after a
-- reply's xq; cv with failing, yielding and odd getters (null), cut strings; columnsChanged is coalesced per
-- FLEET_COLUMNS_GAP; closing carries none; game.* commands run only when declared (the rate, owners, args cap and the
-- scrub still apply); streams run with the poll (positions 2 Hz, custom ones at their rate, batched every second,
-- value and body caps, secrets scrubbed) and stop on a reply saying neither, the poll's end, 3 failed posts or a 401
-- (held); live map mode (wake { k = "lm" } or a heartbeat's lm = 1): positions only every 3 s, extended by replies,
-- ends 60 s after the last, one wake per LD_LM_WAKE_GAP; the key never leaks.
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
local KEY = "backend-key-0123456789abcdef0123456789abcdef"
local GAME_SECRET = "game-webhook-secret-abcdef123"
local BASE = "https://backend.example.test"

-- The scheduler -------------------------------------------------------------------------------------------------------
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

-- The backend -----------------------------------------------------------------------------------------------------------
local requests = {}
local heartbeatReplies = {} -- queued replies to heartbeats (tables), else { ok = true }
local pollAnswers = {}
local streamReplies = {} -- queued replies to stream posts: a table, a status code or "netfail"; else streamDefault
local streamDefault = { ok = true, watch = true, lm = false }
local function pathOf(url: string): string
	return (string.match(string.sub(url, #BASE + 1), "^[^?]*"))
end
local http = {
	RequestAsync = function(_, request)
		local body = nil
		if request.Body then
			local ok, decoded = pcall(serde.decode, "json", request.Body)
			body = if ok then decoded else nil
		end
		local path = pathOf(request.Url)
		table.insert(requests, { at = clock, method = request.Method, url = request.Url, path = path, headers = request.Headers, body = body, raw = request.Body })
		if path == "/v1/fleet/commands" then
			local answer = table.remove(pollAnswers, 1) or { watch = true, commands = {} }
			return { Success = true, StatusCode = 200, Body = serde.encode("json", answer) }
		elseif path == "/v1/fleet/heartbeat" then
			local reply = table.remove(heartbeatReplies, 1) or { ok = true }
			return { Success = true, StatusCode = 200, Body = serde.encode("json", reply) }
		elseif path == "/v1/fleet/streams" then
			local reply = table.remove(streamReplies, 1) or streamDefault
			if reply == "netfail" then
				error("HttpError: NetFail " .. KEY, 0)
			elseif typeof(reply) == "number" then
				return { Success = false, StatusCode = reply, Body = "" }
			elseif typeof(reply) == "string" then
				return { Success = true, StatusCode = 200, Body = reply } -- not JSON
			end
			return { Success = true, StatusCode = 200, Body = serde.encode("json", reply) }
		end
		return { Success = true, StatusCode = 202, Body = "{}" }
	end,
}
local function ofPath(path: string, from: number?): { any }
	local list = {}
	for _, request in requests do
		if request.path == path and request.at >= (from or 0) then
			table.insert(list, request)
		end
	end
	return list
end
local function lastHeartbeat()
	local list = ofPath("/v1/fleet/heartbeat")
	return list[#list]
end

-- The modules ------------------------------------------------------------------------------------------------------------
local Constants = luau.load(fs.readFile("src/shared/Constants.luau"), { debugName = "Constants.luau" })()
local fakeTask = {
	spawn = function(fn, ...)
		spawn(fn, ...)
	end,
	wait = wait,
	delay = function() end,
}
local env = setmetatable({
	game = {
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
	},
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
	warn = function(...)
		table.insert(output, "warn: " .. table.concat({ ... }, " "))
	end,
}, { __index = getfenv(0) })
local function load(file: string)
	return luau.load(fs.readFile(`src/server/{file}`), { debugName = file, environment = env })()
end
local Fleet = load("Fleet.luau")
local RemoteDebug = load("RemoteDebug.luau")
local LiveDebug = load("LiveDebug.luau")
local Api = load("Api.luau")

local function encode(value)
	return serde.encode("json", value)
end
local function decode(text)
	return serde.decode("json", text)
end
local function log(...)
	table.insert(output, table.concat({ ... }, " "))
end

local current = nil -- the running generation
local players = {}
local OWNER, STRANGER = 1001, 2002

Fleet.configure({
	http = http,
	jobId = "job-ld-1",
	active = true,
	readSettings = function()
		return true, { url = BASE, key = KEY }, "backend"
	end,
	status = function()
		return { sv = 2, t = "public", n = #players }
	end,
	encode = encode,
	decode = decode,
	print = log,
	warn = log,
	onHeartbeatReply = function(reply)
		RemoteDebug.wake(reply)
		LiveDebug.onReply(reply)
	end,
	declarations = LiveDebug.declarations,
	columnValues = LiveDebug.columnValues,
})
local function target()
	return Fleet.target()
end
local function secrets()
	return { KEY, GAME_SECRET }
end
RemoteDebug.configure({
	http = http,
	jobId = "job-ld-1",
	active = true,
	target = target,
	encode = encode,
	decode = decode,
	secrets = secrets,
	ops = {
		status = function()
			return { ok = true }
		end,
	},
	gameCommands = function()
		if current and current.debug then
			return current.debug.commands, current.debugCommandHandler
		end
		return nil, nil
	end,
	onSession = LiveDebug.onPoll,
	isOwner = function(userId)
		return userId == OWNER
	end,
	spawn = spawn,
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
	print = log,
	warn = log,
})
LiveDebug.configure({
	http = http,
	jobId = "job-ld-1",
	active = true,
	target = target,
	encode = encode,
	decode = decode,
	generation = function()
		return current
	end,
	players = function()
		return players
	end,
	scrub = function(text)
		return RemoteDebug.scrub(text, secrets())
	end,
	toPlain = RemoteDebug.toPlain,
	heartbeat = Fleet.heartbeat,
	pollRunning = RemoteDebug.running,
	pollSession = RemoteDebug.session,
	watchHint = function()
		RemoteDebug.wake({ rd = 1 })
	end,
	spawn = spawn,
	clock = function()
		return clock
	end,
	nowMs = function()
		return math.floor(clock * 1000)
	end,
	wait = wait,
	print = log,
	warn = log,
})
Api.init({
	LiveDebug = LiveDebug,
	KERNEL_API = 1,
	KERNEL_VERSION = Constants.KERNEL_VERSION,
	serverType = function()
		return "public"
	end,
	Constants = Constants,
})

local function newGeneration(name: string)
	local entry = { name = name }
	local generation = { name = name, number = 1, branch = "main", rules = "prod", artifact = { id = name }, start = {} }
	Api.register(entry, generation)
	return generation, Api.forEntry(entry)
end

local function player(userId: number, name: string, options: any?)
	options = options or {}
	local character = nil
	if not options.noCharacter then
		local root = if options.noRoot then nil else { CFrame = { Position = options.position or { X = 1.04, Y = 2.26, Z = -3.31 }, LookVector = options.look or { X = 0, Y = 0, Z = -1 } } }
		local humanoid = { Health = options.health or 100, GetState = function()
			return { Name = options.state or "Running" }
		end }
		character = {
			FindFirstChild = function(_, childName)
				return if childName == "HumanoidRootPart" then root else nil
			end,
			FindFirstChildOfClass = function(_, className)
				return if className == "Humanoid" then humanoid else nil
			end,
		}
	end
	return { UserId = userId, Name = name, Character = character }
end

-- 1. Declarations and the hash ------------------------------------------------------------------------------------------
local gen, api = newGeneration("gen-a")
do
	check("api: debugDeclare & co. exist with LiveDebug mapped", typeof(api.debugDeclare) == "function" and typeof(api.onDebugCommand) == "function" and typeof(api.onDebugColumn) == "function" and typeof(api.onDebugStream) == "function" and typeof(api.debugColumnsChanged) == "function")
	local _, bare = (function()
		Api.init({ KERNEL_API = 1, KERNEL_VERSION = "x", serverType = function()
			return "public"
		end, Constants = Constants })
		local entry = {}
		Api.register(entry, { name = "old", artifact = {}, start = {} })
		return nil, Api.forEntry(entry)
	end)()
	check("api: without LiveDebug there is no debugDeclare (the framework's feature test fails)", bare.debugDeclare == nil and bare.onDebugCommand == nil)
	Api.init({ LiveDebug = LiveDebug, KERNEL_API = 1, KERNEL_VERSION = Constants.KERNEL_VERSION, serverType = function()
		return "public"
	end, Constants = Constants })

	local result = api:debugDeclare({
		columns = { { name = "current_map", label = "Map", type = "string" }, { name = "in_round", type = "bool" }, { name = "Bad-Name" }, { name = "current_map" }, { name = "score", type = "weird" } },
		commands = { { name = "round_state", label = "Round", description = string.rep("d", 300) }, { name = "9lives" } },
		streams = { { name = "loot", hz = 10, kind = "points", label = string.rep("L", 60) }, { name = "slow", hz = 0.01 }, { name = "nohz" } },
	})
	check("declare: valid entries kept, bad names / duplicates / no hz dropped and counted", result.ok and result.columns == 3 and result.commands == 1 and result.streams == 2 and result.dropped == 4, encode(result))
	local x = gen.debug.x
	check("declare: wire form c / cmd / st with n, l, t, d, hz, k", x.c[1].n == "current_map" and x.c[1].l == "Map" and x.c[1].t == "string" and x.c[2].t == "bool" and x.c[3].t == nil and x.cmd[1].n == "round_state" and x.st[1].k == "points" and x.st[2].k == "json")
	check("declare: descriptions cut to 200, labels to 40", #x.cmd[1].d == 200 and #x.st[1].l == 40)
	check("declare: rates clamped to 0.2..4 Hz", x.st[1].hz == 4 and x.st[2].hz == 0.2)
	check("declare: a 16-hex hash", typeof(result.hash) == "string" and string.match(result.hash, "^%x+$") and #result.hash == 16)
	local again = LiveDebug.normalize({ columns = { { name = "current_map", label = "Map", type = "string" }, { name = "in_round", type = "bool" }, { name = "score" } }, commands = { { name = "round_state", label = "Round", description = string.rep("d", 300) } }, streams = { { name = "loot", hz = 4, kind = "points", label = string.rep("L", 60) }, { name = "slow", hz = 0.2 } } })
	check("hash: the same declarations, the same hash", again.xh == result.hash)
	local labelChanged = LiveDebug.normalize({ columns = { { name = "current_map", label = "Map!", type = "string" }, { name = "in_round", type = "bool" }, { name = "score" } }, commands = { { name = "round_state", label = "Round", description = string.rep("d", 300) } }, streams = { { name = "loot", hz = 4, kind = "points", label = string.rep("L", 60) }, { name = "slow", hz = 0.2 } } })
	check("hash: a label change changes it", labelChanged.xh ~= result.hash)
	local orderChanged = LiveDebug.normalize({ columns = { { name = "in_round", type = "bool" }, { name = "current_map", label = "Map", type = "string" } } })
	local orderBase = LiveDebug.normalize({ columns = { { name = "current_map", label = "Map", type = "string" }, { name = "in_round", type = "bool" } } })
	check("hash: order and the field each value sits in matter", orderChanged.xh ~= orderBase.xh and LiveDebug.normalize({ commands = { { name = "a", label = "b" } } }).xh ~= LiveDebug.normalize({ commands = { { name = "a", description = "b" } } }).xh)
	local many = { columns = {}, commands = {}, streams = {} }
	for index = 1, 40 do
		table.insert(many.columns, { name = `c{index}` })
		table.insert(many.commands, { name = `m{index}` })
		table.insert(many.streams, { name = `s{index}`, hz = 1 })
	end
	local capped, droppedCount = LiveDebug.normalize(many)
	check("limits: 16 columns, 32 commands, 8 streams (the rest dropped)", #capped.x.c == 16 and #capped.x.cmd == 32 and #capped.x.st == 8 and droppedCount == 24 + 8 + 32)
	check("names: ^[a-z][a-z0-9_]{0,31}$", LiveDebug.validName("a") and LiveDebug.validName("a_1") and LiveDebug.validName(string.rep("a", 32)) and not LiveDebug.validName(string.rep("a", 33)) and not LiveDebug.validName("_a") and not LiveDebug.validName("A") and not LiveDebug.validName("a.b") and not LiveDebug.validName(""))
	check("nothing valid declared: no record (no xh on heartbeats)", LiveDebug.normalize({ columns = { { name = "BAD" } } }) == nil and LiveDebug.normalize(nil) == nil)
	check("cleanText: control characters out, cut by characters not bytes", LiveDebug.cleanText("a\nb", 10) == "a b" and LiveDebug.cleanText("ééé", 2) == "éé")
end

-- 2. Heartbeats: xh, x, cv, xq, the columns gap ---------------------------------------------------------------------------
current = gen
local columnValues = {
	current_map = function()
		return "HedgeMaze " .. string.rep("x", 100)
	end,
	in_round = function()
		return true
	end,
	score = function()
		error("boom")
	end,
}
api:onDebugColumn(function(name)
	return columnValues[name]()
end)
Fleet.start()
advance(1)
do
	local first = lastHeartbeat()
	check("heartbeat: the first carries xh and x", first and first.body.xh == gen.debug.xh and first.body.x and #first.body.x.c == 3 and #first.body.x.cmd == 1 and #first.body.x.st == 2)
	local cv = first and first.body.cv
	check("cv: values read at heartbeat time; strings cut to 64 characters", cv and cv.in_round == true and cv.current_map == string.sub("HedgeMaze " .. string.rep("x", 100), 1, 64))
	check("cv: a failing getter is JSON null (the key is there)", first and string.find(first.raw, '"score":null', 1, true) ~= nil and not string.find(first.raw, "__typetorch_json_null", 1, true), first and first.raw)
	advance(31)
	local second = lastHeartbeat()
	check("heartbeat: the next carries xh but not x", second ~= first and second.body.xh == gen.debug.xh and second.body.x == nil and second.body.cv ~= nil)

	-- A yielding getter (past LD_COLUMNS_DEADLINE), NaN and a table are null; the heartbeat isn't held up.
	columnValues.current_map = function()
		wait(5)
		return "late"
	end
	columnValues.in_round = function()
		return 0 / 0
	end
	columnValues.score = function()
		return { 1 }
	end
	local before = #ofPath("/v1/fleet/heartbeat")
	advance(31)
	local third = lastHeartbeat()
	check("cv: a getter that yields past the deadline, NaN and a table: null; the heartbeat still goes", #ofPath("/v1/fleet/heartbeat") == before + 1 and string.find(third.raw, '"current_map":null', 1, true) and string.find(third.raw, '"in_round":null', 1, true) and string.find(third.raw, '"score":null', 1, true), third.raw)
	columnValues.current_map = function()
		return "Lobby"
	end
	columnValues.in_round = function()
		return 3
	end
	columnValues.score = function()
		return false
	end

	-- columnsChanged: coalesced, at most one per FLEET_COLUMNS_GAP (deferred, not dropped).
	advance(2)
	local mark = clock
	check("columnsChanged: true for the running generation with columns", api:debugColumnsChanged() == true)
	advance(0.5)
	local quick = ofPath("/v1/fleet/heartbeat", mark)
	check("columnsChanged: a heartbeat soon", #quick == 1 and quick[1].body.cv.current_map == "Lobby" and quick[1].body.cv.in_round == 3)
	for _ = 1, 5 do
		api:debugColumnsChanged()
		advance(1)
	end
	local within = ofPath("/v1/fleet/heartbeat", mark)
	check("columnsChanged: many calls within the gap give one more heartbeat, after the gap", #within == 1, #within)
	advance(5)
	within = ofPath("/v1/fleet/heartbeat", mark)
	check("columnsChanged: the deferred one goes once the gap ends (2 in ~10.5 s)", #within == 2 and within[2].at - within[1].at >= Constants.FLEET_COLUMNS_GAP - 0.1, #within)

	-- xq: the backend lost the declarations; the next heartbeat (soon) carries x again.
	advance(12)
	table.insert(heartbeatReplies, { ok = true, xq = 1 })
	mark = clock
	api:debugColumnsChanged()
	advance(12)
	local asked = ofPath("/v1/fleet/heartbeat", mark)
	check("xq: the reply's xq = 1 makes the next heartbeat (within the gap) re-send x", #asked == 2 and asked[1].body.x == nil and asked[2].body.x ~= nil and asked[2].body.xh == gen.debug.xh, #asked)
	advance(31)
	check("xq: once sent, x isn't repeated", lastHeartbeat().body.x == nil)

	-- A declaration change: a heartbeat soon with the new x.
	advance(12)
	mark = clock
	local changed = api:debugDeclare({ columns = { { name = "current_map" } }, commands = { { name = "round_state" }, { name = "secret_probe" }, { name = "no_handler" } }, streams = { { name = "loot", hz = 2, kind = "points" }, { name = "big", hz = 1 } } })
	advance(1)
	local after = ofPath("/v1/fleet/heartbeat", mark)
	check("declare again: a heartbeat soon carries the new x and xh", #after == 1 and after[1].body.xh == changed.hash and after[1].body.x and #after[1].body.x.c == 1 and #after[1].body.x.cmd == 3)
	check("Fleet.info().declarationsSent: the acknowledged hash", Fleet.info().declarationsSent == changed.hash)

	-- Not the running generation: columnsChanged does nothing.
	local other, otherApi = newGeneration("gen-b")
	otherApi:debugDeclare({ columns = { { name = "x" } } })
	check("columnsChanged / declare from a generation that isn't running: no heartbeat", otherApi:debugColumnsChanged() == false and other.debug ~= nil)
	-- No declarations: no xh / x / cv.
	current = other
	other.debug = nil
	advance(31)
	local none = lastHeartbeat()
	check("no declarations: heartbeats carry no xh, x or cv", none.body.xh == nil and none.body.x == nil and none.body.cv == nil)
	current = gen
	advance(31)
end

-- 3. game.* commands ----------------------------------------------------------------------------------------------------
local function cmd(id: string, op: string, args: any?, by: any?)
	return { id = id, op = op, args = args or {}, by = by or { kind = "token" }, exp = (clock + 20) * 1000 }
end
do
	local calls = {}
	api:onDebugCommand(function(name, args, caller)
		table.insert(calls, { name = name, args = args, caller = caller })
		if name == "secret_probe" then
			return { kind = "kv", items = { hook = GAME_SECRET } }
		end
		return { kind = "table", columns = { "a" }, rows = { { args.n or 1 } } }
	end)
	local a = RemoteDebug.run(cmd("g1", "game.round_state", { n = 5 }, { kind = "roblox", userId = OWNER }))
	check("game.*: a declared command runs the generation's handler with (name, args, caller)", a.ok and #calls == 1 and calls[1].name == "round_state" and calls[1].args.n == 5 and calls[1].caller.userId == OWNER and decode(a.json).kind == "table")
	local b = RemoteDebug.run(cmd("g2", "game.kick_all"))
	check("game.*: an undeclared command is refused (op_not_allowed, the handler never runs)", b.ok == false and string.find(b.error, "not declared", 1, true) and #calls == 1, b.error)
	for index, op in { "game.", "game.Round", "game.round_state.x", "games.round_state", "game.round-state", "game." .. string.rep("a", 33) } do
		local refused = RemoteDebug.run(cmd(`gx{index}`, op))
		check(`game.*: a malformed name is refused ({op})`, refused.ok == false and string.find(refused.error, "op_not_allowed", 1, true))
	end
	local c = RemoteDebug.run(cmd("g3", "game.round_state", nil, { kind = "roblox", userId = STRANGER }))
	check("game.*: owners only", c.ok == false and c.error == "owners_only")
	local d = RemoteDebug.run(cmd("g4", "game.round_state", { blob = string.rep("z", 3000) }))
	check("game.*: args over 2 KB of JSON are refused", d.ok == false and string.find(d.error, "bad_args", 1, true) and #calls == 1)
	local e = RemoteDebug.run(cmd("g5", "game.secret_probe"))
	check("game.*: secrets in the answer are scrubbed", e.ok and not string.find(e.json, GAME_SECRET, 1, true) and e.redacted == 1)
	local f = RemoteDebug.run(cmd("g6", "game.no_handler"))
	check("game.*: every declared command reaches the one handler", f.ok)
	api:onDebugCommand(nil)
	local g = RemoteDebug.run(cmd("g7", "game.round_state"))
	check("game.*: no handler: not supported", g.ok == false and string.find(g.error, "not_supported", 1, true))
	api:onDebugCommand(function()
		error(`broke with {KEY}`, 0)
	end)
	local h = RemoteDebug.run(cmd("g8", "game.round_state"))
	check("game.*: a failing handler's error is scrubbed", h.ok == false and not string.find(h.error, KEY, 1, true))
	clock += 60
	local limited = false
	for index = 1, 14 do
		local r = RemoteDebug.run(cmd(`gr{index}`, "game.round_state"))
		limited = limited or (r.ok == false and string.find(r.error, "rate_limited", 1, true) ~= nil)
	end
	check("game.*: the same rate limit as every op", limited)
	clock += 60
	api:onDebugCommand(function(name, args)
		if name == "secret_probe" then
			wait(30)
		end
		return { name = name }
	end)
end

-- 4. Streams while the poll runs -------------------------------------------------------------------------------------------
players = {
	player(77, "Rider", { position = { X = 10.04, Y = 3.96, Z = -20.56 }, look = { X = -1, Y = 0, Z = 0 }, health = 75.55 }),
	player(88, "Ghost", { noCharacter = true }),
	player(99, "Fallen", { health = 0, state = "Dead" }),
}
local samples = { loot = 0, big = 0 }
api:onDebugStream(function(name)
	samples[name] += 1
	if name == "loot" then
		return { points = { { x = 1, y = 2, z = 3, label = `chest {GAME_SECRET}` } } }
	end
	return { blob = string.rep("b", 20000) }
end)
local function streamPosts(from: number?): { any }
	return ofPath("/v1/fleet/streams", from)
end
do
	check("streams: nothing posts while nobody watches", #streamPosts() == 0 and LiveDebug.info().state == "off")
	table.clear(pollAnswers)
	local mark = clock
	RemoteDebug.wake({ rd = 1 })
	advance(5.02)
	local posts = streamPosts(mark)
	check("streams: posts every second while the poll runs", #posts >= 4 and #posts <= 6, #posts)
	local post = posts[2]
	check("streams: POST <backend>/v1/fleet/streams with the key and j", post and post.url == BASE .. "/v1/fleet/streams" and post.headers.Authorization == "Bearer " .. KEY and post.body.j == "job-ld-1")
	local positionFrames, lootFrames, total = 0, 0, 0
	for _, request in posts do
		for _, frame in request.body.frames do
			total += 1
			if frame.s.positions then
				positionFrames += 1
			end
			if frame.s["game.loot"] then
				lootFrames += 1
			end
			check("streams: a frame has t in unix ms", typeof(frame.t) == "number" and frame.t > 1000000)
		end
	end
	check("streams: positions at 2 Hz (about 10 frames in 5 s)", positionFrames >= 9 and positionFrames <= 11, positionFrames)
	check("streams: a custom stream at its own rate (loot 2 Hz) under game.<name>", lootFrames >= 9 and lootFrames <= 11 and samples.loot >= 9, lootFrames)
	check("streams: several frames batched per post", #post.body.frames >= 2)
	local value = nil
	for _, frame in post.body.frames do
		value = value or frame.s.positions
	end
	local rider, ghost, fallen = value.players[1], value.players[2], value.players[3]
	check("positions: u, n, x/y/z to 1 decimal, yaw (0 = -Z), hp, st alive", rider.u == 77 and rider.n == "Rider" and rider.x == 10 and rider.y == 4 and rider.z == -20.6 and math.abs(rider.yaw - math.pi / 2) < 0.01 and rider.hp == 75.6 and rider.st == "alive", encode(rider))
	check("positions: no character is st none without x / y / z", ghost.st == "none" and ghost.x == nil and ghost.u == 88)
	check("positions: dead", fallen.st == "dead" and fallen.hp == 0 and fallen.yaw == 0)
	check("streams: a value over 16 KB is dropped and counted", samples.big >= 4 and LiveDebug.info().oversize >= 4 and not string.find(post.raw, string.rep("b", 100), 1, true))
	check("streams: secrets in custom values are scrubbed", not string.find(post.raw, GAME_SECRET, 1, true) and string.find(post.raw, "<redacted>", 1, true))
	check("streams: every post is at most 64 KB", (function()
		for _, request in posts do
			if #request.raw > Constants.LD_BODY_MAX then
				return false
			end
		end
		return true
	end)())
	check("info: state watch, counters, no URL or key", LiveDebug.info().state == "watch" and LiveDebug.info().posts >= 4 and not string.find(encode(LiveDebug.info()), KEY, 1, true))

	-- A slow stream sampler: left out, counted, the sampler keeps its rate.
	api:onDebugStream(function(name)
		if name == "big" then
			wait(10)
		end
		return { points = {} }
	end)
	mark = clock
	advance(3)
	check("streams: a sampler past LD_STREAM_DEADLINE is left out (counted); posts keep going", LiveDebug.info().sampleTimeouts >= 2 and #streamPosts(mark) >= 2)

	-- The body cap: a burst of frames bigger than 64 KB while a post is in flight keeps the newest.
	-- (Many big values: 8 streams at 4 Hz, 15 KB each.)
	local bigStreams = {}
	for index = 1, 8 do
		table.insert(bigStreams, { name = `fat{index}`, hz = 4 })
	end
	local fatGen, fatApi = newGeneration("gen-fat")
	fatApi:debugDeclare({ streams = bigStreams })
	fatApi:onDebugStream(function()
		return { blob = string.rep("f", 15000) }
	end)
	current = fatGen
	mark = clock
	advance(3)
	local fat = streamPosts(mark)
	local biggest = 0
	for _, request in fat do
		biggest = math.max(biggest, #request.raw)
	end
	check("streams: with 480 KB/s sampled, each body stays at most 64 KB; the overflow is dropped and counted", #fat >= 2 and biggest <= Constants.LD_BODY_MAX and biggest > 40000 and LiveDebug.info().dropped + LiveDebug.info().oversize > 0, biggest)
	current = gen

	-- The poll stops: the streams stop with it.
	table.insert(pollAnswers, { watch = false, commands = {} })
	advance(4)
	mark = clock
	advance(5)
	check("streams: stop when the poll stops", RemoteDebug.info().state == "off" and #streamPosts(mark) == 0 and LiveDebug.info().state == "off")
end

-- 5. Stop rules -------------------------------------------------------------------------------------------------------------
do
	-- A reply saying neither watch nor lm: streams stop although the poll still runs.
	table.clear(pollAnswers)
	RemoteDebug.wake({ rd = 1 })
	advance(2.5)
	table.insert(streamReplies, { ok = true, watch = false, lm = false })
	advance(2)
	local mark = clock
	advance(5)
	check("stop: a reply with neither watch nor lm stops the streams (the poll goes on)", #streamPosts(mark) == 0 and RemoteDebug.info().state == "polling" and LiveDebug.info().stopReason ~= nil)
	-- The poll ends; a new session streams again.
	table.insert(pollAnswers, { watch = false, commands = {} })
	advance(5)
	mark = clock
	RemoteDebug.wake({ rd = 1 })
	advance(3)
	check("stop: a new poll session streams again", #streamPosts(mark) >= 2)

	-- 3 failed posts in a row.
	for _ = 1, 3 do
		table.insert(streamReplies, "netfail")
	end
	advance(4)
	mark = clock
	advance(5)
	check("stop: 3 failed posts in a row stop the streams", #streamPosts(mark) == 0 and string.find(LiveDebug.info().stopReason or "", "3 failed", 1, true), LiveDebug.info().stopReason)
	check("stop: the key never lands in lastError", not string.find(LiveDebug.info().lastError or "", KEY, 1, true))
	table.insert(pollAnswers, { watch = false, commands = {} })
	advance(5)

	-- Two failures then a success: the count resets.
	RemoteDebug.wake({ rd = 1 })
	advance(1.5)
	table.insert(streamReplies, "netfail")
	table.insert(streamReplies, 503)
	advance(5)
	mark = clock
	advance(2)
	check("stop: two failures then a success: still streaming", #streamPosts(mark) >= 1)

	-- watch = false, lm = true: positions only, every LM_INTERVAL.
	table.insert(streamReplies, { ok = true, watch = false, lm = true })
	advance(1.5)
	mark = clock
	advance(9)
	local lmPosts = streamPosts(mark)
	local onlyPositions = true
	for _, request in lmPosts do
		if #request.body.frames ~= 1 then
			onlyPositions = false
		end
		for key in request.body.frames[1].s do
			onlyPositions = onlyPositions and key == "positions"
		end
	end
	check("lm reply: the streams turn into live map mode (one positions frame every 3 s)", #lmPosts >= 2 and #lmPosts <= 4 and onlyPositions and LiveDebug.info().state == "lm", #lmPosts)
	streamDefault = { ok = true, watch = false, lm = false }
	advance(4)
	table.insert(pollAnswers, { watch = false, commands = {} })
	advance(6)
	check("lm: a reply with neither stops it", LiveDebug.info().state == "off")

	-- A 401: stop and hold.
	streamDefault = { ok = true, watch = true, lm = false }
	RemoteDebug.wake({ rd = 1 })
	advance(1.5)
	table.insert(streamReplies, 401)
	advance(2)
	mark = clock
	advance(4)
	check("stop: a 401 stops the streams and holds them off", #streamPosts(mark) == 0 and LiveDebug.info().state == "held")
	check("hold: an lm wake during the hold does nothing", LiveDebug.onWake({ k = "lm" }) == false)
	table.insert(pollAnswers, { watch = false, commands = {} })
	advance(5)
	clock += Constants.LD_AUTH_HOLD + 1
end

-- 6. Live map mode ---------------------------------------------------------------------------------------------------------
do
	LiveDebug._reset()
	streamDefault = { ok = true, watch = false, lm = true }
	check("lm: other wakes are ignored", LiveDebug.onWake({ k = "rd", j = "x" }) == false and LiveDebug.onWake(nil) == false and LiveDebug.onWake("lm") == false)
	local mark = clock
	check("lm: a wake { k = lm } starts live map mode", LiveDebug.onWake({ k = "lm" }) == true)
	advance(9.1)
	local posts = streamPosts(mark)
	check("lm: positions only, one frame every LM_INTERVAL (3 s)", #posts >= 3 and #posts <= 4 and posts[1].body.frames[1].s.positions ~= nil and posts[1].body.frames[1].s["game.loot"] == nil and #posts[1].body.frames == 1, #posts)
	check("lm: frames 3 s apart", posts[2] and math.abs(posts[2].at - posts[1].at - Constants.LM_INTERVAL) < 0.2)
	check("lm: a second wake within LD_LM_WAKE_GAP is ignored (counted)", LiveDebug.onWake({ k = "lm" }) == false and LiveDebug.info().lmIgnored == 1)
	-- Replies keep saying lm: it holds past 60 s.
	advance(70)
	check("lm: replies saying lm keep it going past 60 s", LiveDebug.info().state == "lm")
	-- Replies stop saying lm (but watch, with no poll: lm counts the watch too); then neither.
	streamDefault = { ok = true, watch = true, lm = false }
	table.insert(pollAnswers, { watch = false, commands = {} })
	advance(4)
	check("lm: a watch reply while no poll runs wakes the poll", RemoteDebug.info().sessions >= 1)
	streamDefault = { ok = true, watch = false, lm = false }
	advance(8)
	check("lm: a reply saying neither stops it", LiveDebug.info().state == "off")

	-- The 60 s lapse: replies that aren't JSON neither extend nor stop it.
	streamDefault = "ok"
	clock += Constants.LD_LM_WAKE_GAP
	mark = clock
	LiveDebug.onWake({ k = "lm" })
	advance(30)
	check("lm: replies without lm keep it only until the lapse", LiveDebug.info().state == "lm")
	advance(35)
	local late = streamPosts(clock - 3)
	check("lm: it ends 60 s after the last lm signal", LiveDebug.info().state == "off" and #late == 0, LiveDebug.info().state)

	-- A heartbeat reply with lm = 1 starts it too.
	streamDefault = { ok = true, watch = false, lm = true }
	table.insert(heartbeatReplies, { ok = true, lm = 1 })
	mark = clock
	advance(32)
	check("lm: a heartbeat reply's lm = 1 starts live map mode", LiveDebug.info().state == "lm" and #streamPosts(mark) >= 1)
	streamDefault = { ok = true, watch = false, lm = false }
	advance(5)

	-- No backend / not a live server: nothing.
	LiveDebug.configure({ active = false })
	clock += Constants.LD_LM_WAKE_GAP
	check("lm: not a live server (Studio): ignored", LiveDebug.onWake({ k = "lm" }) == false)
	LiveDebug.configure({ active = true, target = function()
		return nil
	end })
	clock += Constants.LD_LM_WAKE_GAP
	check("lm: no backend in the settings: ignored", LiveDebug.onWake({ k = "lm" }) == false)
	LiveDebug.configure({ target = target })
	-- Closing: nothing new.
	LiveDebug.close()
	clock += Constants.LD_LM_WAKE_GAP
	check("close: no live map after BindToClose", LiveDebug.onWake({ k = "lm" }) == false)
end

-- 7. Closing heartbeat, and the key -------------------------------------------------------------------------------------------
do
	Fleet.closing(2)
	advance(1)
	local closing = ofPath("/v1/fleet/closing")
	check("closing: no xh, x or cv (the generation may be gone)", #closing == 1 and closing[1].body.xh == nil and closing[1].body.cv == nil and closing[1].body.x == nil)
	local leaked = false
	for _, line in output do
		leaked = leaked or string.find(line, KEY, 1, true) ~= nil
	end
	for _, request in requests do
		leaked = leaked or (request.raw ~= nil and string.find(request.raw, KEY, 1, true) ~= nil)
	end
	check("the key never appears in a line or a body", not leaked)
end

print(`live debug: {passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
