-- Smoke test for the whole server kernel (from kernel/): `lune run scripts/smoke-kernel.luau`, then again with
-- `--fallback` (the key asset never loads), `--dev` (a reserved dev-branch server), `--vip` (a non-dev's private server),
-- `--bootstrap`, `--bootstrap-only` (BootstrapHeads), `--blind` (the boot fail-safe), `--empty` (nothing usable) and
-- `--studio-local` (0.3.1: a Studio session mounting ServerStorage.TypeTorchDev.Payload; every other mode has the same
-- folder in ServerStorage and checks that a non-Studio server ignores it), and 0.3.2's `--health` (a reserved dev
-- server: the health window, the last-known-good chain, fleet status and deploy reports, the busy-flag hazard, client
-- reports, onClose, subscribe and private-read retries, revocations unknown), `--health-prod` (the same failures on a
-- signed public server) and `--lkg-boot` (a prod head that fails to start at boot: the signed deployment history,
-- never an unsigned entry), and 0.3.5's `--durable` (deploys no running server heard: the CLI wrote only the DataStore
-- copy; a new server boots it, a running one follows it within one durable read, MemoryStore is written back, and the
-- DataStore read budget holds), and 0.3.6's never-an-empty-server modes (`--hold`, `--hold-optout`, `--peers`,
-- `--peers-untrusted`, `--backup`, `--recover`, `--teleport`, `--bounce`, `--mid-swap`, `--client-fail`,
-- `--kernel-crash`; and the security audit follow-ups `--heads-cap`, `--access`; described at "0.3.6 NEVER AN EMPTY SERVER" below; `--client` covers the client's holding screen and
-- re-sent code), and 0.3.7's `--health-config` (health thresholds per build: custom ones used, bad ones fall back to
-- the defaults, HealthRollback = false keeps a failing build) and `--health-missing` (no Health module: boots, warns),
-- and 0.3.8's `--messaging` (game messaging: one lazy kernel-held TypeTorch/game subscription kept across swaps, dispatch
-- per generation, the mid-swap replay, tags and `to`, publish limits, retries, the universe's rate, the queue, the held
-- roll call topic), `--messaging-studio` (loopback only), `--messaging-missing`, `--client-boot` and `--client-own` (the
-- game's loading screen and the ClientReady signal; `--client` and `--hold` check the new attributes too), and
-- `--settings` / `--settings-missing` (plans/20: the signed settings record replacing ConfigService; `--fleet`,
-- `--switch`, `--access` and `--fallback` read their settings from it too), and `--detached` (api:runDetached: a job
-- outlives its generation's hard stop; errors, the cap and the slow-job warning), and 0.3.9's `--rollback-prev`
-- (/tt rollback on a server with no earlier generation: the branch's previous heads, only verified ones on a signed
-- server; the kernel's durable writes keep `prev`); `--hold`, `--client` and `--switch` check the 0.3.9 hold fixes and
-- the channel / rules split too.
-- Every mode also checks that no swap ran on a thread its own stopped generation owned.
-- Boots the real src/server/*.luau as a PUBLIC (prod) server under Lune, with a small Instance emulator and stubbed
-- services (InsertService, MessagingService, DataStore, MemoryStore; 0.3.8: no ConfigService at all), then drives it:
-- signed / unsigned / dev-channel / replayed deploy messages, a payload holding a Script (S-L4), a payload that fails to
-- load twice (P-K2 retries), a rollback, unsigned and signed pins, a key rotation after a rekey hint, and a message
-- signed with a revoked key. Messages are signed with the throwaway plans/03 test keys (scripts/smoke-signatures.json,
-- made with node:crypto); a forged high-seq head in MemoryStore must not shadow the signed one in the DataStore.
-- This is not Roblox: no replication, no real scheduler, Script.Enabled just runs the source. It catches nil calls,
-- wrong order and broken rules before a place publish (a kernel bug costs a restart).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local failures, passes = 0, 0
local function check(name: string, condition: any)
	if condition then
		passes += 1
		print(`ok    {name}`)
	else
		failures += 1
		print(`FAIL  {name}`)
	end
end

local output = {} -- everything the kernel printed or warned
local VERBOSE = table.find(process.args, "--verbose") ~= nil
-- A main thread that dies would leave the kernel's loops running forever: give up after 5 minutes.
task.delay(300, function()
	print("smoke: timed out (the test thread probably errored; run with --verbose)")
	process.exit(2)
end)

-- 0.3.2 boot budget: `--boot-scenario <name>` runs one boot with simulated latencies, and time runs 1/SCALE times
-- faster (the kernel's timing constants and every simulated delay are scaled the same way), so 15 simulated seconds
-- take 7.5 s. Faster distorts: every wait on this machine takes at least ~15 ms of real time. LATENCY[op] = simulated seconds, or { hang = true } (never answers), or { fail = true, after = s }.
local BOOT_SCENARIO = (function()
	local index = table.find(process.args, "--boot-scenario")
	return if index then process.args[index + 1] else nil
end)()
local SCALE = if BOOT_SCENARIO then 0.5 else 1
local LATENCY = {}
local function simWait(op: string)
	local value = LATENCY[op]
	if value == nil then
		return
	end
	if type(value) == "number" then
		task.wait(value * SCALE)
	elseif value.hang then
		task.wait(1e6)
	elseif value.fail then
		task.wait((value.after or 0) * SCALE)
		error(`{op} failed (smoke)`)
	end
end

-- Thread ownership (0.3.2), as on Roblox: a thread belongs to the script whose thread started it (task.spawn/defer/
-- delay inherit it; a signal handler belongs to the script that connected it), and disabling a Script kills its
-- threads. The kernel's hard stop (Entry.Enabled = false) relies on this, and the busy-flag hazard is a swap running on
-- a thread the stopped generation owns: such a thread is "doomed" (it never resumes after its next task.wait) and
-- counted in `hazards`. Errors in owned threads fire ScriptContext.Error(message, trace, owner script).
local ownerOf = setmetatable({}, { __mode = "k" }) -- thread -> script instance
local threadsOf = setmetatable({}, { __mode = "k" }) -- script -> { [thread] = true }
local doomed = setmetatable({}, { __mode = "k" })
local hazards = {} -- names of scripts disabled while one of their own threads was running
local threadErrors = {} -- { owner, text } of every error in an owned thread
local fireScriptError: (string, string, any) -> () = function() end

local function ownedThread(owner, fn, noErrorEvent: boolean?): thread
	local thread = coroutine.create(function(...)
		local ok, err = xpcall(fn, function(e)
			return { message = tostring(e), trace = debug.traceback(tostring(e), 2) }
		end, ...)
		if not ok then
			local message = if type(err) == "table" then err.message else tostring(err)
			table.insert(threadErrors, { owner = owner, text = message })
			table.insert(output, { kind = "error", text = message })
			if VERBOSE then
				print(`  [error] {message}`)
			end
			if not noErrorEvent then
				fireScriptError(message, if type(err) == "table" then err.trace else "", owner)
			end
		end
	end)
	if owner then
		ownerOf[thread] = owner
		threadsOf[owner] = threadsOf[owner] or setmetatable({}, { __mode = "k" })
		threadsOf[owner][thread] = true
	end
	return thread
end

-- The `task` library scripts see: new threads are owned by the current thread's owner; a doomed thread stops at its
-- next wait.
local ownedTask = {
	spawn = function(fn, ...)
		if type(fn) == "thread" then
			return task.spawn(fn, ...)
		end
		return task.spawn(ownedThread(ownerOf[coroutine.running()], fn), ...)
	end,
	defer = function(fn, ...)
		if type(fn) == "thread" then
			return task.defer(fn, ...)
		end
		return task.defer(ownedThread(ownerOf[coroutine.running()], fn), ...)
	end,
	delay = function(seconds, fn, ...)
		if type(fn) == "thread" then
			return task.delay(seconds, fn, ...)
		end
		return task.delay(seconds, ownedThread(ownerOf[coroutine.running()], fn), ...)
	end,
	wait = function(seconds)
		local me = coroutine.running()
		if doomed[me] then
			coroutine.yield() -- killed: never resumed
		end
		local waited = task.wait(seconds)
		if doomed[me] then
			coroutine.yield()
		end
		return waited
	end,
	cancel = task.cancel,
}

-- Instance emulator ------------------------------------------------------------------------------------------------

local internals = setmetatable({}, { __mode = "k" })
local Methods = {}
local instanceMeta = {}
local onScriptEnabled: (any) -> () = function() end
local onScriptDisabled: (any) -> () = function() end
local GAME_ROOT = nil -- the DataModel stand-in (set below)

-- Handlers run deferred (Roblox's default SignalBehavior) on a thread owned by the script that connected them.
local function signal(noErrorEvent: boolean?)
	local handlers = {}
	local object = {}
	function object:Connect(fn)
		local entry = { fn = fn, on = true, owner = ownerOf[coroutine.running()] }
		table.insert(handlers, entry)
		return {
			Disconnect = function()
				entry.on = false
			end,
		}
	end
	function object:Fire(...)
		for _, entry in table.clone(handlers) do
			if entry.on then
				task.defer(ownedThread(entry.owner, entry.fn, noErrorEvent), ...)
			end
		end
	end
	return object
end

local SIGNALS = { Event = true, OnServerEvent = true, OnClientEvent = true, Triggered = true }
local firedToServer = {} -- 0.3.2 `--client`: every RemoteEvent:FireServer call ({ remote name, args... })
local kicked = {} -- names of players Kick was called on
local kickMessages = {} -- 0.3.6: name -> the Kick message
local loadedCharacters = {} -- 0.3.6: names of players LoadCharacter was called on

local function newInstance(className: string, name: string?)
	local self = setmetatable({}, instanceMeta)
	internals[self] = {
		props = { ClassName = className, Name = name or className, Enabled = className ~= "Script" },
		children = {},
		attributes = {},
		signals = {},
	}
	return self
end

instanceMeta.__index = function(self, key)
	local inner = internals[self]
	if Methods[key] then
		return Methods[key]
	end
	local value = inner.props[key]
	if value ~= nil then
		return value
	end
	if SIGNALS[key] then
		inner.signals[key] = inner.signals[key] or signal()
		return inner.signals[key]
	end
	for _, child in inner.children do
		if internals[child].props.Name == key then
			return child
		end
	end
	return nil
end

instanceMeta.__newindex = function(self, key, value)
	local inner = internals[self]
	if key == "Parent" then
		local old = inner.props.Parent
		if old then
			local siblings = internals[old].children
			local index = table.find(siblings, self)
			if index then
				table.remove(siblings, index)
			end
		end
		inner.props.Parent = value
		if value then
			table.insert(internals[value].children, self)
		end
		return
	end
	local was = inner.props[key]
	inner.props[key] = value
	if key == "Enabled" and value == true and was ~= true and inner.props.ClassName == "Script" then
		onScriptEnabled(self)
	elseif key == "Enabled" and value == false and was == true and inner.props.ClassName == "Script" then
		onScriptDisabled(self)
	end
end

instanceMeta.__tostring = function(self)
	return internals[self].props.Name
end

function Methods.FindFirstChild(self, name, recursive)
	for _, child in internals[self].children do
		if internals[child].props.Name == name then
			return child
		end
	end
	if recursive then
		for _, child in internals[self].children do
			local found = child:FindFirstChild(name, true)
			if found then
				return found
			end
		end
	end
	return nil
end

function Methods.WaitForChild(self, name, timeout)
	local child = self:FindFirstChild(name)
	if not child and type(timeout) == "number" then
		local deadline = os.clock() + timeout * SCALE
		while not child and os.clock() < deadline do
			task.wait(0.02)
			child = self:FindFirstChild(name)
		end
		return child
	end
	if not child then
		error(`smoke: {self:GetFullName()} has no child {name}`, 2)
	end
	return child
end

function Methods.FindFirstChildOfClass(self, className)
	for _, child in internals[self].children do
		if internals[child].props.ClassName == className then
			return child
		end
	end
	return nil
end

function Methods.GetChildren(self)
	return table.clone(internals[self].children)
end

function Methods.GetDescendants(self)
	local list = {}
	for _, child in internals[self].children do
		table.insert(list, child)
		for _, inner in child:GetDescendants() do
			table.insert(list, inner)
		end
	end
	return list
end

local ISA = {
	Instance = function()
		return true
	end,
	LuaSourceContainer = function(class)
		return class == "Script" or class == "ModuleScript"
	end,
	BaseScript = function(class)
		return class == "Script"
	end,
}

function Methods.IsA(self, class)
	local own = internals[self].props.ClassName
	return own == class or (ISA[class] ~= nil and ISA[class](own))
end

function Methods.Clone(self)
	local inner = internals[self]
	local copy = newInstance(inner.props.ClassName, inner.props.Name)
	local copyInner = internals[copy]
	for key, value in inner.props do
		if key ~= "Parent" then
			copyInner.props[key] = value
		end
	end
	copyInner.attributes = table.clone(inner.attributes)
	copyInner.sourcePath = inner.sourcePath
	copyInner.sourceText = inner.sourceText
	for _, child in inner.children do
		child:Clone().Parent = copy
	end
	return copy
end

function Methods.Destroy(self)
	self.Parent = nil
	internals[self].destroyed = true
end

function Methods.SetAttribute(self, name, value)
	local inner = internals[self]
	local before = inner.attributes[name]
	inner.attributes[name] = value
	local changed = inner.attributeSignals and inner.attributeSignals[name]
	if changed and before ~= value then
		changed:Fire()
	end
end

function Methods.GetAttributeChangedSignal(self, name)
	local inner = internals[self]
	inner.attributeSignals = inner.attributeSignals or {}
	inner.attributeSignals[name] = inner.attributeSignals[name] or signal()
	return inner.attributeSignals[name]
end

function Methods.Kick(self, message)
	table.insert(kicked, internals[self].props.Name)
	kickMessages[internals[self].props.Name] = message
end

-- 0.3.6: the hold's release spawns waiting players; moves read the bounce count from the join data.
function Methods.LoadCharacter(self)
	table.insert(loadedCharacters, internals[self].props.Name)
	internals[self].props.Character = newInstance("Model", internals[self].props.Name)
end

function Methods.GetJoinData(self)
	return internals[self].props.JoinData or {}
end

function Methods.SetTeleportData(self, data)
	internals[self].props.TeleportData = data
end

function Methods.GetTeleportData(self)
	return internals[self].props.TeleportData
end

function Methods.FireServer(self, ...)
	table.insert(firedToServer, { internals[self].props.Name, ... })
end

function Methods.GetAttribute(self, name)
	return internals[self].attributes[name]
end

function Methods.IsDescendantOf(self, ancestor)
	local node = internals[self].props.Parent
	while node do
		if node == ancestor then
			return true
		end
		node = internals[node].props.Parent
	end
	return false
end

function Methods.GetFullName(self)
	local parent = internals[self].props.Parent
	local name = internals[self].props.Name
	return if parent and parent ~= GAME_ROOT then `{parent:GetFullName()}.{name}` else name
end

local firedToClient = {} -- 0.3.2: every RemoteEvent:FireClient call ({ player, args... })
function Methods.FireClient(_, player, ...)
	table.insert(firedToClient, { player, ... })
end
function Methods.FireAllClients() end
function Methods.Fire(self, ...)
	self.Event:Fire(...)
end

local function isInstance(value): boolean
	return type(value) == "table" and internals[value] ~= nil
end

local function robloxTypeof(value): string
	if isInstance(value) then
		return "Instance"
	end
	return typeof(value)
end

-- Scripts and require ----------------------------------------------------------------------------------------------

local SMOKE = { boots = {}, stops = {}, closed = {}, behave = {}, messages = {}, heard = {}, disconnects = {}, task = ownedTask }
-- 0.3.8 (plans/20): signed settings records, made by the CLI with the public plans/03 test keys
-- (cli/test/fixtures/settings-fixtures.ts; the CLI's tests check it still signs them byte for byte).
SMOKE.settings = serde.decode("json", fs.readFile("scripts/smoke-settings.json"))
local moduleCache = {}
local game

local function hook(kind: string)
	return function(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[index] = tostring((select(index, ...)))
		end
		local line = table.concat(parts, " ")
		table.insert(output, { kind = kind, text = line })
		if VERBOSE then
			print(`  [{kind}] {line}`)
		end
		if SMOKE.logOut then
			SMOKE.logOut(line, kind) -- 0.3.9: LogService.MessageOut, so the kernel's log rings fill as on Roblox
		end
	end
end

local DateTimeMock
-- Enum members the kernel compares are fixed; any other (Font, EasingStyle, ...) is a "Enum.X.Y" string (0.3.6 UI).
local Enum = setmetatable({
	CreatorType = { User = "CreatorType.User", Group = "CreatorType.Group" },
	MessageType = { MessageOutput = 1, MessageInfo = 2, MessageWarning = 3, MessageError = 4 },
}, {
	__index = function(_, kind)
		return setmetatable({}, {
			__index = function(_, member)
				return `Enum.{kind}.{member}`
			end,
		})
	end,
})
-- 0.3.6: the datatypes the client's holding screen uses (plain tables here).
local DATATYPES = {
	UDim2 = {
		new = function(xs, xo, ys, yo)
			return { xs = xs, xo = xo, ys = ys, yo = yo }
		end,
		fromScale = function(x, y)
			return { xs = x, xo = 0, ys = y, yo = 0 }
		end,
		fromOffset = function(x, y)
			return { xs = 0, xo = x, ys = 0, yo = y }
		end,
	},
	Color3 = {
		fromRGB = function(r, g, b)
			return { r = r, g = g, b = b }
		end,
	},
	Vector2 = {
		new = function(x, y)
			return { x = x, y = y }
		end,
	},
	TweenInfo = {
		new = function(...)
			return { ... }
		end,
	},
}

local requireInstance

local function resolve(fromScript, path: string)
	local parts = string.split(path, "/")
	local node
	if parts[1] == "." then
		node = fromScript.Parent
	elseif parts[1] == ".." then
		node = fromScript.Parent.Parent
	elseif parts[1] == "@self" then
		node = fromScript
	else
		error(`smoke: unsupported require "{path}"`)
	end
	for index = 2, #parts do
		if parts[index] == ".." then
			node = node.Parent
		else
			node = node:FindFirstChild(parts[index]) or error(`smoke: require "{path}" from {fromScript:GetFullName()}: no {parts[index]}`)
		end
	end
	return node
end

local BASE_GLOBALS = {
	math = math, string = string, table = table, buffer = buffer, bit32 = bit32, os = os, coroutine = coroutine,
	utf8 = utf8, pcall = pcall, xpcall = xpcall, error = error, assert = assert, tostring = tostring,
	tonumber = tonumber, type = type, setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget,
	rawset = rawset, rawequal = rawequal, rawlen = rawlen, ipairs = ipairs, pairs = pairs, next = next,
	select = select, unpack = table.unpack, debug = debug,
	collectgarbage = function()
		return 0
	end,
}

local function runSource(scriptInstance)
	local inner = internals[scriptInstance]
	local source = inner.sourceText or fs.readFile(inner.sourcePath)
	local env = setmetatable({
		script = scriptInstance,
		game = game,
		workspace = nil,
		require = function(target)
			if type(target) == "string" then
				return requireInstance(resolve(scriptInstance, target))
			end
			return requireInstance(target)
		end,
		typeof = robloxTypeof,
		Instance = {
			new = function(className)
				return newInstance(className)
			end,
		},
		DateTime = DateTimeMock,
		Enum = Enum,
		UDim2 = DATATYPES.UDim2,
		Color3 = DATATYPES.Color3,
		Vector2 = DATATYPES.Vector2,
		TweenInfo = DATATYPES.TweenInfo,
		task = ownedTask,
		warn = hook("warn"),
		print = hook("print"),
		SMOKE = SMOKE,
	}, { __index = BASE_GLOBALS })
	local chunk = luau.load(source, { debugName = inner.sourcePath or scriptInstance:GetFullName(), environment = env })
	return chunk()
end

requireInstance = function(moduleInstance)
	assert(isInstance(moduleInstance), "smoke: require of a non-instance")
	local cached = moduleCache[moduleInstance]
	if cached ~= nil then
		return cached
	end
	local result = runSource(moduleInstance)
	moduleCache[moduleInstance] = result
	return result
end

local scriptErrors = {}
-- A Script's own top-level thread (owned by it).
local function runScript(scriptInstance, onError: ((string) -> ())?)
	task.spawn(ownedThread(scriptInstance, function()
		local ok, err = pcall(runSource, scriptInstance)
		if not ok then
			table.insert(scriptErrors, `{scriptInstance:GetFullName()}: {err}`)
			if onError then
				onError(tostring(err))
			end
		end
	end))
end
onScriptEnabled = function(scriptInstance)
	runScript(scriptInstance)
end
-- Disabling a Script kills its threads: waiting ones are cancelled; the running one (and any that resumed it) die at
-- their next wait. A disabled script whose own thread is the running one is the busy-flag hazard.
onScriptDisabled = function(scriptInstance)
	local me = coroutine.running()
	if ownerOf[me] == scriptInstance then
		table.insert(hazards, internals[scriptInstance].props.Name)
	end
	for thread in threadsOf[scriptInstance] or {} do
		local state = coroutine.status(thread)
		if thread == me or state == "normal" then
			doomed[thread] = true
		elseif state == "suspended" then
			pcall(task.cancel, thread)
		end
	end
end

-- Services -----------------------------------------------------------------------------------------------------------

local BASE_MS = 1759580200000
local startClock = os.clock()
local function nowMs(): number
	return BASE_MS + math.floor((os.clock() - startClock) * 1000)
end
local function dateTime(ms: number)
	return {
		UnixTimestampMillis = ms,
		ToIsoDate = function()
			return os.date("!%Y-%m-%dT%H:%M:%SZ", ms // 1000)
		end,
	}
end
DateTimeMock = {
	now = function()
		return dateTime(nowMs())
	end,
	fromUnixTimestampMillis = function(ms)
		assert(type(ms) == "number", "fromUnixTimestampMillis needs a number")
		return dateTime(ms)
	end,
}

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in value do
		copy[key] = deepCopy(inner)
	end
	return copy
end

local function keyValueStore()
	local data = {}
	local store = { data = data, failGets = {}, reads = {} } -- failGets[key] = n: the next n reads of key throw
	function store:GetAsync(key)
		self.reads[key] = (self.reads[key] or 0) + 1 -- 0.3.5 `--durable`: the read budget
		simWait(if self.latencyName == "memory" then "memoryGet" elseif string.sub(tostring(key), 1, 8) == "private/" then "privateGet" elseif key == "settings" then "settingsGet" else "datastoreGet")
		if (self.failGets[key] or 0) > 0 then
			self.failGets[key] -= 1
			error("DataStore request failed (smoke)")
		end
		return deepCopy(data[key])
	end
	function store:SetAsync(key, value)
		data[key] = deepCopy(value)
	end
	function store:UpdateAsync(key, transform)
		local new = transform(deepCopy(data[key]))
		if new ~= nil then
			data[key] = deepCopy(new)
		end
		return new
	end
	return store
end

local dataStore = keyValueStore()
local memoryStore = keyValueStore()
memoryStore.latencyName = "memory"
-- 0.3.2: the kernel never uses a MemoryStore sorted map (fleet status and deploy reports are API only); finish()
-- checks that nothing asked for one.
local sortedMapRequests = {}
local function sortedMap(name: string)
	table.insert(sortedMapRequests, name)
	error(`smoke: the kernel asked for MemoryStore sorted map {name}`)
end
local topics = {}
local subscribeFailures = {} -- topic -> number of SubscribeAsync calls that fail first
-- 0.3.8: SubscribeAsync calls per topic, the script whose thread made the last one (a generation's hard stop ends the
-- subscriptions its threads made on Roblox), and PublishAsync calls that fail first, per topic.
local msgStub = { calls = {}, owners = {}, publishFailures = {} }
local assets = {}
local assetVersions = {} -- version -> asset id
local closeCallbacks = {} -- game:BindToClose
local fakePlayers = {} -- 0.3.4 `--switch`: the players in this server
-- 0.3.2 fleet API: every RequestAsync ({ url, method, headers, body (decoded), status }); `httpScript` = status codes
-- (or "error") for the next requests, then 200.
local httpRequests = {}
local httpScript = {}
local FLEET_TOKEN = "smoke-fleet-token-0123456789abcdef"
-- 0.3.6: MessagingService publishes ({ topic, data (decoded) }); `peerReplies` answers the kernel's roll call ask with
-- these rows (each { delay?, row }), as other kernels would; teleports ({ placeId, players (names), options props });
-- `teleportFails` = errors for the next TeleportAsync calls; Players attributes; reserved servers made.
local published = {}
local peerReplies = {}
local teleports = {}
local teleportFails = 0
local playersAttributes = {}
local reservedServers = {}

local GAME_ROOT_PROPS = {
	JobId = "smoke-job-0001",
	PlaceId = 42,
	PlaceVersion = 7,
	PrivateServerId = "",
	PrivateServerOwnerId = 0,
	CreatorType = Enum.CreatorType.User,
	CreatorId = 1,
}

local services = {
	ReplicatedStorage = newInstance("ReplicatedStorage"),
	ServerScriptService = newInstance("ServerScriptService"),
	ServerStorage = newInstance("ServerStorage"),
	TextChatService = newInstance("TextChatService"),
	ReplicatedFirst = newInstance("ReplicatedFirst"),
	LogService = { MessageOut = signal(true) },
	RunService = {
		IsStudio = function()
			return table.find(process.args, "--studio-local") ~= nil or table.find(process.args, "--messaging-studio") ~= nil
		end,
	},
	Stats = {
		GetTotalMemoryUsageMb = function()
			return 0
		end,
	},
	HttpService = {
		JSONEncode = function(_, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_, text)
			return serde.decode("json", text)
		end,
		RequestAsync = function(_, request)
			local scripted = table.remove(httpScript, 1)
			local entry = { url = request.Url, method = request.Method, headers = request.Headers, body = serde.decode("json", request.Body), status = if scripted == "error" then 0 else scripted or 200 }
			table.insert(httpRequests, entry)
			if scripted == "error" then
				error("HttpError: ConnectFail (smoke)")
			end
			return { Success = entry.status >= 200 and entry.status < 300, StatusCode = entry.status, Body = "{}" }
		end,
	},
	Players = {
		MaxPlayers = 10,
		CharacterAutoLoads = true, -- 0.3.6: the hold turns it off until a generation is ready
		GetAttribute = function(_, name)
			return playersAttributes[name]
		end,
		PlayerAdded = signal(),
		PlayerRemoving = signal(),
		GetPlayers = function()
			return table.clone(fakePlayers)
		end,
		GetPlayerByUserId = function(_, userId)
			for _, player in fakePlayers do
				if player.UserId == userId then
					return player
				end
			end
			return nil
		end,
	},
	MessagingService = {
		SubscribeAsync = function(_, topic, fn)
			msgStub.calls[topic] = (msgStub.calls[topic] or 0) + 1
			msgStub.owners[topic] = ownerOf[coroutine.running()]
			if (subscribeFailures[topic] or 0) > 0 then
				subscribeFailures[topic] -= 1
				error("MessagingService unavailable (smoke)")
			end
			topics[topic] = fn
			return {
				Disconnect = function()
					if topics[topic] == fn then
						topics[topic] = nil
					end
				end,
			}
		end,
		-- 0.3.6: like Roblox, the publisher's own subscription hears the message too; a roll call ask is answered with
		-- `peerReplies` on the asker's reply topic.
		PublishAsync = function(_, topic, data)
			simWait("publish")
			if (msgStub.publishFailures[topic] or 0) > 0 then
				msgStub.publishFailures[topic] -= 1
				error("MessagingService: request throttled (smoke)")
			end
			assert(type(data) ~= "string" or #data <= 1024, `smoke: a message over 1 KiB on {topic} ({#data} bytes)`)
			local decoded = serde.decode("json", data)
			local subscribed = 0
			for _ in topics do
				subscribed += 1
			end
			table.insert(published, { topic = topic, data = decoded, at = os.clock(), topics = subscribed })
			if topics[topic] then
				task.spawn(topics[topic], { Data = data, Sent = os.time() })
			end
			if topic == "TypeTorch/deploy" and type(decoded) == "table" and decoded.rc == 1 then
				for _, reply in peerReplies do
					task.delay((reply.delay or 0.1) * SCALE, function()
						local row = table.clone(reply.row)
						row.q = decoded.q
						local handler = topics[`TypeTorch/peers/{decoded.j}`]
						if handler then
							handler({ Data = serde.encode("json", row), Sent = os.time() })
						end
					end)
				end
			end
		end,
	},
	ScriptContext = { Error = signal(true) },
	-- 0.3.6: tweens land at once; Completed fires a moment later (after the caller connected).
	TweenService = {
		Create = function(_, instance, _info, goal)
			local completed = signal()
			return {
				Completed = completed,
				Play = function()
					for key, value in goal do
						instance[key] = value
					end
					task.delay(0.01, function()
						completed:Fire()
					end)
				end,
			}
		end,
	},
	DataStoreService = {
		GetDataStore = function()
			return dataStore
		end,
	},
	MemoryStoreService = {
		GetHashMap = function()
			return memoryStore
		end,
		GetSortedMap = function(_, name)
			return sortedMap(name)
		end,
	},
	BadgeService = {
		UserHasBadgeAsync = function()
			simWait("badge")
			return false
		end,
	},
	GroupService = {
		GetGroupsAsync = function()
			simWait("groups")
			return {}
		end,
	},
	TeleportService = {
		-- 0.3.6: moves. Records every call; `teleportFails` makes the next calls throw.
		TeleportAsync = function(_, placeId, players, options)
			local names = {}
			for _, player in players do
				table.insert(names, player.Name)
			end
			local props = internals[options] and table.clone(internals[options].props) or {}
			table.insert(teleports, { placeId = placeId, players = names, options = props, at = os.clock() })
			if teleportFails > 0 then
				teleportFails -= 1
				error("TeleportAsync failed (smoke)")
			end
			return {}
		end,
		ReserveServer = function(_, placeId)
			local n = #reservedServers + 1
			table.insert(reservedServers, { placeId = placeId, code = `code-{n}`, id = `ps-new-{n}` })
			return `code-{n}`, `ps-new-{n}`
		end,
	},
	InsertService = {
		LoadAsset = function(_, id)
			local asset = assets[id] or error(`smoke: asset {id} not found`)
			asset.loads = (asset.loads or 0) + 1
			if id == 500 then
				simWait("keyLoad")
			else
				simWait("payloadLoad")
				if (asset.hangLoads or 0) > 0 then
					asset.hangLoads -= 1
					task.wait(1e6)
				end
			end
			if asset.failLoads > 0 then
				asset.failLoads -= 1
				error("HTTP 500 (smoke)")
			end
			local container = newInstance("Model", "Model")
			asset.build().Parent = container
			return container
		end,
		GetLatestAssetVersionAsync = function(_, id)
			if id == 500 then
				simWait("keyVersion")
			end
			local asset = assets[id] or error(`smoke: asset {id} not found`)
			return asset.version
		end,
		LoadAssetVersion = function(self, version)
			local id = assetVersions[version] or error(`smoke: version {version} not found`)
			return self:LoadAsset(id)
		end,
	},
}

GAME_ROOT = newInstance("DataModel", "game")
fireScriptError = function(message, trace, owner)
	services.ScriptContext.Error:Fire(message, trace, owner)
end
game = setmetatable({}, {
	__index = function(_, key)
		if key == "GetService" then
			return function(_, name)
				return services[name] or error(`smoke: no service {name}`)
			end
		elseif key == "BindToClose" then
			return function(_, fn)
				table.insert(closeCallbacks, fn)
			end
		end
		return GAME_ROOT_PROPS[key]
	end,
})
for _, name in { "ReplicatedStorage", "ServerScriptService", "ServerStorage", "TextChatService", "ReplicatedFirst" } do
	services[name].Parent = GAME_ROOT
end

-- The kernel's place tree (as place.project.json maps it) --------------------------------------------------------

local function sourceInstance(className: string, name: string, path: string)
	local instance = newInstance(className, name)
	internals[instance].sourcePath = path
	return instance
end

local kernelFolder = newInstance("Folder", "TypeTorchKernel")
kernelFolder.Parent = services.ServerScriptService
for name, file in { Kernel = "Kernel.server.luau", Api = "Api.luau", Access = "Access.luau", Logs = "Logs.luau", Registry = "Registry.luau", Fleet = "Fleet.luau", Fallback = "Fallback.luau", Health = "Health.luau", Messaging = "Messaging.luau", Budget = "Budget.luau", Errors = "Errors.luau", Settings = "Settings.luau", Transport = "Transport.luau", Signing = "Signing.luau" } do
	sourceInstance(if name == "Kernel" then "Script" else "ModuleScript", name, `src/server/{file}`).Parent = kernelFolder
end
local entryTemplate = sourceInstance("Script", "Entry", "src/server/Entry.server.luau")
entryTemplate.Parent = kernelFolder
local vendor = newInstance("Folder", "vendor")
vendor.Parent = kernelFolder
local ed = newInstance("Folder", "ed25519")
ed.Parent = vendor
for _, file in fs.readDir("src/server/vendor/ed25519") do
	if string.sub(file, -5) == ".luau" then
		sourceInstance("ModuleScript", string.sub(file, 1, -6), `src/server/vendor/ed25519/{file}`).Parent = ed
	end
end
local shared = newInstance("Folder", "TypeTorchKernelShared")
shared.Parent = services.ReplicatedStorage
sourceInstance("ModuleScript", "Constants", "src/shared/Constants.luau").Parent = shared

-- Trust roots and build identity, as `typetorch kernel deploy` stamps them.
local FALLBACK = "mb6ZhKXQSzn2N+Xzle+xv1IuOLNWfQrtvifYYBknu0E="
local MAIN = "ErlwbCHDCN4WvDHY6l3plaeihIONuatx2jjqoqXZiq4="
local ROTATED = "3Kvcf4gIFRT+mcefCGeN+CNctoEb/DJK+YO9EfF4TEI="
kernelFolder:SetAttribute("KeyAssetId", "500")
kernelFolder:SetAttribute("FallbackPublicKey", FALLBACK)
kernelFolder:SetAttribute("KernelCommit", "abc1234")
kernelFolder:SetAttribute("KernelHash", "0123456789abcdef")

-- Assets -------------------------------------------------------------------------------------------------------------

local nextVersion = 9000
local function addAsset(id: number, build, failLoads: number?)
	nextVersion += 1
	assets[id] = { build = build, failLoads = failLoads or 0, version = nextVersion }
	assetVersions[nextVersion] = id
end
local function bumpVersion(id: number)
	nextVersion += 1
	assets[id].version = nextVersion
	assetVersions[nextVersion] = id
end

local keyAsset = { publicKeys = MAIN, revokedKeys = "" }
addAsset(500, function()
	local model = newInstance("Model", "TypeTorchKeys")
	model:SetAttribute("PublicKeys", keyAsset.publicKeys)
	model:SetAttribute("RevokedKeys", keyAsset.revokedKeys)
	return model
end)

-- `--dev`: a reserved server on branch "dev" (dev channel): unsigned deploys still work there.
-- `--vip`: a player-owned private server whose stored branch says "dev", owned by a non-dev: it must stay on prod.
local DEV_MODE = table.find(process.args, "--dev") ~= nil
local VIP_MODE = table.find(process.args, "--vip") ~= nil
-- 0.3.2: `--health` (a reserved dev server: health window, last known good, reports, heartbeat, busy flag, client
-- reports, onClose, retries), `--health-prod` (the same rules on a signed public server), `--lkg-boot` (a public
-- server whose head fails to start at boot: the branch's signed deployment history, never an unsigned entry).
-- `--client` (0.3.2, P-K7): runs the CLIENT kernel instead: a generation that fails once is retried on a fresh copy
-- of its tree and reported to the server; one that keeps failing is reported as failed.
local CLIENT_MODE = table.find(process.args, "--client") ~= nil or table.find(process.args, "--client-boot") ~= nil or table.find(process.args, "--client-own") ~= nil
-- 0.3.6: the kernel client script in ReplicatedFirst (server modes: a stand-in that only carries the `Hold` attribute).
local clientStandIn = nil
if not CLIENT_MODE then
	clientStandIn = newInstance("LocalScript", "TypeTorchKernelClient")
	clientStandIn.Parent = services.ReplicatedFirst
end
-- `--fleet` (0.3.2): the settings hold `fleet` (0.3.8; ConfigService TypeTorchFleet before), so the kernel sends its fleet data over HTTP (stubbed): a
-- reserved dev server whose head fails to start (nothing runs: the alerts and heartbeats still go out), then recovers.
local FLEET_MODE = table.find(process.args, "--fleet") ~= nil
-- `--switch` (0.3.4): the owner switches a public prod server to dev and back, loads builds here; Reload and Rollback
-- keep working; no admins (a member with the old role "admin" is a dev); members with role "owner" are owners.
local SWITCH_MODE = table.find(process.args, "--switch") ~= nil
if SWITCH_MODE then
	-- 0.3.8: the signed settings record (was ConfigService TypeTorchFleet + the TypeTorch registry key).
	dataStore.data.settings = deepCopy(SMOKE.settings.switch)
end
local HEALTH_MODE = table.find(process.args, "--health") ~= nil
-- `--durable` (0.3.5): a reserved dev server and deploys that only the DataStore copy holds (the CLI wrote it).
local DURABLE_MODE = table.find(process.args, "--durable") ~= nil
local HEALTH_PROD_MODE = table.find(process.args, "--health-prod") ~= nil
local LKG_BOOT_MODE = table.find(process.args, "--lkg-boot") ~= nil
-- `--health-config` (0.3.7): a reserved dev server whose builds carry their own health thresholds (HealthErrors,
-- HealthWindow, HealthRollback on the payload root): custom ones are used, bad ones fall back to the defaults, and
-- HealthRollback = false keeps a failing build running (degraded). `--health-missing`: a place project without the
-- Health module still boots (no window) and says so.
local HEALTH_CONFIG_MODE = table.find(process.args, "--health-config") ~= nil
local HEALTH_MISSING_MODE = table.find(process.args, "--health-missing") ~= nil
-- 0.3.8 game messaging (plans/19 item 4): `--messaging` (a public prod server: one lazy subscription to TypeTorch/game
-- held across swaps, dispatch per generation, the mid-swap replay, the sender's tags and `to`, publish limits, retries,
-- the universe's rate, the queue, the held roll call topic), `--messaging-studio` (Studio: loopback only, no
-- MessagingService) and `--messaging-missing` (a place project without Messaging.luau boots; no messaging methods).
-- (One table: the harness's main chunk is at Luau's 200-local limit.)
local MODES38 = {
	messaging = table.find(process.args, "--messaging") ~= nil,
	messagingStudio = table.find(process.args, "--messaging-studio") ~= nil,
	messagingMissing = table.find(process.args, "--messaging-missing") ~= nil,
	clientBoot = table.find(process.args, "--client-boot") ~= nil,
	clientOwn = table.find(process.args, "--client-own") ~= nil,
	-- plans/20: `--settings` (the signed record: read at boot, a ping re-reads, a bad signature, an older seq, unsigned
	-- and missing records keep the last good copy, the periodic read, server only, onSettingsChanged) and
	-- `--settings-missing` (a place project without Settings.luau boots with the defaults).
	settings = table.find(process.args, "--settings") ~= nil,
	settingsMissing = table.find(process.args, "--settings-missing") ~= nil,
	-- `--detached` (api:runDetached): a job outlives its generation's hard stop and finishes; its callback is dropped
	-- for a stopped generation; errors are logged with the generation and counted; the cap and the slow-job warning.
	detached = table.find(process.args, "--detached") ~= nil,
	-- 0.3.9 `--rollback-prev`: a public prod server that booted straight into the branch head B (#11): /tt rollback
	-- finds no earlier generation here and uses the branch's previous heads (`prev` on the durable head): an unsigned one
	-- is refused (signed server), the signed H1 runs; the kernel's own durable write keeps `prev`, MemoryStore never.
	rollbackPrev = table.find(process.args, "--rollback-prev") ~= nil,
	-- 0.4.0 `--errors` (plans/21 C): a public prod server whose signed settings hold `backend` (and an old `fleet` that
	-- must be ignored): heartbeats with the budget summary `bu` to <url>/v1/fleet/heartbeat, a server error and a client
	-- batch templated and posted to <url>/v1/errors with the player's pid, status().errors / status().budget,
	-- api:budget() and api:budgetCount.
	errors = table.find(process.args, "--errors") ~= nil,
}
-- 0.3.8 loading screens (plans/19 item 13), client side: `--client-boot` (the game's BootScreen replaces the kernel's
-- "Starting..." until the first client generation runs and the server's hold ends), `--client-own` (KernelScreen =
-- false: the game draws its own; the kernel's shows only for moves and later holds). `--client` checks ClientReady,
-- ClientGeneration and Holding too.

if FLEET_MODE then
	dataStore.data.settings = deepCopy(SMOKE.settings.fleetSlash) -- 0.3.8: was ConfigService TypeTorchFleet
end
if DEV_MODE or VIP_MODE or HEALTH_MODE or FLEET_MODE or DURABLE_MODE or HEALTH_CONFIG_MODE then
	GAME_ROOT_PROPS.PrivateServerId = "ps-smoke"
	GAME_ROOT_PROPS.PrivateServerOwnerId = if VIP_MODE then 777 else 0
	dataStore.data["private/ps-smoke"] = { branch = "dev", setBy = 1, setAt = "2026-10-04T00:00:00Z", code = if HEALTH_MODE or FLEET_MODE then "smoke-access-code" else nil }
end
if HEALTH_MODE then
	dataStore.failGets.settings = math.huge -- S-M2: the settings never read, so revocations stay unknown
	dataStore.failGets["private/ps-smoke"] = 2 -- P-K8: the boot read is retried
	subscribeFailures["TypeTorch/deploy"] = 2 -- P-K8: the subscription is retried
end

-- `--fallback`: the key asset never loads, so only `sigF` (the baked fallback key) counts.
local FALLBACK_MODE = table.find(process.args, "--fallback") ~= nil
if FALLBACK_MODE then
	assets[500].failLoads = math.huge
	local latest = services.InsertService.GetLatestAssetVersionAsync
	services.InsertService.GetLatestAssetVersionAsync = function(self, id)
		if id == 500 then
			error("HTTP 403 (smoke: key asset unreadable)")
		end
		return latest(self, id)
	end
end

-- SMOKE.behave[artifactId](kernel) runs on the generation's own thread during boot (0.3.2 health tests); returning
-- "fail" makes boot return no stop function, so the generation fails to start. Behaviors must use SMOKE.task (owned
-- threads), not Lune's task.
local BOOT_SOURCE = [[
return {
	boot = function(kernel)
		SMOKE.kernel = kernel
		if kernel.onDeployReport then
			local reports = {}
			local name = kernel.artifact.id .. "#" .. kernel.generation
			SMOKE.heard[name] = reports
			SMOKE.disconnects[name] = kernel:onDeployReport(function(report)
				table.insert(reports, report)
			end)
		end
		kernel:onMessage(function(player, channel, ...)
			table.insert(SMOKE.messages, { kernel.artifact.id, channel })
		end)
		table.insert(SMOKE.boots, kernel.artifact.id)
		if kernel.onClose then
			kernel:onClose(function()
				table.insert(SMOKE.closed, kernel.artifact.id)
			end)
		end
		if SMOKE.startDelay then
			SMOKE.task.wait(SMOKE.startDelay) -- 0.3.2 boot scenarios: the time a generation takes to start
		end
		local behave = SMOKE.behave[kernel.artifact.id]
		if behave and behave(kernel) == "fail" then
			return nil
		end
		return function(info)
			table.insert(SMOKE.stops, kernel.artifact.id)
			if SMOKE.hangStop then
				task.wait(1e6) -- a stuck onStop: the kernel must hard-stop after STOP_DEADLINE (P-K4)
			end
		end
	end,
}
]]

local function payload(artifactId: string, channel: string?, extraScript: boolean?, protocolHash: string?, attributes: { [string]: any }?)
	return function()
		local model = newInstance("Model", "TypeTorchPayload")
		model:SetAttribute("ArtifactId", artifactId)
		model:SetAttribute("Channel", channel)
		model:SetAttribute("Commit", string.sub(artifactId, 1, 7))
		model:SetAttribute("KernelApi", 1)
		model:SetAttribute("ProtocolHash", protocolHash) -- 0.3.2 (P-N1)
		for name, value in attributes or {} do
			model:SetAttribute(name, value) -- 0.3.7: HealthErrors, HealthWindow, HealthRollback (as `typetorch build` stamps them)
		end
		for _, part in { "Server", "Shared", "Client", "include" } do
			local folder = newInstance("Folder", part)
			folder.Parent = model
			if part == "Server" or part == "Client" then
				local boot = newInstance("ModuleScript", "boot")
				internals[boot].sourceText = BOOT_SOURCE
				boot.Parent = folder
			end
		end
		if extraScript then
			newInstance("Script", "Sneaky").Parent = model.Shared
		end
		return model
	end
end

addAsset(1001, payload("aaaaaaa-111111", "prod", false, "proto-1"))
addAsset(1002, payload("bbbbbbb-222222", "prod", false, "proto-1"))
addAsset(1003, payload("ccccccc-333333", "dev"))
addAsset(1004, payload("ddddddd-444444", "prod", false, "proto-1"))
addAsset(1005, payload("eeeeeee-555555", "prod", true))
addAsset(1006, payload("fffffff-666666", "prod"), 2)
-- 0.3.2 health tests (behaviors set per mode): G errors after ready, H's onStart fails, I fails to start.
addAsset(1007, payload("ggggggg-777777", "prod"))
addAsset(1008, payload("hhhhhhh-888888", "prod"))
addAsset(1009, payload("iiiiiii-999999", "prod"))
-- 0.3.7 health thresholds per build (--health-config; the HEALTH_WINDOW bounds are scaled there to 0.5-10 s): J allows 5
-- errors within 3 s; K's values are all bad (out of bounds, the wrong type: the defaults apply); L turns the rollback off.
addAsset(1010, payload("jjjjjjj-aaaaaa", "prod", false, nil, { HealthErrors = 5, HealthWindow = 3 }))
addAsset(1011, payload("kkkkkkk-bbbbbb", "prod", false, nil, { HealthErrors = 500, HealthWindow = "3", HealthRollback = "no" }))
addAsset(1012, payload("lllllll-cccccc", "prod", false, nil, { HealthRollback = false }))

-- 0.3.1: ServerStorage.TypeTorchDev.Payload, as studio.project.json syncs it (no ArtifactId or Channel attribute). Only
-- `--studio-local` runs in Studio; in every other mode the kernel must ignore it.
local STUDIO_MODE = table.find(process.args, "--studio-local") ~= nil
local devFolder = newInstance("Folder", "TypeTorchDev")
devFolder.Parent = services.ServerStorage
local localSource = payload("unused", nil)()
localSource:SetAttribute("ArtifactId", nil)
localSource:SetAttribute("Commit", nil)
localSource.Name = "Payload"
localSource.Parent = devFolder

-- Signed messages ----------------------------------------------------------------------------------------------------

local SIGS = serde.decode("json", fs.readFile("scripts/smoke-signatures.json"))

local function deployMessage(name: string?, fields, which: { string }?)
	local data = table.clone(fields)
	for _, field in which or {} do
		local key = if field == "sigR" then "sig" else field
		data[key] = SIGS[name][field]
	end
	return data
end

local FIELDS = {
	H1 = { b = "prod", a = 1001, i = "aaaaaaa-111111", s = 10, c = "aaaaaaa", ch = "prod", t = 1759580000000 },
	M2 = { b = "prod", a = 1002, i = "bbbbbbb-222222", s = 11, c = "bbbbbbb", ch = "prod", t = 1759580100000 },
	M3 = { b = "prod", a = 1003, i = "ccccccc-333333", s = 12, c = "ccccccc", ch = "dev", t = 1759580110000 },
	M4 = { b = "prod", a = 1004, i = "ddddddd-444444", s = 13, c = "ddddddd", ch = "prod", t = 1759580120000 },
	M5 = { b = "prod", a = 1005, i = "eeeeeee-555555", s = 14, c = "eeeeeee", ch = "prod", t = 1759580130000 },
	M6 = { b = "prod", a = 1006, i = "fffffff-666666", s = 15, c = "fffffff", ch = "prod", t = 1759580140000 },
	M7 = { b = "prod", a = 1002, i = "bbbbbbb-222222", s = 16, c = "bbbbbbb", ch = "prod", t = 1759580150000, r = 1 },
	M8 = { b = "prod", a = 1006, i = "fffffff-666666", s = 17, c = "fffffff", ch = "prod", t = 1759580160000 },
	M9 = { b = "prod", a = 1001, i = "aaaaaaa-111111", s = 18, c = "aaaaaaa", ch = "prod", t = 1759580170000 },
	-- The CLI re-signs the running head after `keys rotate`: same asset, new seq, r = "resign".
	M10 = { b = "prod", a = 1006, i = "fffffff-666666", s = 19, c = "fffffff", ch = "prod", t = 1759580180000, r = "resign" },
	-- 0.3.6 `--heads-cap`: signed deploys of branches the server doesn't know yet.
	E1 = { b = "eu", a = 1002, i = "bbbbbbb-222222", s = 40, c = "bbbbbbb", ch = "prod", t = 1759580400000 },
	E2 = { b = "eu2", a = 1004, i = "ddddddd-444444", s = 41, c = "ddddddd", ch = "prod", t = 1759580410000 },
	P2 = { j = { "smoke-job-0001" }, a = 1001, b = "prod", by = 1, t = 1759580200000 },
	P3 = { j = { "smoke-job-0001" }, b = "prod", by = 1, t = 1759580200000, unpin = true },
	-- 0.3.2 health tests: G errors after ready, H's onStart fails, I fails to start, G again, then a good D.
	Q1 = { b = "prod", a = 1007, i = "ggggggg-777777", s = 30, c = "ggggggg", ch = "prod", t = 1759580300000 },
	Q2 = { b = "prod", a = 1008, i = "hhhhhhh-888888", s = 31, c = "hhhhhhh", ch = "prod", t = 1759580310000 },
	Q3 = { b = "prod", a = 1009, i = "iiiiiii-999999", s = 32, c = "iiiiiii", ch = "prod", t = 1759580320000 },
	Q4 = { b = "prod", a = 1007, i = "ggggggg-777777", s = 33, c = "ggggggg", ch = "prod", t = 1759580330000 },
	Q5 = { b = "prod", a = 1004, i = "ddddddd-444444", s = 34, c = "ddddddd", ch = "prod", t = 1759580340000 },
}

-- `--bootstrap`: only an UNSIGNED 0.2-style prod head in the stores, matching the stamped BootstrapHeads.
-- `--bootstrap-only`: no stored heads at all; the server boots the BootstrapHeads entry itself.
-- `--blind`: unsigned prod heads only and no BootstrapHeads: the boot fail-safe boots the newest usable one, flagged;
-- updates stay strictly verified.
-- `--empty`: every stored head fails its checks: nothing runs until a signed deploy.
local BOOTSTRAP_MODE = table.find(process.args, "--bootstrap") ~= nil
local BOOTSTRAP_ONLY_MODE = table.find(process.args, "--bootstrap-only") ~= nil
local BLIND_MODE = table.find(process.args, "--blind") ~= nil
local EMPTY_MODE = table.find(process.args, "--empty") ~= nil
if BOOTSTRAP_MODE or BOOTSTRAP_ONLY_MODE then
	kernelFolder:SetAttribute("BootstrapHeads", '{"prod":{"a":1001,"s":10,"i":"aaaaaaa-111111"}}')
end

local function publish(topic: string, data)
	local handler = topics[topic] or error(`smoke: nothing subscribed to {topic}`)
	task.spawn(handler, { Data = serde.encode("json", data), Sent = os.time() })
end

-- 0.3.5 `--durable`: a dev head and history entry exactly as the CLI writes them (cli/src/durablehead.ts).
local function cliHead(seq: number, assetId: number, artifactId: string)
	return { assetId = assetId, artifactId = artifactId, seq = seq, commit = string.sub(artifactId, 1, 7), channel = "dev", deployedAt = "2026-10-06T12:00:00Z", t = 1759580000000 + seq }
end
local function cliEntry(seq: number, assetId: number, artifactId: string)
	local entry = cliHead(seq, assetId, artifactId)
	entry.branch, entry.at, entry.deployedAt = "dev", entry.deployedAt, nil
	return entry
end

-- The stores: a signed H1 in the durable copy, and a FORGED higher-seq unsigned head in MemoryStore.
local h1 = FIELDS.H1
dataStore.data.heads = {
	prod = { assetId = h1.a, artifactId = h1.i, seq = h1.s, commit = h1.c, channel = h1.ch, t = h1.t, sig = SIGS.H1.sig, sigF = SIGS.H1.sigF, deployedAt = "2026-10-04T00:00:00Z" },
}
memoryStore.data.heads = {
	prod = { assetId = 1003, artifactId = "ccccccc-333333", seq = 99, commit = "ccccccc", channel = "prod", t = 1759580000000, deployedAt = "2026-10-04T00:00:00Z" },
	-- An unsigned dev-branch head (dev deploys stay unsigned).
	dev = { assetId = 1004, artifactId = "ddddddd-444444", seq = 5, commit = "ddddddd", channel = "dev", t = 1759580000000, deployedAt = "2026-10-04T00:00:00Z" },
}
if BOOTSTRAP_MODE or BLIND_MODE then
	-- H1 as a 0.2 kernel stored it: no t, no signatures. (MemoryStore keeps the forged dev-channel head, seq 99.)
	dataStore.data.heads = { prod = { assetId = h1.a, artifactId = h1.i, seq = h1.s, commit = h1.c, channel = h1.ch, deployedAt = "2026-10-04T00:00:00Z" } }
elseif BOOTSTRAP_ONLY_MODE then
	dataStore.data.heads = {}
	memoryStore.data.heads = {}
elseif EMPTY_MODE then
	-- Only unusable heads: the forged dev-channel one (seq 99, MemoryStore) and one whose payload holds a Script.
	dataStore.data.heads = { prod = { assetId = 1005, artifactId = "eeeeeee-555555", seq = 70, commit = "eeeeeee", channel = "prod", deployedAt = "2026-10-04T00:00:00Z" } }
elseif DURABLE_MODE then
	-- Deploys #45 (and later #46) went out while no dev server ran: nobody heard the messages, so MemoryStore still says
	-- #44; the CLI wrote the DataStore copy (heads + deployments, durablehead.ts shapes).
	addAsset(1010, payload("jjjjjjj-101010", "dev"))
	addAsset(1011, payload("kkkkkkk-111111", "dev"))
	addAsset(1012, payload("lllllll-121212", "dev"))
	addAsset(1013, payload("mmmmmmm-131313", "dev"))
	-- Real store latencies: MemoryStore answers first, so a boot that didn't wait for the DataStore copy would run #44.
	LATENCY.memoryGet, LATENCY.datastoreGet = 0.05, 1.5
	memoryStore.data.heads.dev = cliHead(44, 1010, "jjjjjjj-101010")
	dataStore.data.heads.dev = cliHead(45, 1011, "kkkkkkk-111111")
	-- No forged prod head in MemoryStore here (that alone would make the boot read the durable copy too).
	memoryStore.data.heads.prod = deepCopy(dataStore.data.heads.prod)
	dataStore.data.deployments = { list = { cliEntry(45, 1011, "kkkkkkk-111111"), cliEntry(44, 1010, "jjjjjjj-101010") } }
elseif FLEET_MODE then
	-- The dev head is I, which fails to start, and nothing else is known for "dev": the server runs nothing.
	memoryStore.data.heads.dev = { assetId = 1009, artifactId = "iiiiiii-999999", seq = 5, commit = "iiiiiii", channel = "dev", t = 1759580000000, deployedAt = "2026-10-04T00:00:00Z" }
elseif LKG_BOOT_MODE then
	-- The signed head (I, seq 32) fails to start. The deployment history holds it, an UNSIGNED prod entry (B, seq 20:
	-- never a target on a prod server) and the signed H1 (A, seq 10): the server must boot A.
	local q3 = FIELDS.Q3
	local function signedEntry(fields, sigs)
		return { seq = fields.s, branch = fields.b, channel = fields.ch, artifactId = fields.i, assetId = fields.a, commit = fields.c, at = "2026-10-04T00:00:00Z", t = fields.t, sig = sigs.sig, sigF = sigs.sigF }
	end
	dataStore.data.heads = { prod = { assetId = q3.a, artifactId = q3.i, seq = q3.s, commit = q3.c, channel = q3.ch, t = q3.t, sig = SIGS.Q3.sig, sigF = SIGS.Q3.sigF, deployedAt = "2026-10-04T00:00:00Z" } }
	memoryStore.data.heads = {}
	dataStore.data.deployments = {
		list = {
			signedEntry(q3, SIGS.Q3),
			{ seq = 20, branch = "prod", channel = "prod", artifactId = "bbbbbbb-222222", assetId = 1002, commit = "bbbbbbb", at = "2026-10-04T00:00:00Z" },
			signedEntry(h1, SIGS.H1),
		},
	}
end
-- 0.3.6 NEVER AN EMPTY SERVER ----------------------------------------------------------------------------------------
-- `--hold` / `--hold-optout`: the hold (no character spawns until a generation is ready; the client's Hold attribute),
-- a swap never holds; the Players attribute TypeTorchHoldCharacters = false leaves characters alone.
-- `--peers`: no usable head anywhere; live servers of the branch run B (signed) healthy: the kernel roll call boots it;
-- this kernel answers other kernels' asks. `--peers-untrusted`: peers run an unsigned build and a forged signature:
-- refused; a peer build whose deployment entry verifies runs. `--backup`: an asset outage (every LoadAsset fails): the
-- backup baked into the place runs. `--recover`: the outage ends: the background retry swaps to the head, players stay.
-- `--teleport`: nothing runs (outage, the backup holds a Script): at the boot budget players are moved (matchmaking,
-- then a healthy peer), retried, then kicked. `--bounce`: a reserved dev server: the 3rd bounce is kicked, others go to a
-- new reserved server on the branch or a reserved peer. `--mid-swap`: a swap whose new generation fails after the old one
-- stopped and whose last known good fails too: ActiveGeneration cleared, the hold arms, the backup runs; BindToClose in
-- the middle of a swap runs the starting generation's onClose. `--client-fail`: a client that failed after its retry
-- gets the client code re-sent, then is moved (rejoin).
local HOLD_MODE = table.find(process.args, "--hold") ~= nil
local HOLD_OPTOUT_MODE = table.find(process.args, "--hold-optout") ~= nil
local PEERS_MODE = table.find(process.args, "--peers") ~= nil
local PEERS_UNTRUSTED_MODE = table.find(process.args, "--peers-untrusted") ~= nil
local BACKUP_MODE = table.find(process.args, "--backup") ~= nil
local RECOVER_MODE = table.find(process.args, "--recover") ~= nil
local TELEPORT_MODE = table.find(process.args, "--teleport") ~= nil
local BOUNCE_MODE = table.find(process.args, "--bounce") ~= nil
local MIDSWAP_MODE = table.find(process.args, "--mid-swap") ~= nil
local CLIENT_FAIL_MODE = table.find(process.args, "--client-fail") ~= nil
-- 0.3.6 (plans/18): `--heads-cap` (a public prod server: deploy messages of unknown branches are recorded only when
-- signed; the stored heads hold at most HEADS_MAX_BRANCHES branches) and `--access` (0.3.8: the dev lists from the
-- signed settings apply at once after a write and a ping; a forged record is refused).
local HEADS_CAP_MODE = table.find(process.args, "--heads-cap") ~= nil
local ACCESS_MODE = table.find(process.args, "--access") ~= nil
if HEADS_CAP_MODE then
	-- 31 branches stored: prod (signed H1) and b01..b30 (dev heads).
	for index = 1, 30 do
		local name = string.format("b%02d", index)
		local head = { assetId = 1004, artifactId = "ddddddd-444444", seq = index, commit = "ddddddd", channel = "dev", t = 1759580000000, deployedAt = "2026-10-04T00:00:00Z" }
		memoryStore.data.heads[name] = head
		dataStore.data.heads[name] = deepCopy(head)
	end
	memoryStore.data.heads.prod = deepCopy(dataStore.data.heads.prod) -- (no forged MemoryStore head here)
	memoryStore.data.heads.dev = nil
end
if ACCESS_MODE then
	dataStore.data.settings = deepCopy(SMOKE.settings.access1) -- 0.3.8: was the ConfigService TypeTorch registry key
end
if MODES38.rollbackPrev then
	-- The branch head is B (M2, #11, signed), in both copies; no `prev` yet (as kernels before 0.3.9 wrote it).
	local m2 = FIELDS.M2
	dataStore.data.heads = { prod = { assetId = m2.a, artifactId = m2.i, seq = m2.s, commit = m2.c, channel = m2.ch, t = m2.t, sig = SIGS.M2.sig, sigF = SIGS.M2.sigF, deployedAt = "2026-10-04T00:00:00Z" } }
	memoryStore.data.heads = { prod = deepCopy(dataStore.data.heads.prod) }
	dataStore.data.deployments = nil
end
-- `--kernel-crash`: the kernel errors right after the hold (a kernel bug): the held players are still moved.
local KERNEL_CRASH_MODE = table.find(process.args, "--kernel-crash") ~= nil
if KERNEL_CRASH_MODE then
	services.TextChatService = nil -- game:GetService("TextChatService") throws a few lines after the hold
end
-- Modes where swaps fail on purpose (outages, refused backups): their "swap failed" warnings are expected.
local NOISY_MODE = BACKUP_MODE or RECOVER_MODE or TELEPORT_MODE or BOUNCE_MODE or MIDSWAP_MODE or PEERS_UNTRUSTED_MODE
local FALLBACK_FLEET = BACKUP_MODE or TELEPORT_MODE or BOUNCE_MODE

-- The backup `typetorch kernel deploy` bakes in: a payload named TypeTorchBackup with the Backup* attributes.
local function addBackup(artifactId: string, extraScript: boolean?)
	local model = payload(artifactId, "prod", extraScript)()
	model.Name = "TypeTorchBackup"
	model:SetAttribute("BackupArtifactId", artifactId)
	model:SetAttribute("BackupSeq", 11)
	model:SetAttribute("BackupBranch", "prod")
	model:SetAttribute("BackupChannel", "prod")
	model:SetAttribute("BackupAt", "2026-10-06T10:00:00Z")
	model.Parent = services.ServerStorage
	return model
end
-- A roll call reply from another kernel running the deploy `name` (FIELDS/SIGS), healthy for 2 minutes.
local function peerReply(job: string, name: string, extra)
	local fields = FIELDS[name]
	local sigs = SIGS[name] or {}
	local row = { j = job, b = fields.b, a = fields.a, i = fields.i, s = fields.s, c = fields.c, ch = fields.ch, t = fields.t, r = fields.r, sig = sigs.sig, sigF = sigs.sigF, st = "public", n = 3, m = 10, h = "ok", u = 120 }
	for key, value in extra or {} do
		row[key] = value
	end
	return { row = row, delay = 0.05 }
end
-- A player in the game (Parent set, in Players:GetPlayers()), with a PlayerGui; `bounce` = the teleport data's count.
local function joinPlayer(userId: number, name: string, bounce: number?, fire: boolean?)
	local instance = newInstance("Player", name)
	instance.UserId = userId
	instance.Parent = GAME_ROOT
	newInstance("PlayerGui", "PlayerGui").Parent = instance
	if bounce then
		instance.JoinData = { TeleportData = { TypeTorch = { bounce = bounce } } }
	end
	table.insert(fakePlayers, instance)
	if fire ~= false then
		services.Players.PlayerAdded:Fire(instance)
	end
	return instance
end

if FALLBACK_FLEET then
	dataStore.data.settings = deepCopy(SMOKE.settings.fleet) -- 0.3.8: was ConfigService TypeTorchFleet
end
if HOLD_OPTOUT_MODE then
	playersAttributes.TypeTorchHoldCharacters = false
end
if HOLD_MODE or HOLD_OPTOUT_MODE then
	LATENCY.payloadLoad = 0.6 -- the boot takes a moment: a player joins during it
end
if PEERS_MODE or PEERS_UNTRUSTED_MODE then
	-- No head anywhere (both stores empty, no deployment list, no BootstrapHeads): only peers can help.
	dataStore.data.heads, memoryStore.data.heads, dataStore.data.deployments = {}, {}, nil
end
if PEERS_MODE then
	peerReplies = {
		peerReply("peer-b-1", "M2"),
		peerReply("peer-b-2", "M2"),
		peerReply("peer-b-3", "M2"),
		peerReply("peer-b-young", "M2", { u = 5 }), -- not up long enough: not counted
		peerReply("peer-d-1", "Q5"),
		peerReply("peer-g-1", "Q1", { h = "degraded" }), -- unhealthy: not counted
		peerReply("peer-g-2", "Q1", { h = "degraded" }),
		peerReply("peer-g-3", "Q1", { h = "degraded" }),
		peerReply("peer-g-4", "Q1", { h = "degraded" }),
		peerReply("peer-dev-1", "M2", { b = "dev" }), -- another branch: not counted
	}
end
if PEERS_UNTRUSTED_MODE then
	-- Most common: an unsigned build (C), then B with a forged signature; least common: D, unsigned in the reply, but the
	-- deployment list holds its signed entry (Q5).
	local forged = string.rep("A", 86) .. "=="
	local function unsigned(extra)
		extra.sig, extra.sigF = "", "" -- (an empty string: the reply carries no usable signature)
		return extra
	end
	peerReplies = {
		peerReply("peer-c-1", "M3", unsigned({ s = 50, ch = "prod" })),
		peerReply("peer-c-2", "M3", unsigned({ s = 50, ch = "prod" })),
		peerReply("peer-c-3", "M3", unsigned({ s = 50, ch = "prod" })),
		peerReply("peer-b-1", "M2", { sig = forged, sigF = forged }),
		peerReply("peer-b-2", "M2", { sig = forged, sigF = forged }),
		peerReply("peer-d-1", "Q5", unsigned({})),
	}
	-- The deployment list is unreadable at boot (D isn't a boot candidate); it reads fine when the peer reply is checked.
	dataStore.failGets.deployments = 3 -- (the boot prefetch, the boot, the boot again once the heads are in)
	local fields = FIELDS.Q5
	dataStore.data.deployments = {
		list = { { seq = fields.s, branch = fields.b, channel = fields.ch, artifactId = fields.i, assetId = fields.a, commit = fields.c, at = "2026-10-04T00:00:00Z", t = fields.t, sig = SIGS.Q5.sig, sigF = SIGS.Q5.sigF } },
	}
end
if BACKUP_MODE or RECOVER_MODE or TELEPORT_MODE or BOUNCE_MODE then
	-- An asset outage: every payload LoadAsset fails (the key asset still loads).
	for id = 1001, 1009 do
		assets[id].failLoads = math.huge
	end
end
if BACKUP_MODE or RECOVER_MODE then
	addBackup("bbbbbbb-222222")
end
if TELEPORT_MODE then
	addBackup("bbbbbbb-222222", true) -- holds a Script: refused at mount like any payload
end
if BOUNCE_MODE then
	GAME_ROOT_PROPS.PrivateServerId = "ps-bounce"
	GAME_ROOT_PROPS.PrivateServerOwnerId = 0
	dataStore.data["private/ps-bounce"] = { branch = "dev", setBy = 1, setAt = "2026-10-04T00:00:00Z", code = "own-code" }
end
if MIDSWAP_MODE then
	addBackup("ddddddd-444444")
	SMOKE.behave["aaaaaaa-111111"] = function()
		if SMOKE.breakA then
			return "fail" -- the last known good fails too
		end
	end
end
if CLIENT_FAIL_MODE then
	GAME_ROOT_PROPS.PrivateServerId = "ps-smoke"
	GAME_ROOT_PROPS.PrivateServerOwnerId = 0
	dataStore.data["private/ps-smoke"] = { branch = "dev", setBy = 1, setAt = "2026-10-04T00:00:00Z", code = "smoke-access-code" }
end

-- 0.3.2 behaviors: G's scripts error after ready (3 times; one from a ModuleScript in its tree), H reports a failed
-- onStart (as the framework does), I fails to start (boot returns no stop function).
local function generationModule(kernel)
	local tree = services.ServerStorage.TypeTorch.Generations:FindFirstChild(`{kernel.artifact.id}#{kernel.generation}`)
	return tree and tree.Server.boot
end
SMOKE.behave["ggggggg-777777"] = function(kernel)
	if SMOKE.quietG then
		return
	end
	for index = 1, 2 do
		SMOKE.task.delay(0.05 * index, function()
			error(`G boom {index}`)
		end)
	end
	SMOKE.task.delay(0.2, function()
		fireScriptError("G boom 3 (module)", "", generationModule(kernel))
	end)
end
SMOKE.behave["hhhhhhh-888888"] = function(kernel)
	kernel:reportError({ kind = "onStart", module = "ShopService", message = "attempt to index nil with 'price'" })
end
SMOKE.behave["iiiiiii-999999"] = function()
	return "fail"
end
-- 0.3.7: L (HealthRollback = false) reports a failed onStart at boot too: it must keep running.
SMOKE.behave["lllllll-cccccc"] = function(kernel)
	kernel:reportError({ kind = "onStart", module = "NoisyService", message = "attempt to index nil with 'gui'" })
end

-- 0.3.2 boot budget scenarios ------------------------------------------------------------------------------------------
-- Each: `setup` (fixtures and latencies), `first` = the artifact expected first, `final` = the artifact expected once
-- background retries and late reads settle (optional), `within` = a tighter bound than the 15 s budget (optional).
-- A public prod server unless the setup says otherwise. Normal latencies (simulated seconds): key asset 0.3 + 0.5,
-- settings 0.4 (0.3.8; ConfigService 0.5 before), MemoryStore 0.15, DataStore 0.4 (private record too), LoadAsset 0.6, generation start 0.3.
local NORMAL = { keyVersion = 0.3, keyLoad = 0.5, settingsGet = 0.4, memoryGet = 0.15, datastoreGet = 0.4, privateGet = 0.4, payloadLoad = 0.6, groups = 0.3, badge = 0.3 }
local HANG = { hang = true }
local function signedStoredHead(name: string)
	local fields = FIELDS[name]
	return { assetId = fields.a, artifactId = fields.i, seq = fields.s, commit = fields.c, channel = fields.ch, t = fields.t, sig = SIGS[name].sig, sigF = SIGS[name].sigF, deployedAt = "2026-10-04T00:00:00Z" }
end
local function signedEntry(name: string)
	local head = signedStoredHead(name)
	head.branch = FIELDS[name].b
	head.at = head.deployedAt
	head.deployedAt = nil
	return head
end
local function reservedDev()
	GAME_ROOT_PROPS.PrivateServerId = "ps-boot"
	GAME_ROOT_PROPS.PrivateServerOwnerId = 0
	dataStore.data["private/ps-boot"] = { branch = "dev", setBy = 1, setAt = "2026-10-04T00:00:00Z" }
end
local BOOT_SCENARIOS = {
	{ name = "normal", first = "bbbbbbb-222222", within = 3 },
	{ name = "keys-slow", first = "bbbbbbb-222222", setup = function() LATENCY.keyVersion = HANG end },
	{ name = "keys-fail", first = "bbbbbbb-222222", within = 3, setup = function() LATENCY.keyVersion = { fail = true, after = 0.2 }; assets[500].failLoads = math.huge end },
	-- 0.3.8: the signed settings (one DataStore read) replace ConfigService on the boot path.
	{ name = "settings-slow", first = "bbbbbbb-222222", setup = function() LATENCY.settingsGet = HANG end },
	{ name = "settings-fail", first = "bbbbbbb-222222", within = 3, setup = function() LATENCY.settingsGet = { fail = true, after = 0.3 } end },
	{ name = "memory-slow", first = "aaaaaaa-111111", setup = function() LATENCY.memoryGet = HANG end },
	{ name = "stores-slow", first = "aaaaaaa-111111", final = "bbbbbbb-222222", setup = function()
		LATENCY.memoryGet, LATENCY.datastoreGet = 8, 8
		kernelFolder:SetAttribute("BootstrapHeads", '{"prod":{"a":1001,"s":10,"i":"aaaaaaa-111111"}}')
	end },
	{ name = "stores-slow-nobootstrap", first = "bbbbbbb-222222", setup = function() LATENCY.memoryGet, LATENCY.datastoreGet = 8, 8 end },
	{ name = "stores-fail", first = "aaaaaaa-111111", within = 5, setup = function()
		LATENCY.memoryGet, LATENCY.datastoreGet = { fail = true, after = 1 }, { fail = true, after = 1 }
		kernelFolder:SetAttribute("BootstrapHeads", '{"prod":{"a":1001,"s":10,"i":"aaaaaaa-111111"}}')
	end },
	{ name = "head-load-fails", first = "aaaaaaa-111111", final = "bbbbbbb-222222", setup = function() assets[1002].failLoads = 1 end },
	{ name = "head-load-hangs", first = "aaaaaaa-111111", final = "bbbbbbb-222222", setup = function() assets[1002].hangLoads = 1 end },
	{ name = "head-mount-refused", first = "aaaaaaa-111111", setup = function() assets[1002].build = payload("bbbbbbb-222222", "prod", true) end },
	{ name = "head-start-fails", first = "aaaaaaa-111111", setup = function() SMOKE.behave["bbbbbbb-222222"] = function() return "fail" end end },
	{ name = "head-never-ready", first = "aaaaaaa-111111", setup = function() SMOKE.behave["bbbbbbb-222222"] = function() SMOKE.task.wait(1e6) end end },
	{ name = "two-broken-then-good", first = "bbbbbbb-222222", setup = function()
		memoryStore.data.heads.prod = signedStoredHead("Q5")
		dataStore.data.deployments = { list = { signedEntry("Q5"), signedEntry("Q1"), signedEntry("M2"), signedEntry("H1") } }
		SMOKE.behave["ddddddd-444444"] = function() SMOKE.task.wait(1e6) end -- D never calls ready
		assets[1007].hangLoads = 1 -- G's LoadAsset never answers
	end },
	{ name = "bootstrap-only", first = "aaaaaaa-111111", within = 3, setup = function()
		memoryStore.data.heads, dataStore.data.heads, dataStore.data.deployments = {}, {}, nil
		kernelFolder:SetAttribute("BootstrapHeads", '{"prod":{"a":1001,"s":10,"i":"aaaaaaa-111111"}}')
	end },
	{ name = "blind-fail-safe", first = "aaaaaaa-111111", within = 3, setup = function()
		memoryStore.data.heads = { prod = { assetId = 1001, artifactId = "aaaaaaa-111111", seq = 10, commit = "aaaaaaa", channel = "prod", deployedAt = "2026-10-04T00:00:00Z" } }
		dataStore.data.heads, dataStore.data.deployments = {}, nil
	end },
	{ name = "private-record-slow", first = "bbbbbbb-222222", final = "ddddddd-444444", setup = function()
		reservedDev()
		LATENCY.privateGet = 8
	end },
	{ name = "owner-check-slow", first = "bbbbbbb-222222", setup = function()
		GAME_ROOT_PROPS.PrivateServerId = "ps-boot"
		GAME_ROOT_PROPS.PrivateServerOwnerId = 777
		GAME_ROOT_PROPS.CreatorType = Enum.CreatorType.Group
		dataStore.data["private/ps-boot"] = { branch = "dev", setBy = 777, setAt = "2026-10-04T00:00:00Z" }
		LATENCY.groups = HANG
	end },
	{ name = "dev-head-load-fails", first = "bbbbbbb-222222", final = "ddddddd-444444", setup = function()
		reservedDev()
		assets[1004].failLoads = 1
		local entry = { seq = 4, branch = "dev", channel = "dev", artifactId = "bbbbbbb-222222", assetId = 1002, commit = "bbbbbbb", at = "2026-10-03T00:00:00Z" }
		dataStore.data.deployments = { list = { entry } }
	end },
	{ name = "studio-local", first = "local", within = 1 },
	-- 0.3.6 never an empty server: the time to each fallback (a player waits on the holding screen meanwhile).
	{ name = "peers-only", first = "bbbbbbb-222222", setup = function()
		-- No head anywhere; live servers of the branch run B (signed). Publish 0.2 s, replies 0.4-0.6 s later.
		memoryStore.data.heads, dataStore.data.heads, dataStore.data.deployments = {}, {}, nil
		LATENCY.publish = 0.2
		peerReplies = { peerReply("peer-1", "M2"), peerReply("peer-2", "M2"), peerReply("peer-3", "M2") }
		for index, reply in peerReplies do
			reply.delay = 0.4 + index * 0.1
		end
	end },
	{ name = "outage-backup", first = "ddddddd-444444", setup = function()
		-- An asset outage: every payload LoadAsset fails after its usual latency; the backup baked into the place runs.
		for id = 1001, 1009 do
			assets[id].failLoads = math.huge
		end
		LATENCY.publish = 0.2
		addBackup("ddddddd-444444")
	end },
	{ name = "outage-hang-backup", first = "ddddddd-444444", setup = function()
		-- Every payload LoadAsset hangs (each boot attempt waits out its cap); the backup runs inside the budget.
		for id = 1001, 1009 do
			assets[id].hangLoads = math.huge
		end
		LATENCY.publish = 0.2
		addBackup("ddddddd-444444")
	end },
	{ name = "nothing-teleport", first = "teleport", setup = function()
		-- Everything fails, no backup: the waiting player is moved at the boot budget.
		for id = 1001, 1009 do
			assets[id].failLoads = math.huge
		end
		LATENCY.publish = 0.2
		joinPlayer(7, "Waiting", nil, false)
	end },
}
local scenario = nil
if BOOT_SCENARIO then
	for _, candidate in BOOT_SCENARIOS do
		if candidate.name == BOOT_SCENARIO then
			scenario = candidate
		end
	end
	assert(scenario, `unknown boot scenario {BOOT_SCENARIO}`)
	-- The base: signed B (seq 11) in MemoryStore, signed A (seq 10) in the DataStore and both in the deployment list.
	memoryStore.data.heads = { prod = signedStoredHead("M2"), dev = { assetId = 1004, artifactId = "ddddddd-444444", seq = 5, commit = "ddddddd", channel = "dev", t = 1759580000000, deployedAt = "2026-10-04T00:00:00Z" } }
	dataStore.data.heads = { prod = signedStoredHead("H1") }
	dataStore.data.deployments = { list = { signedEntry("M2"), signedEntry("H1") } }
	if scenario.name ~= "studio-local" then
		devFolder.Parent = nil -- no local payload outside the Studio scenario
	end
	for op, value in NORMAL do
		LATENCY[op] = value
	end
	SMOKE.startDelay = 0.3 * SCALE
	if scenario.setup then
		scenario.setup()
	end
end

-- Boot ---------------------------------------------------------------------------------------------------------------

local Constants = requireInstance(shared.Constants)
Constants.PUBLIC_JITTER_SECONDS = 0.05
Constants.CONFIG_BOOT_WAIT = 0.1
Constants.LOAD_RETRY_DELAYS = { 0.1, 0.1, 0.1 }
Constants.STOP_DEADLINE = 0.3
Constants.SUBSCRIBE_RETRY_DELAYS = { 0.05 }
Constants.PRIVATE_READ_RETRY_DELAYS = { 0.05, 0.05, 0.05 }
Constants.CLOSE_DEADLINE = 1
Constants.SETTINGS_PING_GAP = 0.05 -- 0.3.8: a settings ping re-reads at once
if BOOT_SCENARIO then
	-- Real kernel timing, SCALE times faster (and the same constants an older kernel had, for before/after runs).
	for _, name in { "BOOT_BUDGET", "BOOT_READS_WAIT", "KEYS_BOOT_WAIT", "CONFIG_BOOT_WAIT", "BOOT_OWNER_CHECK", "BOOT_DEADLINE", "BOOT_LOAD_TIMEOUT", "BOOT_READY_TIMEOUT", "BOOT_LATE_LOAD", "BOOT_LATE_READY", "READY_TIMEOUT", "POLL_SECONDS", "STOP_DEADLINE", "PUBLIC_JITTER_SECONDS", "FALLBACK_AT", "PEER_COLLECT", "PEER_CACHE", "PEER_REPLY_JITTER", "TELEPORT_GRACE", "TELEPORT_RETRY" } do
		if type(Constants[name]) == "number" then
			Constants[name] *= SCALE
		end
	end
	Constants.CONFIG_BOOT_WAIT = 3 * SCALE
	Constants.KEYS_BOOT_WAIT = (if Constants.BOOT_BUDGET then 3 else 10) * SCALE
	Constants.LOAD_RETRY_DELAYS = { 5 * SCALE, 15 * SCALE, 60 * SCALE }
	Constants.PRIVATE_READ_RETRY_DELAYS = { 1 * SCALE, 2 * SCALE, 4 * SCALE }
	Constants.POLL_SECONDS = 60 * SCALE
	Constants.RECOVER_DELAYS = { 15 * SCALE, 30 * SCALE, 60 * SCALE }
end
if SWITCH_MODE then
	Constants.SWITCH_GAP = 0.3
	Constants.POLL_SECONDS = 0.3
	Constants.FLEET_RETRY_DELAYS = { 0.05 }
	Constants.FLEET_RATE_PER_MINUTE = 6000
end
if FLEET_MODE then
	Constants.FLEET_HEARTBEAT_SECONDS = 0.5
	Constants.FLEET_PLAYERS_GAP = 0.2
	Constants.FLEET_WATCH_SECONDS = 0.2
	Constants.FLEET_RETRY_DELAYS = { 0.05, 0.1, 0.2 }
	Constants.FLEET_SETTINGS_SECONDS = 0.5
	Constants.FLEET_ALERT_GAP = 0.3
	Constants.FLEET_SPIKE_GAP = 0.3
	Constants.FLEET_RATE_PER_MINUTE = 6000
	-- 0.3.9: the backoff after a failed cycle and the hold after a 401, scaled down like the rest (test-fleet.luau checks
	-- the real values); every outage line shows.
	Constants.FLEET_BACKOFF_MAX = 0.5
	Constants.FLEET_AUTH_HOLD = 0.3
	Constants.FLEET_LOG_GAP = 0
end
if HOLD_MODE or HOLD_OPTOUT_MODE or PEERS_MODE or PEERS_UNTRUSTED_MODE or BACKUP_MODE or RECOVER_MODE or TELEPORT_MODE or BOUNCE_MODE or MIDSWAP_MODE or CLIENT_FAIL_MODE or KERNEL_CRASH_MODE then
	Constants.PEER_COLLECT = 0.4
	Constants.PEER_CACHE = 0.5
	Constants.RECOVER_DELAYS = { 0.5, 0.8, 1 }
	Constants.TELEPORT_RETRY = 0.4
	Constants.TELEPORT_GRACE = 0.5
	Constants.CLIENT_TREE_GRACE = 0.2
	Constants.FLEET_RETRY_DELAYS = { 0.05 }
	Constants.FLEET_RATE_PER_MINUTE = 6000
	Constants.FLEET_ALERT_GAP = 0.05
	if TELEPORT_MODE or BOUNCE_MODE then
		Constants.BOOT_BUDGET = 3 -- (the real budget is 15 s; the moves start at the budget)
	end
	if KERNEL_CRASH_MODE then
		Constants.BOOT_BUDGET = 0.5 -- the dead-man moves start 5 s after it
	end
	if MIDSWAP_MODE then
		Constants.READY_TIMEOUT = 1.5
	end
end
if HEALTH_MODE or HEALTH_PROD_MODE or LKG_BOOT_MODE or FLEET_MODE or HEALTH_CONFIG_MODE then
	Constants.HEALTH_WINDOW = 1.5
	Constants.POLL_SECONDS = 0.3
end
if HEALTH_CONFIG_MODE then
	-- The real bounds (5-300 s) scaled like the default window (30 s -> 1.5 s): a build's HealthWindow may be 0.5-10 s.
	Constants.HEALTH_WINDOW_MIN = 0.5
	Constants.HEALTH_WINDOW_MAX = 10
end
if HEALTH_MISSING_MODE then
	kernelFolder.Health.Parent = nil -- an older place project that lists the kernel's files one by one
end
if MODES38.messagingMissing then
	kernelFolder.Messaging.Parent = nil -- an older place project that lists the kernel's files one by one
end
if MODES38.settings then
	dataStore.data.settings = deepCopy(SMOKE.settings.s1)
	Constants.POLL_SECONDS = 0.3 -- the sync tick runs often; the settings re-read only on pings until the last check
	Constants.SETTINGS_REFRESH_SECONDS = 1000
end
if MODES38.settingsMissing then
	kernelFolder.Settings.Parent = nil
end
if MODES38.errors then
	dataStore.data.settings = deepCopy(SMOKE.settings.backend)
	Constants.FLEET_HEARTBEAT_SECONDS = 0.5
	Constants.FLEET_RATE_PER_MINUTE = 6000
	Constants.FLEET_SETTINGS_SECONDS = 0.5
	Constants.ERRORS_FLUSH_SECONDS = 0.3
	Constants.ERRORS_RATE_PER_MINUTE = 6000
	Constants.ERRORS_CLIENT_SERVER_GAP = 0
end
if FALLBACK_MODE then
	dataStore.data.settings = deepCopy(SMOKE.settings.s1) -- the key asset never loads: the record verifies by sigF
end
if MODES38.messaging or MODES38.messagingStudio then
	Constants.MESSAGING_RETRY_DELAYS = { 0.05, 0.05, 0.05 }
	Constants.MESSAGING_WARN_GAP = 0.05
	Constants.MESSAGING_REPLAY_SECONDS = 2
end
-- 0.3.8 loading screens, server side: the game's settings are copied onto the kernel client script at the hold
-- (`--hold`: ReplicatedFirst's attributes; `--hold-optout`: the kernel folder's, stamped by kernel deploy, win).
if HOLD_MODE or HOLD_OPTOUT_MODE then
	services.ReplicatedFirst:SetAttribute("TypeTorchBootScreen", "Loading")
	services.ReplicatedFirst:SetAttribute("TypeTorchKernelScreen", false)
end
if HOLD_OPTOUT_MODE then
	kernelFolder:SetAttribute("BootScreen", "FromConfig")
	kernelFolder:SetAttribute("KernelScreen", true)
end
if BLIND_MODE then
	Constants.POLL_SECONDS = 0.3 -- the forged newer head must meet several polls
end
if DURABLE_MODE then
	-- The real ratio, 100 times faster: a sync tick every 0.6 s (60 s), the durable read at most every 0.55 s (55 s).
	Constants.POLL_SECONDS = 0.6
	Constants.HEADS_DURABLE_SECONDS = 0.55
end
if STUDIO_MODE then
	Constants.POLL_SECONDS = 0.2 -- a newer stored dev head must meet several polls (and be ignored)
end
local Signing = requireInstance(kernelFolder.Signing)

local function waitFor(what: string, condition: () -> boolean, timeout: number?): boolean
	local deadline = os.clock() + (timeout or 5)
	while os.clock() < deadline do
		local ok, result = pcall(condition)
		if ok and result then
			return true
		end
		task.wait(0.02)
	end
	print(`      (timed out waiting for {what})`)
	return false
end

if table.find(process.args, "--boot-budget") then
	-- One process per scenario (each is a fresh server); the table says when the first generation ran.
	print("boot budget (simulated seconds from the kernel start to a running generation; budget 15 s)")
	print(string.format("%-26s %8s  %-16s %s", "path", "first", "artifact", "then"))
	local bad = 0
	for _, entry in BOOT_SCENARIOS do
		local args = { "run", "scripts/smoke-kernel.luau", "--boot-scenario", entry.name }
		if entry.name == "studio-local" then
			table.insert(args, "--studio-local")
		end
		local result = process.exec("lune", args)
		local line = string.match(result.stdout, "BOOT [^\n]+")
		local first, artifact, final = nil, nil, nil
		if line then
			first, artifact, final = string.match(line, "first=(%S+) artifact=(%S+) final=(%S+)")
		end
		print(string.format("%-26s %8s  %-16s %s%s", entry.name, first or "?", artifact or "?", final or "?", if result.ok then "" else "   FAIL"))
		if not result.ok then
			bad += 1
			print(result.stdout)
		end
	end
	print(`{#BOOT_SCENARIOS - bad} passed, {bad} failed (--boot-budget)`)
	process.exit(if bad == 0 then 0 else 1)
end

SMOKE.logOut = function(line: string, kind: string)
	services.LogService.MessageOut:Fire(line, if kind == "warn" then 3 else 1)
end
-- 0.3.9: the lines in a kernel log ring (the server's api:logs or the client's), as text.
SMOKE.ringHas = function(kernel, text: string): boolean
	local ok, entries = pcall(function()
		return kernel:logs(0)
	end)
	if not ok then
		return false
	end
	for _, entry in entries do
		if string.find(entry.text, text, 1, true) then
			return true
		end
	end
	return false
end

local kernelStartClock = os.clock()
local kernelErrors = {}
if not CLIENT_MODE then
	runScript(kernelFolder.Kernel, function(err)
		table.insert(kernelErrors, err)
	end)
end

local function status()
	return SMOKE.kernel:status()
end
local function running(): string?
	local s = status()
	return s.generation and s.generation.artifact.id
end
local function rejected(kind: string?): number
	local r = status().rejected
	return if kind then r.byKind[kind] or 0 else r.total
end

-- 0.3.2: events are unique keys events/<date>/<job>/<n>.
local function events(): { any }
	local list = {}
	for key, value in dataStore.data do
		if type(key) == "string" and string.sub(key, 1, 7) == "events/" then
			table.insert(list, value)
		end
	end
	return list
end
local function hasEvent(action: string, field: string?, value: any?): boolean
	for _, event in events() do
		if event.action == action and (field == nil or event[field] == value) then
			return true
		end
	end
	return false
end

local function finish()
	check("no kernel or script errors", #kernelErrors == 0 and #scriptErrors == 0)
	-- Errors in kernel-owned threads: only the deliberate "[TypeTorch] ..." lines (logError) are expected.
	local unexpected = {}
	for _, err in threadErrors do
		if err.owner == kernelFolder.Kernel and string.sub(err.text, 1, 12) ~= "[TypeTorch] " then
			table.insert(unexpected, err.text)
		end
	end
	check(`no unexpected errors on kernel threads{if #unexpected > 0 then ": " .. unexpected[1] else ""}`, #unexpected == 0)
	check(`no swap ran on a thread its own stopped generation owned (busy-flag hazard){if #hazards > 0 then ": " .. hazards[1] else ""}`, #hazards == 0)
	check("the kernel never used a MemoryStore sorted map (0.3.2: fleet status and reports are API only)", #sortedMapRequests == 0)
	if not FLEET_MODE and not SWITCH_MODE and not FALLBACK_FLEET and not ACCESS_MODE and not MODES38.errors then
		check("no HTTP request without settings.fleet", #httpRequests == 0)
	end
	local leaked = false
	for _, line in output do
		leaked = leaked or string.find(line.text, FLEET_TOKEN, 1, true) ~= nil
	end
	check("the fleet token never appears in any output", not leaked)
	for _, line in output do
		if not BOOT_SCENARIO and not NOISY_MODE and line.kind == "warn" and string.find(line.text, "swap failed", 1, true) and not string.find(line.text, "eeeeeee", 1, true) and not string.find(line.text, "1006", 1, true) and not string.find(line.text, "ccccccc", 1, true) and not string.find(line.text, "Sneaky", 1, true) then
			check(`unexpected: {line.text}`, false)
		end
	end
	if failures > 0 or VERBOSE then
		for _, err in kernelErrors do
			print(`kernel error: {err}`)
		end
		for _, err in scriptErrors do
			print(`script error: {err}`)
		end
		if not VERBOSE then
			for _, line in output do
				print(`  [{line.kind}] {line.text}`)
			end
		end
	end
	local mode = if MODES38.errors then "--errors" elseif MODES38.rollbackPrev then "--rollback-prev" elseif MODES38.detached then "--detached" elseif MODES38.settings then "--settings" elseif MODES38.settingsMissing then "--settings-missing" elseif MODES38.messaging then "--messaging" elseif MODES38.messagingStudio then "--messaging-studio" elseif MODES38.messagingMissing then "--messaging-missing" elseif MODES38.clientBoot then "--client-boot" elseif MODES38.clientOwn then "--client-own" elseif FALLBACK_MODE then "--fallback" elseif DEV_MODE then "--dev" elseif VIP_MODE then "--vip" elseif BOOTSTRAP_ONLY_MODE then "--bootstrap-only" elseif BOOTSTRAP_MODE then "--bootstrap" elseif BLIND_MODE then "--blind" elseif EMPTY_MODE then "--empty" elseif STUDIO_MODE then "--studio-local" elseif HEALTH_MODE then "--health" elseif HEALTH_PROD_MODE then "--health-prod" elseif LKG_BOOT_MODE then "--lkg-boot" elseif CLIENT_MODE then "--client" elseif FLEET_MODE then "--fleet" elseif SWITCH_MODE then "--switch" elseif DURABLE_MODE then "--durable" elseif HOLD_MODE then "--hold" elseif HOLD_OPTOUT_MODE then "--hold-optout" elseif PEERS_MODE then "--peers" elseif PEERS_UNTRUSTED_MODE then "--peers-untrusted" elseif BACKUP_MODE then "--backup" elseif RECOVER_MODE then "--recover" elseif TELEPORT_MODE then "--teleport" elseif BOUNCE_MODE then "--bounce" elseif MIDSWAP_MODE then "--mid-swap" elseif CLIENT_FAIL_MODE then "--client-fail" elseif KERNEL_CRASH_MODE then "--kernel-crash" elseif HEADS_CAP_MODE then "--heads-cap" elseif ACCESS_MODE then "--access" elseif HEALTH_CONFIG_MODE then "--health-config" elseif HEALTH_MISSING_MODE then "--health-missing" elseif BOOT_SCENARIO then `--boot-scenario {BOOT_SCENARIO}` else "public server"
	print(`{passes} passed, {failures} failed ({mode})`)
	process.exit(if failures == 0 then 0 else 1)
end

if scenario and scenario.first == "teleport" then
	-- 0.3.6: nothing can run: the time until the waiting player is moved (and that nothing ran meanwhile).
	local movedAt = nil
	local limit = os.clock() + 60 * SCALE
	while os.clock() < limit do
		if #teleports > 0 then
			movedAt = (teleports[1].at - kernelStartClock) / SCALE
			break
		end
		task.wait(0.002)
	end
	local shown = if movedAt then string.format("%.1f", movedAt) else ">60"
	print(`BOOT {scenario.name} first={shown} artifact=moved final=moved`)
	check(`{scenario.name}: the waiting player is moved at the boot budget (simulated {shown} s)`, movedAt ~= nil and movedAt >= 14.9 and movedAt <= 17)
	check(`{scenario.name}: nothing ran, the player never spawned`, SMOKE.kernel == nil and #loadedCharacters == 0)
	finish()
end
if scenario then
	-- The first running generation, then (with `final`) what it settles on.
	local firstAt, firstArtifact = nil, nil
	local limit = os.clock() + 60 * SCALE
	while os.clock() < limit do
		local ok, generation = pcall(function()
			return SMOKE.kernel:status().generation
		end)
		if ok and generation then
			firstAt, firstArtifact = (os.clock() - kernelStartClock) / SCALE, generation.artifact.id
			break
		end
		task.wait(0.002)
	end
	local finalArtifact = firstArtifact
	if scenario.final and firstArtifact then
		local settle = os.clock() + 30 * SCALE
		while os.clock() < settle and running() ~= scenario.final do
			task.wait(0.01)
		end
		finalArtifact = running()
	end
	local shown = if firstAt then string.format("%.1f", firstAt) else ">60"
	print(`BOOT {scenario.name} first={shown} artifact={firstArtifact or "-"} final={finalArtifact or "-"}`)
	local expected = if scenario.first == "local" then firstArtifact ~= nil and string.sub(firstArtifact, 1, 6) == "local-" else firstArtifact == scenario.first
	check(`{scenario.name}: a generation runs within 15 s (simulated)`, firstAt ~= nil and firstAt <= 15)
	check(`{scenario.name}: within {scenario.within or 15} s`, firstAt ~= nil and firstAt <= (scenario.within or 15))
	check(`{scenario.name}: first {scenario.first}`, expected)
	if scenario.final then
		check(`{scenario.name}: then {scenario.final}`, finalArtifact == scenario.final)
	end
	finish()
end

if CLIENT_MODE then
	-- The client half of the place: TypeTorchKernelShared (Constants, ClientApi, ClientEntry), ReplicatedStorage.TypeTorch
	-- (Generations, Net, NetU), a LocalPlayer with PlayerScripts, and the client kernel script.
	sourceInstance("ModuleScript", "ClientApi", "src/shared/ClientApi.luau").Parent = shared
	local clientEntry = sourceInstance("Script", "ClientEntry", "src/shared/ClientEntry.client.luau") -- a LocalScript on Roblox
	clientEntry.Enabled = false
	clientEntry.Parent = shared
	local root = newInstance("Folder", "TypeTorch")
	root.Parent = services.ReplicatedStorage
	local generations = newInstance("Folder", "Generations")
	generations.Parent = root
	newInstance("RemoteEvent", "Net").Parent = root
	newInstance("UnreliableRemoteEvent", "NetU").Parent = root
	local localPlayer = newInstance("Player", "LocalPlayer")
	newInstance("Folder", "PlayerScripts").Parent = localPlayer
	local playerGui = newInstance("PlayerGui", "PlayerGui") -- 0.3.6: the holding screen and re-sent client trees
	playerGui.Parent = localPlayer
	services.Players.LocalPlayer = localPlayer
	-- A client tree whose Client.boot fails `failures` times when required (each copy of the tree requires it anew).
	local function clientTree(name: string, failures: number)
		SMOKE.clientFailures = SMOKE.clientFailures or {}
		SMOKE.clientFailures[name] = failures
		local tree = newInstance("Folder", name)
		tree:SetAttribute("ArtifactId", string.split(name, "#")[1])
		for _, part in { "Shared", "Client", "include" } do
			local folder = newInstance("Folder", part)
			folder.Parent = tree
			if part == "Client" then
				local boot = newInstance("ModuleScript", "boot")
				local source = [[
					if SMOKE.clientFailures["NAME"] > 0 then
						SMOKE.clientFailures["NAME"] -= 1
						error("client boot boom")
					end
					return { boot = function(kernel)
						SMOKE.clientKernel = kernel
						if kernel.onResync then
							kernel:onResync(function() SMOKE.resynced = (SMOKE.resynced or 0) + 1 end)
						end
						return function() end
					end }]]
				internals[boot].sourceText = (string.gsub(source, "NAME", name))
				boot.Parent = folder
			end
		end
		tree.Parent = generations
	end
	clientTree("aaaaaaa-111111#1", 1)
	clientTree("bbbbbbb-222222#2", 5)
	local clientScript = sourceInstance("Script", "TypeTorchKernelClient", "src/client/KernelClient.client.luau")
	clientScript.Parent = services.ReplicatedFirst
	if MODES38.clientBoot or MODES38.clientOwn then
		-- 0.3.8 loading screens: the server copied the game's settings onto this script before the player joined.
		local boot = MODES38.clientBoot
		local label = if boot then "client-boot" else "client-own"
		local function kernelScreen()
			return playerGui:FindFirstChild("TypeTorchHold")
		end
		local function bootScreen()
			return playerGui:FindFirstChild("Loading")
		end
		if boot then
			local source = newInstance("ScreenGui", "Loading")
			newInstance("Frame", "Splash").Parent = source
			-- It replicates a moment after the kernel client starts (ReplicatedFirst has no fixed order).
			task.delay(0.1, function()
				source.Parent = services.ReplicatedFirst
			end)
			clientScript:SetAttribute("BootScreen", "Loading")
		else
			clientScript:SetAttribute("KernelScreen", false)
		end
		-- 0.3.9: the join snapshot on the script, and the live hold on ReplicatedStorage.TypeTorch (later changes go
		-- there only: ReplicatedFirst replicates once).
		clientScript:SetAttribute("Hold", "start")
		root:SetAttribute("Hold", "start")
		Constants.CLIENT_RETRY_SECONDS = 0.1
		runScript(clientScript, function(err)
			table.insert(kernelErrors, err)
		end)
		task.wait(0.3)
		check(`{label}: the server holds: the kernel's "Starting..." stays off ({if boot then "the boot screen is cloned into PlayerGui" else "the game draws its own"}); Holding = start, no ClientReady yet`, kernelScreen() == nil and clientScript:GetAttribute("Holding") == "start" and clientScript:GetAttribute("ClientReady") == nil and (if boot then bootScreen() ~= nil and bootScreen().ResetOnSpawn == false and bootScreen():FindFirstChild("Splash") ~= nil else bootScreen() == nil))
		if not boot then
			root:SetAttribute("Hold", "move")
			check("client-own: a move always shows the kernel's screen (Reconnecting...)", waitFor("move", function()
				return kernelScreen() ~= nil and kernelScreen().Backdrop.Card.Label.Text == "Reconnecting..."
			end))
			root:SetAttribute("Hold", "start")
			check("client-own: back to the start hold: the kernel's screen goes again", waitFor("start", function()
				return kernelScreen() == nil and clientScript:GetAttribute("Holding") == "start"
			end, 2))
		end
		clientTree("aaaaaaa-111111#1", 0)
		root:SetAttribute("ActiveGeneration", "aaaaaaa-111111#1")
		check(`{label}: the first client generation runs: ClientReady = true, ClientGeneration = its name`, waitFor("ready", function()
			return clientScript:GetAttribute("ClientReady") == true and clientScript:GetAttribute("ClientGeneration") == "aaaaaaa-111111#1"
		end))
		check(`{label}: the server still holds: the game's screen stays, the kernel's stays off`, kernelScreen() == nil and (not boot or bootScreen() ~= nil))
		root:SetAttribute("Hold", nil) -- (the script keeps its join snapshot, "start")
		check(`{label}: the hold ends: {if boot then "the boot screen goes, " else ""}the kernel's never showed, Holding cleared`, waitFor("hand-over", function()
			return bootScreen() == nil and clientScript:GetAttribute("Holding") == nil
		end) and kernelScreen() == nil)
		-- Later holds (a failed swap clears ActiveGeneration and the server holds again) are the kernel's, as in 0.3.6.
		root:SetAttribute("ActiveGeneration", nil)
		root:SetAttribute("Hold", "start")
		check(`{label}: a later hold shows the kernel's "Starting..."; ClientGeneration cleared, ClientReady stays`, waitFor("re-hold", function()
			return kernelScreen() ~= nil and kernelScreen().Backdrop.Card.Label.Text == "Starting..." and clientScript:GetAttribute("ClientGeneration") == nil
		end) and clientScript:GetAttribute("ClientReady") == true)
		finish()
	end
	-- 0.3.6: the server holds players (nothing runs yet): the client covers the place from its first line. 0.3.9: the
	-- server marks the script (the JOIN snapshot: ReplicatedFirst replicates once, so this client never sees a later
	-- change there) and ReplicatedStorage.TypeTorch (live: every later change goes only there below).
	clientScript:SetAttribute("Hold", "start")
	clientScript:SetAttribute("HoldReason", "boot: no generation runs yet")
	root:SetAttribute("Hold", "start")
	root:SetAttribute("HoldReason", "boot: no generation runs yet")
	runScript(clientScript, function(err)
		table.insert(kernelErrors, err)
	end)
	local function screen()
		return playerGui:FindFirstChild("TypeTorchHold")
	end
	local function screenText(): string?
		local gui = screen()
		return gui and gui.Backdrop.Card.Label.Text
	end
	waitFor("the holding screen", function()
		return screen() ~= nil
	end, 2)
	local shownMs = if screen() then screen():GetAttribute("ShownMs") else nil
	check(string.format("hold: the holding screen is up from the client's first line (time-to-held %s ms after the client script started; target < 1000)", tostring(shownMs)), shownMs ~= nil and shownMs < 1000 and screenText() == "Starting..." and screen().IgnoreGuiInset == true and screen().Backdrop.BackgroundTransparency == nil)
	check("hold: Holding = start on the kernel client script (0.3.8), no ClientReady yet", clientScript:GetAttribute("Holding") == "start" and clientScript:GetAttribute("ClientReady") == nil)
	check("0.3.9: HoldReason next to Holding says why (the server's reason)", clientScript:GetAttribute("HoldReason") == "server hold start: boot: no generation runs yet")
	check("hold: no emojis, a few words, a UIScale pop and a progress bar", (function()
		local card = screen().Backdrop.Card
		local text = screenText() or ""
		return card:FindFirstChildOfClass("UIScale") ~= nil and card.Track.Fill ~= nil and #string.split(text, " ") <= 2 and not string.find(text, "[ -¤]")
	end)())
	local function lastReport()
		for index = #firedToServer, 1, -1 do
			local call = firedToServer[index]
			if call[1] == "Net" and call[2] == "*" and call[3] == "__tt/client" then
				return call[4]
			end
		end
		return nil
	end
	Constants.CLIENT_RETRY_SECONDS = 0.1
	Constants.CLIENT_RESEND_WAIT = 1
	task.wait(0.1)
	root:SetAttribute("ActiveGeneration", "aaaaaaa-111111#1")
	check("client: a generation that fails once starts on the retry (fresh copy of its tree)", waitFor("client A", function()
		local report = lastReport()
		return report ~= nil and report.g == "aaaaaaa-111111#1" and report.ok == true and report.retried == true and typeof(report.ms) == "number"
	end) and SMOKE.clientKernel ~= nil and localPlayer.PlayerScripts:FindFirstChild("TypeTorchRetry") ~= nil)
	check("hold: the screen stays while the server still holds", screen() ~= nil and screenText() == "Starting...")
	check("client: ClientReady = true and ClientGeneration once the first client generation runs (0.3.8)", clientScript:GetAttribute("ClientReady") == true and clientScript:GetAttribute("ClientGeneration") == "aaaaaaa-111111#1")
	-- 0.3.9 THE BUG: the server released, but this client joined during the hold and its ReplicatedFirst script still says
	-- "start" (never replicated again). Only ReplicatedStorage.TypeTorch changes.
	root:SetAttribute("Hold", nil)
	root:SetAttribute("HoldReason", nil)
	check("hold: the server's hold ends and this client's generation runs: the screen pops out", waitFor("screen gone", function()
		return screen() == nil
	end, 2))
	check("0.3.9: ... although the script's join snapshot still says Hold = start (ReplicatedFirst replicates once); Holding and HoldReason cleared", clientScript:GetAttribute("Hold") == "start" and clientScript:GetAttribute("Holding") == nil and clientScript:GetAttribute("HoldReason") == nil)
	check("0.3.9: one line per screen change in the client's log ring (Logs, Logs > Upload): up with the server's reason, down with the generation", waitFor("ring", function()
		return SMOKE.ringHas(SMOKE.clientKernel, "[TypeTorch] screen up (Starting...): server hold start: boot: no generation runs yet")
			and SMOKE.ringHas(SMOKE.clientKernel, "[TypeTorch] screen down: generation aaaaaaa-111111#1 running")
	end, 2))
	-- P-N1: a resync naming this generation's artifact reaches it (the framework fails its pending calls); one naming
	-- another artifact doesn't.
	local net = root.Net
	net.OnClientEvent:Fire("bbbbbbb-222222", "__tt/resync", "zzzzzzz-000000")
	net.OnClientEvent:Fire("bbbbbbb-222222", "__tt/resync", "aaaaaaa-111111")
	check("P-N1: the client generation hears a resync of its own artifact only", waitFor("resync", function()
		return SMOKE.resynced == 1
	end))
	root:SetAttribute("ActiveGeneration", "bbbbbbb-222222#2")
	check("client: a generation that keeps failing is reported failed after its one retry", waitFor("client B", function()
		local report = lastReport()
		return report ~= nil and report.g == "bbbbbbb-222222#2" and report.ok == false and report.retried == true and string.find(report.e or "", "client boot boom", 1, true) ~= nil
	end) and SMOKE.clientFailures["bbbbbbb-222222#2"] == 3)
	check("client: the retry copy of the stopped generation was destroyed", #localPlayer.PlayerScripts.TypeTorchRetry:GetChildren() == 0)
	-- 0.3.6: failed after its retry: the holding screen covers the broken UI; the server re-sends the client code.
	check("client-fail: after the retry failed the holding screen shows Loading...", waitFor("loading", function()
		return screenText() == "Loading..."
	end))
	local function resend(name: string, failures: number)
		local folder = playerGui:FindFirstChild("TypeTorchResend") or newInstance("Folder", "TypeTorchResend")
		folder.Parent = playerGui
		local before = #generations:GetChildren()
		clientTree(name, failures) -- builds into Generations; the server's copy goes to PlayerGui instead
		local tree = generations:FindFirstChild(name)
		if #generations:GetChildren() > before then
			tree.Parent = folder
		else
			local copy = tree:Clone()
			copy.Parent = folder
		end
		root.Net.OnClientEvent:Fire("*", "__tt/resend", { g = name })
	end
	SMOKE.clientFailures["bbbbbbb-222222#2"] = 0
	resend("bbbbbbb-222222#2", 0)
	check("client-fail: the re-sent client code starts and is reported (resent), the screen goes", waitFor("resent B", function()
		local report = lastReport()
		return report ~= nil and report.g == "bbbbbbb-222222#2" and report.ok == true and report.resent == true
	end) and waitFor("screen gone", function()
		return screen() == nil
	end, 2))
	-- A generation that fails everywhere, the re-sent copy too: reported, the screen says Reconnecting... (the server moves
	-- this player).
	clientTree("ccccccc-333333#3", 10)
	root:SetAttribute("ActiveGeneration", "ccccccc-333333#3")
	waitFor("C failed", function()
		local report = lastReport()
		return report ~= nil and report.g == "ccccccc-333333#3" and report.retried == true
	end)
	resend("ccccccc-333333#3", 10)
	check("client-fail: the re-sent copy fails too: reported (resent), the screen shows Reconnecting...", waitFor("resent C", function()
		local report = lastReport()
		return report ~= nil and report.g == "ccccccc-333333#3" and report.ok == false and report.resent == true
	end) and screenText() == "Reconnecting...")
	-- The server lost its generation (a failed swap cleared ActiveGeneration): the client stops the dead one.
	root:SetAttribute("ActiveGeneration", "aaaaaaa-111111#1")
	SMOKE.clientFailures["aaaaaaa-111111#1"] = 0
	waitFor("A again", function()
		local report = lastReport()
		return report ~= nil and report.g == "aaaaaaa-111111#1" and report.ok == true
	end)
	local stopsBefore = SMOKE.clientKernel
	root:SetAttribute("ActiveGeneration", nil)
	root:SetAttribute("Hold", "start")
	root:SetAttribute("HoldReason", "a failed swap: smoke")
	check("hold: ActiveGeneration cleared (nothing runs on the server): the dead client generation stops, the screen covers", waitFor("stopped", function()
		return #localPlayer.PlayerScripts:GetChildren() <= 1 and screenText() == "Starting..."
	end) and stopsBefore ~= nil)
	-- 0.3.9 FAIL-SAFE: a generation runs again (on the server and here) but the server's hold stays "start" (a server
	-- bookkeeping bug): the screen comes down by itself after 5 s, with a loud warning of what it saw.
	SMOKE.clientFailures["aaaaaaa-111111#1"] = 0
	root:SetAttribute("ActiveGeneration", "aaaaaaa-111111#1")
	check("0.3.9 fail-safe: the client's generation runs while the hold says start: the screen stays for now", waitFor("A runs", function()
		return clientScript:GetAttribute("ClientGeneration") == "aaaaaaa-111111#1"
	end) and screenText() == "Starting...")
	local failSafeAt = os.clock()
	local function failSafeWarned(): boolean
		for _, line in output do
			if line.kind == "warn" and string.find(line.text, "FAIL-SAFE: the holding screen came down by itself", 1, true) and string.find(line.text, "a failed swap: smoke", 1, true) then
				return true
			end
		end
		return false
	end
	check("0.3.9 fail-safe: about 5 s later the screen comes down, warned with the state it saw", waitFor("fail-safe", function()
		return screen() == nil and failSafeWarned()
	end, 8) and os.clock() - failSafeAt >= 4.5 and clientScript:GetAttribute("Holding") == nil)
	-- A new hold from the server (another reason) is honoured again; a "move" hold is real and never dropped.
	root:SetAttribute("Hold", "move")
	root:SetAttribute("HoldReason", "nothing runs: moving players")
	check("0.3.9 fail-safe: a later move hold shows (Reconnecting...) and stays past the fail-safe time", waitFor("move", function()
		return screenText() == "Reconnecting..."
	end) and (function()
		task.wait(5.6)
		return screenText() == "Reconnecting..." and clientScript:GetAttribute("Holding") == "move"
	end)())
	finish()
end

if DEV_MODE then
	check("dev: a reserved dev-branch server boots the unsigned dev head", waitFor("boot", function()
		return running() == "ddddddd-444444"
	end))
	check("dev: no signatures required", status().signedOnly == false and status().branch == "dev")
	publish("TypeTorch/deploy", { b = "dev", a = 1002, i = "bbbbbbb-222222", s = 20, c = "bbbbbbb", ch = "dev", t = nowMs() })
	check("dev: an unsigned deploy swaps", waitFor("swap to B", function()
		return running() == "bbbbbbb-222222" and status().appliedSeq == 20
	end))
	-- 0.3.2 (P-N1): a client still tagging the previous artifact (same ProtocolHash) reaches the running generation;
	-- another protocol gets a resync that names the dropped artifact.
	local client = newInstance("Player", "Client1")
	client.UserId = 5
	local net = services.ReplicatedStorage.TypeTorch.Net
	net.OnServerEvent:Fire(client, "ddddddd-444444", "e:ping", 1)
	check("P-N1: an old-id message of the same protocol reaches the running generation", waitFor("message", function()
		for _, message in SMOKE.messages do
			if message[1] == "bbbbbbb-222222" and message[2] == "e:ping" then
				return true
			end
		end
		return false
	end))
	local function resynced(artifactId: string): boolean
		for _, call in firedToClient do
			if call[1] == client and call[3] == "__tt/resync" and call[4] == artifactId then
				return true
			end
		end
		return false
	end
	net.OnServerEvent:Fire(client, "zzzzzzz-000000", "e:ping", 2)
	check("P-N1: another protocol gets a resync naming the dropped artifact", waitFor("resync", function()
		return resynced("zzzzzzz-000000")
	end))
	net.OnServerEvent:Fire(client, "ddddddd-444444", "r:shop.buy", 7, "sword")
	check("P-N1: a request of the old artifact is never taken (its reply couldn't reach it): resync", waitFor("request resync", function()
		return resynced("ddddddd-444444")
	end) and (function()
		for _, message in SMOKE.messages do
			if message[2] == "r:shop.buy" then
				return false
			end
		end
		return true
	end)())
	-- 0.3.9: channel = what the branch is (dev); the rules stay prod while a prod-channel build (B) runs here, as before.
	check("0.3.9 dev: channel dev (heartbeat c dev); rules prod while a prod-channel build runs", status().channel == "dev" and status().rules == "prod" and SMOKE.kernel:fleetStatus().c == "dev" and SMOKE.kernel.channel == "prod")
	finish()
end
if DURABLE_MODE then
	local function devHead(store)
		return store.data.heads and store.data.heads.dev
	end
	check("durable: a new server boots the head only the DataStore copy holds (#45, no server heard it)", waitFor("boot #45", function()
		return running() == "kkkkkkk-111111" and status().appliedSeq == 45
	end))
	check("durable: it boots #45 directly (the boot waits for the DataStore copy; #44 never ran)", SMOKE.boots[1] == "kkkkkkk-111111" and #SMOKE.boots == 1)
	LATENCY.datastoreGet = 0.05 -- the periodic reads below
	check("durable: it writes MemoryStore back (#44 -> #45)", waitFor("memory #45", function()
		return devHead(memoryStore).seq == 45 and devHead(memoryStore).assetId == 1011
	end))
	local listed = nil
	for _, branch in SMOKE.kernel:branches() do
		if branch.name == "dev" then
			listed = branch
		end
	end
	check("durable: the dev menu lists #45 as the dev head", listed ~= nil and listed.seq == 45 and listed.artifactId == "kkkkkkk-111111")
	-- The CLI deploys #46 while this server runs, and the message is lost (no MessagingService delivery here at all):
	-- only the DataStore copy changes.
	local readsBefore, memoryBefore, startedAt = dataStore.reads.heads or 0, memoryStore.reads.heads or 0, os.clock()
	dataStore.data.heads.dev = cliHead(46, 1012, "lllllll-121212")
	table.insert(dataStore.data.deployments.list, 1, cliEntry(46, 1012, "lllllll-121212"))
	local followed = waitFor("follow #46", function()
		return running() == "lllllll-121212" and status().appliedSeq == 46
	end, 4)
	local tookTicks = (os.clock() - startedAt) / Constants.POLL_SECONDS
	check(string.format("durable: the running server follows the CLI-only head within about one sync tick (%.1f ticks = %.0f s at full scale)", tookTicks, tookTicks * 60), followed and tookTicks <= 2.5)
	check("durable: MemoryStore catches up (#46)", waitFor("memory #46", function()
		return devHead(memoryStore).seq == 46
	end))
	-- Budget over about 5 ticks: one durable read per tick at most (MemoryStore is read every tick too).
	task.wait(Constants.POLL_SECONDS * 5)
	local window = os.clock() - startedAt
	local durableReads = (dataStore.reads.heads or 0) - readsBefore
	local memoryReads = (memoryStore.reads.heads or 0) - memoryBefore
	local allowed = math.floor(window / Constants.HEADS_DURABLE_SECONDS) + 1
	check(`durable: DataStore heads reads within budget ({durableReads} in {string.format("%.1f", window / Constants.POLL_SECONDS)} ticks, at most {allowed}; MemoryStore {memoryReads})`, durableReads >= 1 and durableReads <= allowed)
	-- A lower seq in the durable copy (an older CLI run, or forged) is never followed nor written back.
	dataStore.data.heads.dev = cliHead(43, 1013, "mmmmmmm-131313")
	task.wait(Constants.POLL_SECONDS * 3)
	check("durable: a lower seq in the DataStore copy is ignored", running() == "lllllll-121212" and devHead(memoryStore).seq == 46)
	check("durable: no deploy message was involved", status().lastMessage == nil)
	finish()
end
if VIP_MODE then
	check("vip: a non-dev's private server ignores its stored dev branch and boots signed prod", waitFor("boot", function()
		return running() == "aaaaaaa-111111"
	end) and status().branch == "prod" and status().signedOnly == true and rejected("private-branch") == 1)
	finish()
end
if BOOTSTRAP_MODE or BOOTSTRAP_ONLY_MODE then
	local label = if BOOTSTRAP_MODE then "the unsigned stored head matching BootstrapHeads" else "the BootstrapHeads entry itself"
	check(`bootstrap: boots {label}`, waitFor("boot", function()
		return running() == "aaaaaaa-111111"
	end) and status().appliedSeq == 10 and status().noTrustedHead == nil)
	check("bootstrap: no verified badge (unsigned)", status().generation.artifact.verified == nil)
	check("bootstrap: keys() lists it", SMOKE.kernel:keys().bootstrap.prod ~= nil and SMOKE.kernel:keys().bootstrap.prod.seq == 10)
	publish("TypeTorch/deploy", deployMessage(nil, FIELDS.M4))
	check("bootstrap: anything newer must be signed (unsigned refused)", waitFor("refusal", function()
		return rejected("deploy") == 1
	end) and running() == "aaaaaaa-111111")
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("bootstrap: a signed deploy swaps", waitFor("swap to B", function()
		return running() == "bbbbbbb-222222" and status().appliedSeq == 11
	end))
	finish()
end
local function said(text: string): boolean
	for _, line in output do
		if string.find(line.text, text, 1, true) then
			return true
		end
	end
	return false
end
if BLIND_MODE then
	-- No verified head, no bootstrap head: the boot fail-safe skips the forged dev-channel head (seq 99) and boots the
	-- unsigned prod head (seq 10), flagged.
	check("blind: boots the unverified stored head (the dev-channel forgery skipped)", waitFor("boot", function()
		return running() == "aaaaaaa-111111"
	end))
	local s0 = status()
	check("blind: flagged unverified, no verified badge, appliedSeq untouched", s0.unverified == true and s0.generation.artifact.verified == nil and s0.appliedSeq == -1)
	check("blind: warned", said("BOOT FAIL-SAFE"))
	check("blind: event booted_unverified", hasEvent("booted_unverified", "assetId", 1001))
	-- Updates stay strictly verified: an unsigned deploy, an unsigned pin, and a forged newer stored head.
	publish("TypeTorch/deploy", deployMessage(nil, FIELDS.M4))
	local pin = table.clone(FIELDS.P2)
	pin.t = nowMs()
	publish("TypeTorch/pin", pin)
	memoryStore.data.heads.prod = { assetId = 1002, artifactId = "bbbbbbb-222222", seq = 300, commit = "bbbbbbb", channel = "prod", t = nowMs(), deployedAt = "2026-10-05T00:00:00Z" }
	task.wait(1.5) -- several polls
	check("blind: unsigned deploy, unsigned pin and a forged newer head are refused", rejected("deploy") == 1 and rejected("pin") == 1 and running() == "aaaaaaa-111111")
	local admin = newInstance("Player", "Owner")
	admin.UserId = 1
	local rollback = SMOKE.kernel:rollback(admin)
	check("blind: still flagged after the refusals", status().unverified == true and rollback.ok == false)
	-- A signed head for the SAME asset vouches for it: no swap, the flag clears.
	local boots = #SMOKE.boots
	publish("TypeTorch/deploy", deployMessage("H1", FIELDS.H1, { "sig" }))
	check("blind: a signed message for the running asset clears the flag without a swap", waitFor("vouch", function()
		return status().unverified == nil and status().appliedSeq == 10
	end) and #SMOKE.boots == boots and status().generation.artifact.verified ~= nil)
	-- The next signed deploy (seq 11, below the forged 99 and 300) still lands: the blind boot didn't move appliedSeq.
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("blind: the next signed deploy swaps", waitFor("swap to B", function()
		return running() == "bbbbbbb-222222" and status().appliedSeq == 11
	end))
	-- The vouched-for generation is a verified rollback target now.
	local back = SMOKE.kernel:rollback(admin)
	check("blind: /tt rollback to the vouched generation works", back.ok == true and running() == "aaaaaaa-111111" and status().unverified == nil)
	finish()
end
if EMPTY_MODE then
	-- Every stored head fails its checks (dev channel; a Script inside): the server stays empty and says so.
	task.wait(1)
	check("empty: nothing loads", SMOKE.kernel == nil and said("nothing loaded"))
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("empty: the next signed deploy boots it", waitFor("boot B", function()
		return SMOKE.kernel ~= nil and running() == "bbbbbbb-222222"
	end))
	check("empty: not flagged unverified", status().unverified == nil and status().noTrustedHead == nil)
	finish()
end

if STUDIO_MODE then
	-- 0.3.1: Studio with ServerStorage.TypeTorchDev.Payload: a clone of it boots (not the stored dev head), on branch
	-- "dev", dev channel; deploys and the poll don't move it; Reload remounts a fresh clone; the same mount checks apply.
	local function isLocalId(id): boolean
		return typeof(id) == "string" and string.sub(id, 1, 6) == "local-"
	end
	check("studio: boots the local payload", waitFor("boot", function()
		return isLocalId(running())
	end))
	local s0 = status()
	check("studio: localPayload, studio server, branch dev, dev channel, no asset id", s0.localPayload == true and s0.serverType == "studio" and s0.branch == "dev" and s0.channel == "dev" and s0.generation.artifact.channel == "dev" and s0.generation.artifact.assetId == nil and s0.signedOnly == false)
	check("studio: the source stays put (a clone was mounted)", localSource.Parent == devFolder and localSource:FindFirstChild("Server") ~= nil and localSource:FindFirstChild("Client") ~= nil and localSource:GetAttribute("ArtifactId") == nil and #SMOKE.boots == 1)
	publish("TypeTorch/deploy", { b = "dev", a = 1002, i = "bbbbbbb-222222", s = 20, c = "bbbbbbb", ch = "dev", t = nowMs() })
	task.wait(0.8) -- several polls, with a newer stored dev head
	check("studio: a deploy message and the poll don't move it", isLocalId(running()) and #SMOKE.boots == 1 and said("not applied: this Studio session runs the local payload"))
	local owner = newInstance("Player", "Owner")
	owner.UserId = 1
	local first = status().generation.name
	local reloaded = SMOKE.kernel:reload(owner)
	check("studio: Reload remounts a fresh clone", reloaded.ok == true and isLocalId(running()) and status().generation.name ~= first and #SMOKE.boots == 2 and #SMOKE.stops == 1 and localSource.Parent == devFolder)
	local sneaky = newInstance("Script", "Sneaky")
	sneaky.Parent = localSource.Shared
	local before = status().generation.name
	local refused = SMOKE.kernel:reload(owner)
	check("studio: a local payload holding a Script is refused at mount", refused.ok == false and string.find(refused.error or "", "Folders and ModuleScripts", 1, true) ~= nil and status().generation.name == before)
	sneaky:Destroy()
	local pinned = SMOKE.kernel:pinArtifact(owner, 1002)
	check("studio: an uploaded artifact can still be pinned", pinned.ok == true and running() == "bbbbbbb-222222" and status().localPayload == nil)
	local back = SMOKE.kernel:reload(owner)
	check("studio: Reload goes back to the local payload", back.ok == true and isLocalId(running()) and status().localPayload == true)
	localSource.Parent = nil
	local missing = SMOKE.kernel:reload(owner)
	check("studio: Reload without a source fails cleanly", missing.ok == false and string.find(missing.error or "", "TypeTorchDev.Payload", 1, true) ~= nil and isLocalId(running()))
	localSource.Parent = devFolder
	check("studio: fleet status and deploy reports on the API, nothing written", #sortedMapRequests == 0 and SMOKE.kernel:fleetStatus().t == "studio" and typeof(SMOKE.kernel:deployReports()) == "table")
	finish()
end

-- 0.3.2 helpers: the newest kept report of a seq (api:deployReports()), this server's fleet status, what a
-- generation's report listener heard, and the running Entry clone.
local JOB = GAME_ROOT_PROPS.JobId
local function reportOf(seq: number)
	local list = SMOKE.kernel:deployReports()
	for index = #list, 1, -1 do
		if list[index].s == seq then
			return list[index]
		end
	end
	return nil
end
local function fleet()
	return SMOKE.kernel:fleetStatus()
end

if MODES38.rollbackPrev then
	check("rollback-prev: a fresh public server boots the signed head B (#11) straight away", waitFor("boot", function()
		return running() == "bbbbbbb-222222"
	end) and #status().history == 1 and status().signedOnly == true)
	local first = SMOKE.kernel:rollback(nil)
	check("rollback-prev: no earlier build anywhere: the error says what to do (typetorch rollback <branch>)", first.ok == false and string.find(first.error or "", "typetorch rollback prod", 1, true) ~= nil and running() == "bbbbbbb-222222")
	-- The CLI (0.9) keeps the branch's last heads as `prev` on the durable head: a forged unsigned one (#10, D: game code
	-- can write the store) and the signed H1 (#10, A).
	local h1Fields = FIELDS.H1
	dataStore.data.heads.prod.prev = {
		{ assetId = 1004, artifactId = "ddddddd-444444", seq = 10, commit = "ddddddd", channel = "prod", t = 1759580110000, deployedAt = "2026-10-04T00:00:00Z" },
		{ assetId = h1Fields.a, artifactId = h1Fields.i, seq = h1Fields.s, commit = h1Fields.c, channel = h1Fields.ch, t = h1Fields.t, sig = SIGS.H1.sig, sigF = SIGS.H1.sigF, deployedAt = "2026-10-04T00:00:00Z" },
	}
	local second = SMOKE.kernel:rollback(nil)
	check("rollback-prev: the branch's previous heads: the forged unsigned one is refused (signed server), the signed H1 (#10) runs", second.ok == true and running() == "aaaaaaa-111111" and (assets[1004].loads or 0) == 0)
	check("rollback-prev: a server-local swap (reason server_rollback, logged with source branch, appliedSeq stays 11)", status().appliedSeq == 11 and hasEvent("server_rollback", "source", "branch") and said("nothing earlier ran on this server; the branch's previous head aaaaaaa-111111 #10") and SMOKE.kernel.start.reason == "server_rollback")
	task.wait(0.4)
	check("rollback-prev: it holds (the poll doesn't move it back to the head)", running() == "aaaaaaa-111111")
	-- The kernel's durable write keeps `prev` (the head it replaces first, newest first, at most 3); MemoryStore never.
	publish("TypeTorch/deploy", deployMessage("M9", FIELDS.M9, { "sig" }))
	check("rollback-prev: a newer signed deploy of the running build: the durable head's prev = B #11, then its own prev (3 kept, newest first)", waitFor("durable prev", function()
		local head = dataStore.data.heads.prod
		local prev = head and head.prev
		return head.seq == 18 and prev ~= nil and #prev == 3 and prev[1].seq == 11 and prev[1].sig ~= nil and prev[2].seq == 10 and prev[3].seq == 10 and prev[1].prev == nil
	end) and memoryStore.data.heads.prod.seq == 18 and memoryStore.data.heads.prod.prev == nil and status().appliedSeq == 18)
	finish()
end
local function heard(name: string, seq: number, result: string): boolean
	for _, report in SMOKE.heard[name] or {} do
		if report.s == seq and report.r == result then
			return true
		end
	end
	return false
end
local function reported(seq: number, result: string): boolean
	local value = reportOf(seq)
	return value ~= nil and value.r == result
end
local function currentEntry()
	local s = status()
	return s.generation and services.ServerScriptService.TypeTorchEntries:FindFirstChild(s.generation.name)
end
local function rolledBackFrom(artifactId: string, to: string): boolean
	local health = status().health
	return health.lastRollback ~= nil and health.lastRollback.from == artifactId and running() == to
end

if SWITCH_MODE then
	local function player(userId: number, name: string)
		local instance = newInstance("Player", name)
		instance.UserId = userId
		instance.Parent = GAME_ROOT -- in the game (Parent ~= nil)
		return instance
	end
	-- Owner = the creator (1); CoOwner = a member with role "owner" (4); Legacy = a member with the old role "admin" (2);
	-- Stranger = no dev (3).
	local owner, legacy, stranger, coOwner = player(1, "Owner"), player(2, "Legacy"), player(3, "Stranger"), player(4, "CoOwner")
	for _, each in { owner, legacy, stranger, coOwner } do
		table.insert(fakePlayers, each)
	end
	local net = nil
	local nextId = 0
	-- The player's own client asks (kernel transport, tagged "*"); returns the kernel's answer.
	local function ask(who, request)
		net = net or services.ReplicatedStorage.TypeTorch.Net
		nextId += 1
		local id = nextId
		request.id = id
		net.OnServerEvent:Fire(who, "*", "__tt/switch", request)
		local answer = nil
		waitFor(`answer {id}`, function()
			for _, call in firedToClient do
				if call[1] == who and call[3] == "__tt/switch" and type(call[4]) == "table" and call[4].id == id then
					answer = call[4]
					return true
				end
			end
			return false
		end, 6)
		return answer or {}
	end
	local function alerts(code: string)
		local list = {}
		for _, request in httpRequests do
			if request.body and request.body.code == code then
				table.insert(list, request.body)
			end
		end
		return list
	end
	local function gap()
		task.wait(0.4) -- SWITCH_GAP is 0.3 s here
	end

	check("switch: a public prod server boots the signed prod head", waitFor("boot", function()
		return running() == "aaaaaaa-111111"
	end) and status().signedOnly == true)

	-- No admins: the old role "admin" is a dev (least privilege), with a warning; role "owner" members are owners.
	local api = SMOKE.kernel
	check("switch: a legacy admin member is a dev, warned once", api:devInfo(legacy).role == "dev" and said("role admin no longer exists: use owner or dev") and api:devInfo(coOwner).role == "owner" and api:devInfo(owner).role == "owner")

	-- Payload code can't do it for a player: the server API refuses on a prod server.
	local viaSwitch = api:switchBranch(owner, "dev")
	local viaPin = api:pinArtifact(owner, 1004)
	check("switch: no server API switches or loads unsigned builds on a prod server (payload code can't act for the owner)", api.requestSwitch == nil and api.ownerSwitch == nil and viaSwitch.ok == false and viaPin.ok == false and running() == "aaaaaaa-111111")

	-- Non-owners are refused (a non-dev, a legacy admin).
	local refused = ask(stranger, { branch = "dev" })
	gap()
	local refusedLegacy = ask(legacy, { branch = "dev" })
	check("switch: non-owners are refused (a legacy admin too)", refused.ok == false and refusedLegacy.ok == false and string.find(refusedLegacy.error or "", "only the owner", 1, true) ~= nil and running() == "aaaaaaa-111111")

	-- The owner switches THIS public prod server to dev: an ordinary switch, players stay.
	local generationBefore = status().generation.number
	local switched = ask(owner, { branch = "dev" })
	local tooSoon = ask(owner, { branch = "prod" })
	local s1 = status()
	check("switch: the owner switches the public prod server to dev", switched.ok == true and running() == "ddddddd-444444" and s1.branch == "dev" and s1.serverType == "public" and s1.generation.number > generationBefore)
	check("switch: players stay (no kick, no teleport)", #kicked == 0 and fleet().n == 4)
	-- 0.3.9: the channel is what the branch is (dev); the rules this public server applies stay prod.
	local root = services.ReplicatedStorage.TypeTorch
	check("0.3.9 channel: a dev branch on a public server reports channel dev, rules prod (status, heartbeat c, root BranchChannel)", s1.channel == "dev" and s1.rules == "prod" and fleet().c == "dev" and root:GetAttribute("BranchChannel") == "dev")
	check("0.3.9 channel: the payload API keeps channel = the rules (older frameworks gate on it), adds rules and branchChannel; root Channel = rules", SMOKE.kernel.channel == "prod" and SMOKE.kernel.rules == "prod" and SMOKE.kernel.branchChannel == "dev" and root:GetAttribute("Channel") == "prod")
	services.TextChatService.TypeTorchCommand.Triggered:Fire({ UserId = 1 }, "/tt status")
	check("0.3.9 channel: /tt status says the branch's channel and the stricter rules", waitFor("tt status", function()
		for _, call in firedToClient do
			if call[1] == owner and call[3] == "__tt/notice" and string.find(tostring(call[4]), "branch dev (dev, prod rules)", 1, true) then
				return true
			end
		end
		return false
	end))
	check("switch: status().switched = {by, name, at, branch}; the heartbeat's b is the branch; no ov", s1.switched ~= nil and s1.switched.by == 1 and s1.switched.name == "Owner" and s1.switched.branch == "dev" and typeof(s1.switched.at) == "number" and s1.ov == nil and fleet().b == "dev" and fleet().ov == nil)
	check("switch: a branch_switch alert (info) is posted and the server logs it", waitFor("alert", function()
		local list = alerts("branch_switch")
		return #list == 1 and list[1].level == "info" and string.find(list[1].message, "switched this server to dev", 1, true) ~= nil
	end) and said("Owner (1) switched this server to dev") and hasEvent("branch_switch", "by", 1) and #alerts("owner_override") == 0)

	-- A signed prod deploy doesn't move it (it follows dev now); nothing is stored, so new servers boot prod.
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	task.wait(0.6)
	check("switch: a signed prod deploy doesn't move it", running() == "ddddddd-444444")
	check("switch: new servers still boot the signed prod head (nothing stored)", (function()
		local memoryHead = memoryStore.data.heads and memoryStore.data.heads.prod
		for key in dataStore.data do
			if string.sub(tostring(key), 1, 8) == "private/" then
				return false
			end
		end
		return memoryHead ~= nil and memoryHead.artifactId == "bbbbbbb-222222" and memoryHead.sig ~= nil
	end)())
	-- A dev deploy does (dev rules: unsigned).
	publish("TypeTorch/deploy", { b = "dev", a = 1003, i = "ccccccc-333333", s = 21, c = "ccccccc", ch = "dev", t = nowMs() })
	check("switch: a dev deploy moves it (dev rules, unsigned)", waitFor("dev deploy", function()
		return running() == "ccccccc-333333" and status().appliedSeq == 21
	end))
	check("switch: one request per player per SWITCH_GAP", tooSoon.ok == false and string.find(tooSoon.error or "", "one switch per", 1, true) ~= nil)
	gap()

	-- Reload and Rollback work on the current branch and history (nothing locks the server).
	local generationBeforeReload = status().generation.number
	local reloaded = api:reload(owner)
	check("switch: Reload works afterwards (the dev head again)", reloaded.ok == true and running() == "ccccccc-333333" and status().generation.number > generationBeforeReload)
	local rolledBack = api:rollback(owner)
	check("switch: Rollback works afterwards (the previous build here)", rolledBack.ok == true and running() == "ddddddd-444444")
	local refusedRollback = api:rollback(legacy)
	check("switch: a dev can't roll back a public (prod-channel) server", refusedRollback.ok == false and string.find(refusedRollback.error or "", "only the owner", 1, true) ~= nil)

	-- Load here: a normal pin of a known build on this server; the next deploy of its branch moves it.
	local loaded = ask(owner, { assetId = 1001 })
	check("switch: the owner loads a build here (a normal pin)", loaded.ok == true and running() == "aaaaaaa-111111" and status().pinned == true and status().switched.artifact == "aaaaaaa-111111" and waitFor("build_load alert", function()
		return #alerts("build_load") == 1 and alerts("build_load")[1].level == "info"
	end), { ok = loaded.ok, running = running(), pinned = status().pinned, switched = status().switched })
	publish("TypeTorch/deploy", { b = "dev", a = 1004, i = "ddddddd-444444", s = 22, c = "ddddddd", ch = "dev", t = nowMs() })
	check("switch: the next deploy of the branch moves a pinned server (normal pin semantics)", waitFor("dev deploy 2", function()
		return running() == "ddddddd-444444" and status().appliedSeq == 22
	end))
	gap()

	-- Back to prod = Switch on the prod row: the verified prod head, by the signed rules.
	local back = ask(owner, { branch = "prod" })
	local s2 = status()
	check("switch: switching to prod runs the verified prod head (signed rules again)", back.ok == true and running() == "bbbbbbb-222222" and s2.branch == "prod" and s2.signedOnly == true and s2.generation.artifact.verified ~= nil)
	publish("TypeTorch/deploy", { b = "prod", a = 1004, i = "ddddddd-444444", s = 40, c = "ddddddd", ch = "prod", t = nowMs() })
	check("switch: back on prod an unsigned prod deploy is refused again", waitFor("refusal", function()
		return rejected("deploy") >= 1
	end) and running() == "bbbbbbb-222222")
	gap()

	-- The owner loads an unsigned dev build on the prod server (their own client only), then Reload goes back to prod.
	local devOnProd = ask(owner, { assetId = 1003 })
	check("switch: the owner loads a dev build on a prod server from their own client", devOnProd.ok == true and running() == "ccccccc-333333" and status().branch == "prod" and status().pinned == true)
	local reloadProd = api:reload(owner)
	check("switch: Reload goes back to the verified prod head", reloadProd.ok == true and running() == "bbbbbbb-222222" and status().generation.artifact.verified ~= nil)
	gap()

	-- A member with role "owner" is an owner; /tt branch works for owners.
	local byCoOwner = ask(coOwner, { branch = "dev" })
	check("switch: a member with role owner switches too", byCoOwner.ok == true and status().branch == "dev" and status().switched.by == 4)
	gap()
	local commandSignal = services.TextChatService.TypeTorchCommand.Triggered
	commandSignal:Fire({ UserId = 1 }, "/tt branch prod")
	check("switch: /tt branch prod by the owner", waitFor("tt branch", function()
		return status().branch == "prod" and running() == "bbbbbbb-222222"
	end))
	check("0.3.9 channel: back on prod: channel prod, rules prod", status().channel == "prod" and status().rules == "prod" and fleet().c == "prod")
	check("switch: no /tt back, no override field anywhere", status().ov == nil and fleet().ov == nil and not said("OWNER OVERRIDE"))
	finish()
end

if FLEET_MODE then
	local PREFIX = "https://fleet.example.test/api/v1/fleet/"
	local function requests(path: string, from: number?)
		local list = {}
		for index = from or 1, #httpRequests do
			local request = httpRequests[index]
			if request.url == PREFIX .. path then
				table.insert(list, request)
			end
		end
		return list
	end
	local function alerted(code: string, from: number?)
		for _, request in requests("alert", from) do
			if request.body.code == code and request.status == 200 then
				return request.body
			end
		end
		return nil
	end
	local function lastHeartbeat()
		local list = requests("heartbeat")
		return list[#list] and list[#list].body
	end

	-- A broken generation: the head fails to start and nothing else is known. The kernel still alerts and beats.
	check("fleet: a deploy that fails to start: alert deploy_failed (critical) with its seq and artifact", waitFor("deploy_failed", function()
		local alert = alerted("deploy_failed")
		return alert ~= nil and alert.level == "critical" and alert.s == 5 and alert.a == "iiiiiii-999999" and alert.j == JOB and alert.b == "dev" and alert.k == Constants.KERNEL_VERSION and typeof(alert.t) == "number" and #alert.message <= 300
	end, 6))
	check("fleet: nothing else could run: lkg_exhausted and health_failed (critical)", waitFor("lkg", function()
		return alerted("lkg_exhausted") ~= nil and alerted("health_failed") ~= nil and alerted("health_failed").level == "critical"
	end, 6) and status().generation == nil)
	check("fleet: heartbeats go on with no generation (h failed, no artifact, j set, no access code)", waitFor("heartbeat", function()
		local body = lastHeartbeat()
		return body ~= nil and body.h == "failed" and body.a == nil and body.j == JOB and body.k == nil and body.sv == 2 and body.t == "reserved"
	end))
	check("fleet: the failed deploy's report went out", waitFor("report", function()
		for _, request in requests("report") do
			if request.body.s == 5 and request.body.r == "failed" and request.body.j == JOB then
				return true
			end
		end
		return false
	end))
	local wellFormed = #httpRequests > 0
	for _, request in httpRequests do
		local headers = request.headers or {}
		wellFormed = wellFormed and request.method == "POST" and string.sub(request.url, 1, #PREFIX) == PREFIX and headers.Authorization == "Bearer " .. FLEET_TOKEN and headers["Content-Type"] == "application/json"
	end
	check("fleet: every request is a JSON POST to <url>/v1/fleet/... with the bearer token", wellFormed)
	check("fleet: status().fleet shows the host, never the token", (function()
		local info = status().fleet
		return info.enabled == true and info.host == "fleet.example.test" and info.settings == "ok" and not string.find(serde.encode("json", info), FLEET_TOKEN, 1, true)
	end)())

	-- It recovers: a good deploy runs, the heartbeat says ok.
	publish("TypeTorch/deploy", { b = "dev", a = 1004, i = "ddddddd-444444", s = 6, c = "ddddddd", ch = "dev", t = nowMs() })
	check("fleet: a good deploy: heartbeat ok with the artifact, report booted (the first generation here)", waitFor("recovered", function()
		local body = lastHeartbeat()
		local swapped = false
		for _, request in requests("report") do
			swapped = swapped or (request.body.s == 6 and request.body.r == "booted") -- the first generation of this server
		end
		return running() == "ddddddd-444444" and body ~= nil and body.h == "ok" and body.a == "ddddddd-444444" and body.q == 6 and swapped
	end, 6))

	-- A deploy that fails its health window: alert health_rollback, report rolled_back, back to D.
	local mark = #httpRequests
	publish("TypeTorch/deploy", { b = "dev", a = 1007, i = "ggggggg-777777", s = 7, c = "ggggggg", ch = "dev", t = nowMs() })
	check("fleet: a health-window rollback: alert health_rollback and report rolled_back", waitFor("health rollback", function()
		local rolled = false
		for _, request in requests("report", mark) do
			rolled = rolled or (request.body.s == 7 and request.body.r == "rolled_back")
		end
		local alert = alerted("health_rollback", mark)
		return alert ~= nil and alert.level == "critical" and alert.s == 7 and alert.a == "ggggggg-777777" and rolled and running() == "ddddddd-444444"
	end, 6))

	-- An error spike after the window: 20 errors from the generation within 60 s.
	task.wait(Constants.HEALTH_WINDOW + 0.3)
	mark = #httpRequests
	local entry = currentEntry()
	for index = 1, 20 do
		fireScriptError(`spike {index}`, "", entry)
	end
	check("fleet: an error spike (20 errors in 60 s): alert error_spike (warning), no rollback", waitFor("spike", function()
		local alert = alerted("error_spike", mark)
		return alert ~= nil and alert.level == "warning"
	end) and running() == "ddddddd-444444")

	-- Retries: no answer and 503 are retried; 401 is dropped (the warning names the setting, never the token).
	mark = #httpRequests
	httpScript = { "error", 503 }
	check("fleet: a request that gets no answer, then 503, is retried until it goes through", waitFor("retry", function()
		local statuses = {}
		for index = mark + 1, #httpRequests do
			table.insert(statuses, httpRequests[index].status)
		end
		return statuses[1] == 0 and statuses[2] == 503 and statuses[3] == 200 and httpRequests[mark + 1].url == httpRequests[mark + 3].url
	end, 4))
	httpScript = { 401 }
	check("fleet: 401 is dropped with a warning that names the setting (0.3.9: and holds the sender off)", waitFor("401", function()
		return said("HTTP 401") and said("settings.fleet.token") and said("refused")
	end, 4))

	-- A player count change sends a heartbeat at once (at most once per FLEET_PLAYERS_GAP).
	Constants.FLEET_HEARTBEAT_SECONDS = 100
	task.wait(0.6)
	local before = #requests("heartbeat")
	local visitor = newInstance("Player", "Visitor")
	visitor.UserId = 77
	services.Players.PlayerAdded:Fire(visitor)
	check("fleet: a player count change sends a heartbeat", waitFor("players", function()
		return #requests("heartbeat") == before + 1
	end, 2))

	-- Without the setting nothing is sent; it comes back after a write. 0.3.8: a new signed record without `fleet`, a ping.
	dataStore.data.settings = deepCopy(SMOKE.settings.fleetOff)
	publish("TypeTorch/deploy", { k = "settings", s = 2 })
	task.wait(0.8)
	local quiet = #httpRequests
	publish("TypeTorch/deploy", { b = "dev", a = 1002, i = "bbbbbbb-222222", s = 8, c = "bbbbbbb", ch = "dev", t = nowMs() })
	task.wait(0.8)
	check("fleet: without settings.fleet nothing is sent (the swap still happens)", #httpRequests == quiet and running() == "bbbbbbb-222222" and status().fleet.enabled == false)
	dataStore.data.settings = deepCopy(SMOKE.settings.fleetOn)
	publish("TypeTorch/deploy", { k = "settings", s = 3 })
	check("fleet: the setting is back after a write and a ping: sending resumes", waitFor("resumed", function()
		return #httpRequests > quiet and status().fleet.enabled == true
	end, 3))

	-- BindToClose: the closing request (a clean close, not a lost server).
	local closeDone = false
	task.spawn(function()
		closeCallbacks[1]()
		closeDone = true
	end)
	check("fleet: BindToClose sends closing", waitFor("closing", function()
		local list = requests("closing")
		return closeDone and #list == 1 and list[1].body.closing == true and list[1].body.j == JOB and list[1].body.k == nil
	end))
	finish()
end

if HEALTH_MODE then
	local owner = newInstance("Player", "Owner")
	owner.UserId = 1
	local function devDeploy(assetId: number, artifactId: string, seq: number)
		publish("TypeTorch/deploy", { b = "dev", a = assetId, i = artifactId, s = seq, c = string.sub(artifactId, 1, 7), ch = "dev", t = nowMs() })
	end
	check("health: boots the dev head (the stored-branch read failed twice and was retried)", waitFor("boot", function()
		return running() == "ddddddd-444444"
	end) and status().branch == "dev" and status().signedOnly == false)
	check("P-K8: the deploy subscription failed twice and was retried", waitFor("subscribe", function()
		return said("deploy messages: subscribed after 2 failed attempts")
	end))

	-- P-O1: deploy reports and the fleet status on the API (the kernel writes nothing).
	check("P-O1: a booted report for seq 5", waitFor("booted report", function()
		return reported(5, "booted")
	end))
	local booted = reportOf(5)
	check(
		"P-O1: report fields {s,b,a,j,r,d,t,g,k,p}",
		booted ~= nil and booted.s == 5 and booted.b == "dev" and booted.a == "ddddddd-444444" and booted.j == JOB and typeof(booted.t) == "number" and booted.g == 1 and booted.k == Constants.KERNEL_VERSION and booted.p == 0 and typeof(booted.d) == "number" and booted.e == nil
	)
	check("P-O1: the boot generation's listener got its own boot report (replayed)", waitFor("replay", function()
		return heard("ddddddd-444444#1", 5, "booted")
	end))
	local hb = fleet()
	check(
		"P-O1: fleetStatus {t,b,c,a,n,m,s,u,p,k,v} plus q, g, h, sv = 2",
		hb ~= nil and hb.t == "reserved" and hb.b == "dev" and hb.c == status().channel and hb.c ~= nil and hb.a == "ddddddd-444444" and hb.n == 0 and hb.m == 10 and typeof(hb.s) == "number" and typeof(hb.u) == "number" and hb.p == 42 and hb.k == "smoke-access-code" and hb.x == nil and hb.v == Constants.KERNEL_VERSION and hb.q == 5 and hb.g == 1 and hb.h == "ok" and hb.sv == 2
	)
	check("api: accessCode() (from the private record)", SMOKE.kernel:accessCode() == "smoke-access-code")

	-- S-M2: the settings never loaded (every read fails here), so revocations are unknown.
	local stranger = newInstance("Player", "Stranger")
	stranger.UserId = 99
	local info = SMOKE.kernel:devInfo(stranger)
	check("S-M2: no badge or member access while revocations are unknown (the owner still is a dev)", info.dev == false and info.reason == "registry-unknown" and SMOKE.kernel:devInfo(owner).dev == true)

	-- Busy-flag hazard: B's own thread calls kernel:reload once. The swap stops B (its threads die), so it must run on
	-- a kernel thread: no hazard, the caller never returns, and the next deploy still swaps (busy was cleared).
	SMOKE.behave["bbbbbbb-222222"] = function(kernel)
		if SMOKE.reloadFromGeneration then
			SMOKE.reloadFromGeneration = false
			SMOKE.task.delay(0.1, function()
				SMOKE.reloadReport = kernel:reload(owner)
				SMOKE.reloadReturned = true
			end)
		end
	end
	SMOKE.reloadFromGeneration = true
	devDeploy(1002, "bbbbbbb-222222", 20)
	check("deploy B swaps and reports swapped", waitFor("B", function()
		return running() == "bbbbbbb-222222" and status().appliedSeq == 20 and reported(20, "swapped")
	end))
	check("P-O1: the new generation hears the replay and the live report; the stopped one was dropped", waitFor("listeners", function()
		return heard("bbbbbbb-222222#2", 5, "booted") and heard("bbbbbbb-222222#2", 20, "swapped")
	end) and not heard("ddddddd-444444#1", 20, "swapped"))
	local generationBefore = status().generation.number
	check("busy flag: a reload from the generation's own thread finishes on a kernel thread", waitFor("reload", function()
		return status().generation.number > generationBefore and running() == "bbbbbbb-222222"
	end) and #hazards == 0)
	task.wait(0.2)
	check("busy flag: the calling thread died with its generation (it never got the report)", SMOKE.reloadReturned ~= true)

	-- P-F1: G's own scripts raise 3 errors right after ready (two from its threads, one from a ModuleScript in its tree).
	devDeploy(1007, "ggggggg-777777", 21)
	check("P-F1: 3 errors within the window roll the server back to the last known good (B)", waitFor("G rollback", function()
		return rolledBackFrom("ggggggg-777777", "bbbbbbb-222222")
	end, 6))
	local failed = status().failed
	check("P-F1: G is marked failed here; report rolled_back; event health_rollback", failed[1] ~= nil and failed[1].assetId == 1007 and reported(21, "rolled_back") and string.find(reportOf(21).e or "", "errors", 1, true) ~= nil and hasEvent("health_rollback", "assetId", 1007))
	check("P-O1: the fleet status says degraded after the rollback", waitFor("degraded", function()
		local entry = fleet()
		return entry.h == "degraded" and entry.a == "bbbbbbb-222222" and entry.e ~= nil
	end))

	-- Errors from outside the generation never count.
	local placeScript = newInstance("Script", "PlaceScript")
	placeScript.Parent = services.ServerScriptService
	for _ = 1, 4 do
		fireScriptError("place script boom", "", placeScript)
	end
	fireScriptError("kernel boom", "", kernelFolder.Kernel)
	fireScriptError("no script boom", "", nil)
	task.wait(0.3)
	check("P-F1: errors from outside the generation never count", running() == "bbbbbbb-222222" and status().health.errors == 0 and status().health.lastRollback.from == "ggggggg-777777")

	-- P-K3: an artifact that failed here isn't run again automatically.
	devDeploy(1007, "ggggggg-777777", 22)
	check("P-K3: a redeploy of an artifact that failed here is skipped", waitFor("skipped", function()
		return reported(22, "skipped")
	end) and running() == "bbbbbbb-222222" and assets[1007].loads == 1)

	-- P-F1: H's onStart fails (the framework reports it through kernel:reportError).
	devDeploy(1008, "hhhhhhh-888888", 23)
	check("P-F1: a failed onStart rolls back", waitFor("H rollback", function()
		return rolledBackFrom("hhhhhhh-888888", "bbbbbbb-222222")
	end, 6) and reported(23, "rolled_back"))
	check("P-F1: the kernel printed the reported failure as an error line", said("[TypeTorch] ShopService.onStart failed: attempt to index nil"))

	-- P-K3: I fails to start; the last known good skips G and H (failed here) and runs B.
	devDeploy(1009, "iiiiiii-999999", 24)
	check("P-K3: a generation that fails to start: report failed, back to B, G and H never loaded again", waitFor("I failed", function()
		return reported(24, "failed") and running() == "bbbbbbb-222222"
	end, 6) and assets[1007].loads == 1 and assets[1008].loads == 1 and #status().failed == 3)

	-- After the window, errors are counted (degraded) but never roll back.
	task.wait(Constants.HEALTH_WINDOW + 0.3)
	local entry = currentEntry()
	for index = 1, 3 do
		fireScriptError(`late boom {index}`, "", entry)
	end
	task.wait(0.3)
	check("P-F1: after the window errors are counted, never rolled back", running() == "bbbbbbb-222222" and status().health.errors == 3 and status().health.state == "degraded")

	-- P-O1: a good deploy brings the fleet status back to ok; a disconnected listener hears nothing more.
	devDeploy(1004, "ddddddd-444444", 25)
	check("P-O1: a good deploy: swapped report, fleet status ok again", waitFor("D", function()
		local now = fleet()
		return running() == "ddddddd-444444" and reported(25, "swapped") and now.h == "ok" and now.q == 25 and now.a == "ddddddd-444444"
	end))
	local name = status().generation.name
	waitFor("D listener", function()
		return heard(name, 25, "swapped")
	end)
	local heardBefore = #SMOKE.heard[name]
	SMOKE.disconnects[name]()
	devDeploy(1004, "ddddddd-444444", 26) -- already running: a "swapped" report without a swap
	check("P-O1: a disconnected listener hears nothing more", waitFor("26", function()
		return reported(26, "swapped")
	end) and #SMOKE.heard[name] == heardBefore and status().generation.name == name)
	check("P-O1: the kernel keeps the last 20 reports", #SMOKE.kernel:deployReports() <= 20 and status().reports.total >= 10)

	-- P-K7: client generation reports (kernel channel "*" / __tt/client), checked field by field.
	local client = newInstance("Player", "Client1")
	client.UserId = 5
	local net = services.ReplicatedStorage.TypeTorch.Net
	net.OnServerEvent:Fire(client, "*", "__tt/client", { g = string.rep("x", 200), ok = true })
	net.OnServerEvent:Fire(client, "*", "__tt/client", { g = status().generation.name, ok = false, e = "client boom", ms = 12, retried = true })
	check("P-K7: a client's failed generation start is recorded", waitFor("client", function()
		local clients = status().clients
		return clients.reported == 1 and clients.failed == 1 and clients.lastFailure ~= nil and clients.lastFailure.error == "client boom"
	end))
	net.OnServerEvent:Fire(client, "*", "__tt/client", { g = status().generation.name, ok = true, ms = 30 })
	check("P-K7: then ok", waitFor("client ok", function()
		local clients = status().clients
		return clients.ok == 1 and clients.failed == 0 and clients.behind == 0
	end))

	-- onClose: the running generation's handler runs from BindToClose; the heartbeat entry goes; no swaps after.
	local closeDone = false
	task.spawn(function()
		closeCallbacks[1]()
		closeDone = true
	end)
	check("onClose: the generation's handler runs", waitFor("close", function()
		return closeDone
	end) and table.find(SMOKE.closed, "ddddddd-444444") ~= nil)
	devDeploy(1002, "bbbbbbb-222222", 27)
	task.wait(0.4)
	check("onClose: no swaps after BindToClose", running() == "ddddddd-444444")
	finish()
end

if HEALTH_PROD_MODE then
	-- The same failures on a signed public server: every last-known-good target is admitted (no refused swap).
	check("health-prod: boots A (signed)", waitFor("boot", function()
		return running() == "aaaaaaa-111111"
	end))
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("health-prod: signed deploy B", waitFor("B", function()
		return running() == "bbbbbbb-222222" and reported(11, "swapped")
	end))
	publish("TypeTorch/deploy", deployMessage("Q1", FIELDS.Q1, { "sig" }))
	check("health-prod: G errors: rolled back to B (this server's history)", waitFor("G rollback", function()
		return rolledBackFrom("ggggggg-777777", "bbbbbbb-222222") and reported(30, "rolled_back")
	end, 6))
	publish("TypeTorch/deploy", deployMessage("Q4", FIELDS.Q4, { "sig" }))
	check("health-prod: a signed redeploy of G is skipped", waitFor("skipped", function()
		return reported(33, "skipped")
	end) and running() == "bbbbbbb-222222")
	publish("TypeTorch/deploy", deployMessage("Q2", FIELDS.Q2, { "sig" }))
	check("health-prod: H's onStart fails: rolled back to B", waitFor("H rollback", function()
		return rolledBackFrom("hhhhhhh-888888", "bbbbbbb-222222") and reported(31, "rolled_back")
	end, 6))
	publish("TypeTorch/deploy", deployMessage("Q3", FIELDS.Q3, { "sig" }))
	check("health-prod: I fails to start: report failed, back to B", waitFor("I failed", function()
		return reported(32, "failed") and running() == "bbbbbbb-222222"
	end, 6))
	publish("TypeTorch/deploy", deployMessage("Q5", FIELDS.Q5, { "sig" }))
	check("health-prod: a good signed deploy swaps; health ok", waitFor("D", function()
		return running() == "ddddddd-444444" and reported(34, "swapped") and status().health.state == "ok"
	end))
	check("health-prod: every restore passed the prod gate (no refused swap)", rejected("swap") == 0)
	finish()
end

if LKG_BOOT_MODE then
	check("lkg-boot: the signed head (I) fails to start; the signed deployment history boots A", waitFor("boot A", function()
		return SMOKE.kernel ~= nil and running() == "aaaaaaa-111111"
	end, 8))
	check("lkg-boot: the UNSIGNED history entry (B) is never a target on a prod server", (assets[1002].loads or 0) == 0 and rejected("swap") == 0)
	check("lkg-boot: I failed here; reports failed #32 and booted #10; appliedSeq 10", status().failed[1] ~= nil and status().failed[1].assetId == 1009 and waitFor("reports", function()
		return reported(32, "failed") and reported(10, "booted")
	end) and status().appliedSeq == 10)
	task.wait(1) -- several polls meet the failed head (seq 32)
	check("lkg-boot: the poll leaves the failed head alone", running() == "aaaaaaa-111111" and assets[1009].loads == 1)
	publish("TypeTorch/deploy", deployMessage("Q1", FIELDS.Q1, { "sig" }))
	check("lkg-boot: a later deploy that fails its health window goes back to A", waitFor("G rollback", function()
		return rolledBackFrom("ggggggg-777777", "aaaaaaa-111111") and reported(30, "rolled_back")
	end, 6))
	finish()
end

if HEALTH_CONFIG_MODE then
	-- 0.3.7 (plans/17 blocker 5): the health window's thresholds come from each build (payload root attributes).
	local function devDeploy(assetId: number, artifactId: string, seq: number)
		publish("TypeTorch/deploy", { b = "dev", a = assetId, i = artifactId, s = seq, c = string.sub(artifactId, 1, 7), ch = "dev", t = nowMs() })
	end
	local function fire(count: number, label: string)
		local entry = currentEntry()
		for index = 1, count do
			fireScriptError(`{label} {index}`, "", entry)
		end
	end
	check("health-config: boots the dev head", waitFor("boot", function()
		return running() == "ddddddd-444444"
	end))
	local h = status().health
	check("health-config: a build without the attributes uses the defaults (3 errors, the default window, rollback on)", h.limit == 3 and h.window == Constants.HEALTH_WINDOW and h.rollback == true and h.source == "default" and h.invalid == nil)
	devDeploy(1002, "bbbbbbb-222222", 20)
	check("health-config: deploy B (the last known good below)", waitFor("B", function()
		return running() == "bbbbbbb-222222" and reported(20, "swapped")
	end))

	-- J: 5 errors within 3 s. Errors past the DEFAULT window (1.5 s) still count, and 4 don't roll it back.
	devDeploy(1010, "jjjjjjj-aaaaaa", 21)
	check("health-config: J runs with its own thresholds (5 errors, 3 s, from the payload)", waitFor("J", function()
		return running() == "jjjjjjj-aaaaaa"
	end) and (function()
		local health = status().health
		return health.limit == 5 and health.window == 3 and health.rollback == true and health.source == "payload" and health.invalid == nil and (health.windowLeft or 0) >= 2
	end)())
	task.wait(Constants.HEALTH_WINDOW + 0.3) -- past the default window, inside J's own
	fire(4, "J noise")
	task.wait(0.3)
	h = status().health
	check("health-config: 4 errors after the default window: counted, below J's limit, no rollback", running() == "jjjjjjj-aaaaaa" and h.errors == 4 and h.state == "ok" and h.windowLeft ~= nil)
	fire(1, "J fifth")
	check("health-config: the 5th error inside J's window rolls it back to B", waitFor("J rollback", function()
		return rolledBackFrom("jjjjjjj-aaaaaa", "bbbbbbb-222222") and reported(21, "rolled_back")
	end, 4) and string.find(reportOf(21).e or "", "5 errors within 3 s", 1, true) ~= nil)

	-- K: every value is bad (out of bounds or the wrong type): the defaults apply, listed in status and warned.
	devDeploy(1011, "kkkkkkk-bbbbbb", 22)
	check("health-config: K's bad values fall back to the defaults, listed in status().health.invalid", waitFor("K", function()
		return running() == "kkkkkkk-bbbbbb"
	end) and (function()
		local health = status().health
		return health.limit == 3 and health.window == Constants.HEALTH_WINDOW and health.rollback == true and health.source == "default" and health.invalid ~= nil and #health.invalid == 3
	end)() and said("health settings out of bounds, defaults used for: HealthErrors 500"))
	fire(3, "K boom")
	check("health-config: 3 errors (the default limit) roll K back", waitFor("K rollback", function()
		return rolledBackFrom("kkkkkkk-bbbbbb", "bbbbbbb-222222") and reported(22, "rolled_back")
	end, 4))

	-- L: HealthRollback = false. A failed onStart and 3 errors in the window: it keeps running, degraded, warned once.
	devDeploy(1012, "lllllll-cccccc", 23)
	check("health-config: L (rollback off) keeps running after a failed onStart", waitFor("L", function()
		return running() == "lllllll-cccccc" and reported(23, "swapped")
	end) and (function()
		local health = status().health
		return health.rollback == false and health.source == "payload" and health.startFailed ~= nil and health.kept ~= nil and health.state == "degraded"
	end)())
	fire(3, "L boom")
	task.wait(0.5)
	h = status().health
	check("health-config: L's errors past the limit don't roll it back either (degraded, no rolled_back report)", running() == "lllllll-cccccc" and h.errors == 3 and h.state == "degraded" and fleet().h == "degraded" and not reported(23, "rolled_back") and h.lastRollback.from == "kkkkkkk-bbbbbb")
	check("health-config: the kernel warned once that L's build turns the rollback off", said("turns the health rollback off"))

	-- A build without the attributes is back on the defaults.
	devDeploy(1004, "ddddddd-444444", 24)
	check("health-config: the next build uses the defaults again", waitFor("D", function()
		local health = status().health
		return running() == "ddddddd-444444" and health.limit == 3 and health.rollback == true and health.source == "default" and health.state == "ok"
	end))
	finish()
end

if HEALTH_MISSING_MODE then
	-- A place project without TypeTorchKernel.Health (an older template studio.project.json): it boots, says so, and
	-- counts nothing (no window, no rollback).
	check("health-missing: boots without the Health module and says so", waitFor("boot", function()
		return running() ~= nil
	end) and said("TypeTorchKernel.Health is missing"))
	local first = running()
	local entry = currentEntry()
	for index = 1, 5 do
		fireScriptError(`missing {index}`, "", entry)
	end
	task.wait(0.5)
	local h = status().health
	check("health-missing: status().health says missing; errors never roll back", h.missing == true and h.state == "ok" and fleet().h == "ok" and running() == first and SMOKE.kernel:reportError({ kind = "onStart", module = "X", message = "y" }) == false)
	finish()
end

-- 0.3.6 NEVER AN EMPTY SERVER: the modes ------------------------------------------------------------------------------
local function alertsOf(code: string): { any }
	local list = {}
	for _, request in httpRequests do
		if request.body and request.body.code == code and string.find(request.url, "/v1/fleet/alert", 1, true) then
			table.insert(list, request.body)
		end
	end
	return list
end
local function sinceKernel(): number
	return os.clock() - kernelStartClock
end
local function holdAttribute()
	return clientStandIn:GetAttribute("Hold"), services.ReplicatedStorage.TypeTorch:GetAttribute("Hold")
end
local function teleportsOf(name: string): { any }
	local list = {}
	for _, entry in teleports do
		if table.find(entry.players, name) then
			table.insert(list, entry)
		end
	end
	return list
end
local function bounceData(entry): any
	local data = entry.options.TeleportData
	return data and data.TypeTorch
end

if HOLD_MODE or HOLD_OPTOUT_MODE then
	local optOut = HOLD_OPTOUT_MODE
	-- The hold is the kernel's first statement: before the boot reads, before any player can join.
	check(`hold: {if optOut then "opt-out: CharacterAutoLoads untouched" else "CharacterAutoLoads off from the kernel's first line"}, the client's Hold attribute "start"`, waitFor("hold", function()
		local first, root = holdAttribute()
		return first == "start" and root == "start" and services.Players.CharacterAutoLoads == optOut
	end, 1))
	-- A player joins while the boot is still loading (LoadAsset takes 0.6 s here).
	task.wait(0.1)
	local early = joinPlayer(11, "Early")
	task.wait(0.1)
	check("hold: a player who joins during the boot has no character yet", SMOKE.kernel == nil and early.Character == nil and #loadedCharacters == 0)
	check("hold: the first generation runs", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() == "aaaaaaa-111111"
	end))
	local hold = status().fallback.hold
	-- 0.3.8: the game's loading screen settings reached the kernel client script with the hold (before any join).
	if optOut then
		check("hold-optout: the kernel folder's BootScreen / KernelScreen (kernel deploy) win over ReplicatedFirst's", clientStandIn:GetAttribute("BootScreen") == "FromConfig" and clientStandIn:GetAttribute("KernelScreen") == nil and hold.bootScreen == "FromConfig" and hold.kernelScreen == nil)
	else
		check("hold: ReplicatedFirst's TypeTorchBootScreen / TypeTorchKernelScreen are on the kernel client script (BootScreen, KernelScreen = false)", clientStandIn:GetAttribute("BootScreen") == "Loading" and clientStandIn:GetAttribute("KernelScreen") == false and hold.bootScreen == "Loading" and hold.kernelScreen == false)
	end
	if optOut then
		check("hold-optout: the kernel never touched characters (no LoadCharacter), the screen hold ended", services.Players.CharacterAutoLoads == true and #loadedCharacters == 0 and hold.optOut == true and holdAttribute() == nil)
	else
		check(string.format("hold: released when the generation was ready: CharacterAutoLoads back on, the waiting player spawned, Hold cleared (held %d ms after the kernel start)", hold.heldMs or -1), waitFor("release", function()
			local first, root = holdAttribute()
			return services.Players.CharacterAutoLoads == true and table.find(loadedCharacters, "Early") ~= nil and first == nil and root == nil
		end) and hold.heldMs ~= nil and hold.heldMs < 50 and hold.active == false and hold.spawned == 1)
	end
	if not optOut then
		-- 0.3.9: one line per hold change with its reason, in the server's log ring (the dev menu's Logs, Logs > Upload).
		check("0.3.9 hold: 'hold start' (with its reason) and 'hold released: generation ... running' are in the kernel's log ring", waitFor("ring", function()
			return SMOKE.ringHas(SMOKE.kernel, "[TypeTorch] hold start: boot: no generation runs yet")
				and SMOKE.ringHas(SMOKE.kernel, "[TypeTorch] hold released: generation aaaaaaa-111111#1 running")
		end) and status().fallback.hold.lastReleased == "generation aaaaaaa-111111#1 running" and services.ReplicatedStorage.TypeTorch:GetAttribute("HoldReason") == nil)
	end
	-- A swap of the running generation never holds anybody.
	SMOKE.behave["bbbbbbb-222222"] = function()
		local first = holdAttribute()
		SMOKE.midSwap = { autoLoads = services.Players.CharacterAutoLoads, hold = first }
	end
	local spawnedBefore = #loadedCharacters
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("hold: a swap of a running generation doesn't hold (CharacterAutoLoads stays on, no Hold, nobody respawned)", waitFor("swap", function()
		return running() == "bbbbbbb-222222"
	end) and SMOKE.midSwap ~= nil and SMOKE.midSwap.autoLoads == true and SMOKE.midSwap.hold == nil and holdAttribute() == nil and #loadedCharacters == spawnedBefore)
	local late = joinPlayer(12, "Late")
	task.wait(0.2)
	check("hold: a player who joins while a generation runs isn't held (Roblox spawns them as usual)", services.Players.CharacterAutoLoads == true and late.Character == nil and #loadedCharacters == spawnedBefore)
	if not optOut then
		-- 0.3.9 safety net: a "start" hold while a generation runs (a bookkeeping bug, forced here) is released by the
		-- watchdog after HOLD_STUCK_RELEASE s, warned.
		requireInstance(kernelFolder.Fallback).lost("smoke: a forced bookkeeping bug")
		check("0.3.9 hold: a forced 'start' hold while B runs is marked with its reason", select(2, holdAttribute()) == "start" and services.ReplicatedStorage.TypeTorch:GetAttribute("HoldReason") == "a failed swap: smoke: a forced bookkeeping bug")
		local forcedAt = os.clock()
		check("0.3.9 hold: the watchdog releases it after about 3 s, warned (a kernel bookkeeping bug)", waitFor("watchdog release", function()
			local first, root = holdAttribute()
			return first == nil and root == nil
		end, 6) and os.clock() - forcedAt >= 2.5 and said("released by the watchdog (a kernel bookkeeping bug") and status().fallback.hold.stuckReleases == 1 and services.Players.CharacterAutoLoads == true)
	end
	finish()
end

if PEERS_MODE then
	check("peers: no head anywhere: the kernel roll call boots the build most healthy servers of the branch run (B, 3 servers)", waitFor("peer boot", function()
		return SMOKE.kernel ~= nil and running() == "bbbbbbb-222222"
	end, 15))
	local s0 = status()
	local seconds = sinceKernel()
	check(string.format("peers: within the boot budget (%.1f s after the kernel start), verified by its signature, appliedSeq 11", seconds), seconds < 15 and s0.generation.artifact.verified ~= nil and s0.appliedSeq == 11 and s0.fallback.chain.result == "peers")
	local chosen = s0.fallback.peers.chosen
	check("peers: young, unhealthy and other-branch servers aren't counted; D (1 server) lost to B (3)", chosen ~= nil and chosen.servers == 3 and chosen.assetId == 1002 and (assets[1004].loads or 0) == 0 and (assets[1007].loads or 0) == 0)
	local ask = nil
	for _, entry in published do
		if entry.topic == "TypeTorch/deploy" and type(entry.data) == "table" and entry.data.rc == 1 then
			ask = entry
		end
	end
	check("peers: the ask rides TypeTorch/deploy ({rc = 1, q, j, b, t}); no new permanent subscription", ask ~= nil and ask.data.j == JOB and ask.data.b == "prod" and type(ask.data.q) == "number" and type(ask.data.t) == "number")
	check(`peers: at most 5 MessagingService subscriptions during the ask (Roblox allows 20 + 8 x players): {ask and ask.topics or "?"}`, ask ~= nil and ask.topics <= 5)
	check("peers: the reply subscription is gone after the ask; the ask isn't a deploy message", topics[`TypeTorch/peers/{JOB}`] == nil and s0.lastMessage == nil)
	-- This kernel answers other kernels' asks once its generation ran healthy for PEER_MIN_UPTIME.
	Constants.PEER_MIN_UPTIME = 1
	task.wait(2.1)
	local function repliesTo(job: string): { any }
		local list = {}
		for _, entry in published do
			if entry.topic == `TypeTorch/peers/{job}` then
				table.insert(list, entry.data)
			end
		end
		return list
	end
	publish("TypeTorch/deploy", { rc = 1, q = 7, j = "other-job-1", b = "prod", t = nowMs() })
	publish("TypeTorch/deploy", { rc = 1, q = 8, j = "other-job-2", b = "dev", t = nowMs() })
	publish("TypeTorch/deploy", { rc = 1, q = 9, j = "other-job-3", b = "prod", t = nowMs() - 120000 })
	check("peers: answers an ask of its branch: its build with the signatures, server type, players, health, uptime", waitFor("reply", function()
		local reply = repliesTo("other-job-1")[1]
		return reply ~= nil and reply.q == 7 and reply.j == JOB and reply.a == 1002 and reply.i == "bbbbbbb-222222" and reply.s == 11 and reply.sig ~= nil and reply.st == "public" and reply.h == "ok" and reply.u >= 1 and reply.k == nil
	end, 2))
	publish("TypeTorch/deploy", { rc = 1, q = 10, j = "other-job-1", b = "prod", t = nowMs() })
	task.wait(0.8)
	check("peers: no reply to another branch, a stale ask, or the same asker within 5 s", #repliesTo("other-job-2") == 0 and #repliesTo("other-job-3") == 0 and #repliesTo("other-job-1") == 1)
	finish()
end

if PEERS_UNTRUSTED_MODE then
	check("peers-untrusted: the unsigned build (3 servers) and the forged signature (2) are refused; D runs (its deployment entry verifies)", waitFor("D", function()
		return SMOKE.kernel ~= nil and running() == "ddddddd-444444"
	end, 15))
	check("peers-untrusted: the refused builds were never loaded; refusals counted", (assets[1003].loads or 0) == 0 and (assets[1002].loads or 0) == 0 and rejected("peer") >= 2)
	check("peers-untrusted: D is verified (the signed deployment entry), not unverified", status().generation.artifact.verified ~= nil and status().unverified == nil and status().appliedSeq == 34)
	finish()
end

if BACKUP_MODE or RECOVER_MODE then
	local player1 = joinPlayer(21, "Player1")
	check("backup: an asset outage (every LoadAsset fails): the backup baked into the place runs", waitFor("backup", function()
		return SMOKE.kernel ~= nil and running() == "bbbbbbb-222222" and status().backup == true
	end, 15))
	local seconds = sinceKernel()
	local s0 = status()
	check(string.format("backup: within the boot budget (%.1f s after the kernel start); hold released, the waiting player spawned", seconds), seconds < 15 and holdAttribute() == nil and services.Players.CharacterAutoLoads == true and table.find(loadedCharacters, "Player1") ~= nil)
	check("backup: flagged (status backup, fallback.backup {runs, at, seq}), no verified badge, appliedSeq untouched", s0.fallback.backup.runs == 1 and s0.fallback.backup.at == "2026-10-06T10:00:00Z" and s0.fallback.backup.seq == 11 and s0.generation.artifact.verified == nil and s0.appliedSeq == -1 and s0.fallback.chain.result == "backup")
	check("backup: mounted as a fresh clone with the payload checks (prod channel, modules only); the source stays", services.ServerStorage:FindFirstChild("TypeTorchBackup") ~= nil and s0.generation.artifact.channel == "prod" and s0.generation.artifact.assetId == nil)
	if BACKUP_MODE then
		check("backup: fleet status backup = true, h = backup; alert backup_build (critical), no health_backup alert", waitFor("alert", function()
			local alert = alertsOf("backup_build")[1]
			return alert ~= nil and alert.level == "critical" and fleet().backup == true and fleet().h == "backup"
		end, 3) and #alertsOf("health_backup") == 0 and hasEvent("backup_build", "artifactId", "bbbbbbb-222222"))
		local commandSignal = services.TextChatService.TypeTorchCommand.Triggered
		local owner = joinPlayer(1, "Owner")
		commandSignal:Fire({ UserId = 1 }, "/tt status")
		check("backup: /tt status says BACKUP", waitFor("tt status", function()
			for _, call in firedToClient do
				if call[1] == owner and call[3] == "__tt/notice" and string.find(tostring(call[4]), "BACKUP build", 1, true) then
					return true
				end
			end
			return false
		end))
		task.wait(1.5)
		check("backup: the outage goes on: the backup keeps running while the recovery retries in the background", running() == "bbbbbbb-222222" and status().fallback.recovery.running == true and status().fallback.recovery.attempts >= 1)
		finish()
	end
	-- RECOVER: the outage ends; the next background retry swaps to the head (A) as a normal swap.
	local generationBefore = status().generation.number
	assets[1001].failLoads = 0
	check("recover: the outage ends: the background retry swaps to the real head (A)", waitFor("recovered", function()
		return running() == "aaaaaaa-111111"
	end, 5))
	local s1 = status()
	check("recover: a normal swap (players stay: no kick, no teleport; the backup stopped; the head verified, appliedSeq 10)", s1.backup == nil and s1.generation.number > generationBefore and #kicked == 0 and #teleports == 0 and table.find(SMOKE.stops, "bbbbbbb-222222") ~= nil and s1.generation.artifact.verified ~= nil and s1.appliedSeq == 10 and player1.Parent ~= nil)
	check("recover: a deploy report swapped #10", waitFor("report", function()
		return reported(10, "swapped")
	end))
	task.wait(2.5)
	local attempts = status().fallback.recovery.attempts
	task.wait(1.5)
	check("recover: the retries stop once the head runs", status().fallback.recovery.running == false and status().fallback.recovery.attempts == attempts and running() == "aaaaaaa-111111")
	finish()
end

if TELEPORT_MODE then
	local p1 = joinPlayer(31, "P1")
	local p2 = joinPlayer(32, "P2", 1)
	teleportFails = 1 -- the first TeleportAsync throws
	check("teleport: the backup holds a Script: refused at mount like any payload", waitFor("backup refused", function()
		return said("the backup build failed (mount)")
	end, 6))
	task.wait(0.5)
	check("teleport: before the boot budget nobody moves; players are held", #teleports == 0 and holdAttribute() == "start" and services.Players.CharacterAutoLoads == false and p1.Character == nil)
	check("teleport: at the boot budget nothing runs: players are moved, by bounce count (P1 -> bounce 1, P2 -> bounce 2)", waitFor("moves", function()
		local one, two = teleportsOf("P1"), teleportsOf("P2")
		return #one >= 1 and #two >= 1 and bounceData(one[#one]).bounce == 1 and bounceData(two[#two]).bounce == 2
	end, 8))
	local first = teleportsOf("P1")[1]
	check(string.format("teleport: a public server's fresh server is matchmaking (no ServerInstanceId, no reserved code); data carries the source JobId (%.1f s after the kernel start)", first.at - kernelStartClock), first.options.ServerInstanceId == nil and first.options.ReservedServerAccessCode == nil and bounceData(first).from == JOB and first.placeId == 42 and first.at - kernelStartClock >= Constants.BOOT_BUDGET)
	check("teleport: the screen says Reconnecting (Hold move), new joiners are held too", holdAttribute() == "move" and services.Players.CharacterAutoLoads == false)
	check("teleport: alert boot_failed_teleport (critical) and an event", waitFor("alert", function()
		local alert = alertsOf("boot_failed_teleport")[1]
		return alert ~= nil and alert.level == "critical"
	end) and hasEvent("boot_failed_teleport"))
	check("teleport: a failed TeleportAsync is warned and retried", said("TeleportAsync failed (smoke)") and waitFor("retry", function()
		return #teleportsOf("P1") + #teleportsOf("P2") >= 3
	end, 3))
	local p3 = joinPlayer(33, "P3")
	check("teleport: a new joiner is moved at once", waitFor("P3", function()
		return #teleportsOf("P3") >= 1
	end, 2) and p3.Character == nil)
	-- A healthy server of the branch answers now: the next joiner goes there.
	peerReplies = { peerReply("peer-ok-1", "M2") }
	task.wait(Constants.PEER_CACHE + 0.1)
	local p4 = joinPlayer(34, "P4")
	check("teleport: with a healthy server of the branch (the roll call), players go there (ServerInstanceId)", waitFor("P4", function()
		local list = teleportsOf("P4")
		return #list >= 1 and list[1].options.ServerInstanceId == "peer-ok-1"
	end, 3) and p4.Parent ~= nil)
	-- Players still here after their tries are kicked with the message (logged and alerted).
	check("teleport: a player still here after 3 teleports is kicked with the restart message (event + alert bounce_kick)", waitFor("kick", function()
		return table.find(kicked, "P1") ~= nil
	end, 8) and kickMessages.P1 == "Servers are restarting. Please rejoin in a minute." and #teleportsOf("P1") == 3 and hasEvent("bounce_kick", "userId", 31) and waitFor("kick alert", function()
		return #alertsOf("bounce_kick") >= 1 and alertsOf("bounce_kick")[1].level == "critical"
	end))
	check("teleport: nothing ever ran here (no generation, no character)", SMOKE.kernel == nil and p1.Character == nil and #loadedCharacters == 0)
	finish()
end

if BOUNCE_MODE then
	local p1 = joinPlayer(41, "Bounced3", 3)
	local p2 = joinPlayer(42, "Bounced1", 1)
	check("bounce: a player who arrives with 3 bounces is kicked with the restart message, never teleported (event + alert)", waitFor("kick", function()
		return table.find(kicked, "Bounced3") ~= nil
	end, 8) and kickMessages.Bounced3 == "Servers are restarting. Please rejoin in a minute." and #teleportsOf("Bounced3") == 0 and hasEvent("bounce_kick", "bounce", 3) and waitFor("kick alert", function()
		return #alertsOf("bounce_kick") >= 1
	end))
	check("bounce: a reserved server's players go to a NEW reserved server on the same branch (bounce 2)", waitFor("reserved", function()
		local list = teleportsOf("Bounced1")
		return #list >= 1 and list[1].options.ReservedServerAccessCode == "code-1" and bounceData(list[1]).bounce == 2
	end, 4))
	check("bounce: the new reserved server's record says branch dev (it boots the same branch)", (function()
		local record = dataStore.data["private/ps-new-1"]
		return record ~= nil and record.branch == "dev" and record.code == "code-1"
	end)())
	-- A healthy reserved server of the branch answers with its access code: the next joiner goes there.
	peerReplies = { peerReply("peer-res-1", "M2", { b = "dev", st = "reserved", k = "peer-code", ch = "dev" }) }
	task.wait(Constants.PEER_CACHE + 0.1)
	joinPlayer(43, "Joiner")
	check("bounce: with a healthy reserved server of the branch, players go there (its access code)", waitFor("peer", function()
		local list = teleportsOf("Joiner")
		return #list >= 1 and list[1].options.ReservedServerAccessCode == "peer-code"
	end, 3))
	check("bounce: the kicked player isn't moved again", p1 and #teleportsOf("Bounced3") == 0 and p2 ~= nil)
	finish()
end

if MIDSWAP_MODE then
	check("mid-swap: boots A", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() == "aaaaaaa-111111"
	end))
	local p1 = joinPlayer(51, "InGame")
	p1.Character = newInstance("Model", "InGame")
	-- The next deploy (I) fails to start after A stopped, and A fails too now: nothing runs.
	SMOKE.breakA = true
	local seen = { cleared = false, held = false, autoLoadsOff = false }
	local watching = true
	task.spawn(function()
		while watching do
			local root = services.ReplicatedStorage.TypeTorch
			if root:GetAttribute("ActiveGeneration") == nil and status().generation == nil then
				seen.cleared = true
				seen.held = seen.held or holdAttribute() == "start"
				seen.autoLoadsOff = seen.autoLoadsOff or services.Players.CharacterAutoLoads == false
			end
			task.wait(0.01)
		end
	end)
	publish("TypeTorch/deploy", deployMessage("Q3", FIELDS.Q3, { "sig" }))
	check("mid-swap: I fails after A stopped, A fails again: ActiveGeneration cleared (clients stop the dead client code), the hold arms", waitFor("lost", function()
		return seen.cleared and seen.held and seen.autoLoadsOff
	end, 5))
	local joiner = joinPlayer(52, "Joiner")
	check("mid-swap: then the chain runs the backup (no peers): the hold ends, the joiner spawns, the player in game keeps their character", waitFor("backup", function()
		return running() == "ddddddd-444444" and status().backup == true and holdAttribute() == nil and services.Players.CharacterAutoLoads == true
	end, 6) and table.find(loadedCharacters, "Joiner") ~= nil and table.find(loadedCharacters, "InGame") == nil and joiner.Parent ~= nil)
	watching = false
	check("mid-swap: ActiveGeneration names the backup generation now", services.ReplicatedStorage.TypeTorch:GetAttribute("ActiveGeneration") == status().generation.name)
	-- BindToClose between the stop of the old generation and the ready of the new one: the starting generation's onClose.
	SMOKE.behave["bbbbbbb-222222"] = function()
		SMOKE.task.wait(1e6) -- never calls ready
	end
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("mid-swap: a swap is between stop and ready", waitFor("starting", function()
		return status().generation == nil and table.find(SMOKE.boots, "bbbbbbb-222222") ~= nil
	end, 3))
	local closeDone = false
	task.spawn(function()
		closeCallbacks[1]()
		closeDone = true
	end)
	check("close: BindToClose during a swap runs the starting generation's onClose", waitFor("close", function()
		return closeDone
	end, 3) and table.find(SMOKE.closed, "bbbbbbb-222222") ~= nil)
	finish()
end

if HEADS_CAP_MODE then
	check("heads-cap: boots the signed prod head", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() == "aaaaaaa-111111"
	end))
	local function stored(branch: string)
		return memoryStore.data.heads[branch], dataStore.data.heads[branch]
	end
	local function count(map): number
		local n = 0
		for _ in map do
			n += 1
		end
		return n
	end
	-- An unsigned deploy of a branch this prod server doesn't know: not recorded (forged messages can't grow the key).
	publish("TypeTorch/deploy", { b = "newdev", a = 1003, i = "ccccccc-333333", s = 50, c = "ccccccc", ch = "dev", t = nowMs() })
	task.wait(0.3)
	check("heads-cap: a prod server ignores an unsigned deploy of an unknown branch (nothing stored, one line)", stored("newdev") == nil and said("deploy message for unknown branch newdev not recorded") and count(memoryStore.data.heads) == 31)
	-- A known branch still updates.
	publish("TypeTorch/deploy", { b = "b05", a = 1003, i = "ccccccc-333333", s = 51, c = "ccccccc", ch = "dev", t = nowMs() })
	check("heads-cap: a known branch's deploy is still recorded", waitFor("b05", function()
		local memory = stored("b05")
		return memory ~= nil and memory.seq == 51
	end))
	-- A signed deploy of a new branch is recorded (32 branches now).
	publish("TypeTorch/deploy", deployMessage("E1", FIELDS.E1, { "sig", "sigF" }))
	check("heads-cap: a SIGNED deploy of an unknown branch is recorded (32 branches)", waitFor("eu", function()
		local memory, durable = stored("eu")
		return memory ~= nil and memory.seq == 40 and durable ~= nil and count(memoryStore.data.heads) == 32
	end))
	-- Full: a new branch isn't recorded even signed; the branches there keep updating.
	publish("TypeTorch/deploy", deployMessage("E2", FIELDS.E2, { "sig", "sigF" }))
	publish("TypeTorch/deploy", { b = "b06", a = 1003, i = "ccccccc-333333", s = 52, c = "ccccccc", ch = "dev", t = nowMs() })
	check("heads-cap: at HEADS_MAX_BRANCHES (32) a new branch isn't stored, even signed (warned); known branches still update", waitFor("b06", function()
		local memory = stored("b06")
		return memory ~= nil and memory.seq == 52
	end) and stored("eu2") == nil and select(2, stored("eu2")) == nil and count(memoryStore.data.heads) == 32 and count(dataStore.data.heads) == 32 and said("the stored heads hold 32 branches"))
	check("heads-cap: the server's own branch is unaffected", running() == "aaaaaaa-111111" and status().appliedSeq == 10)
	finish()
end

-- 0.3.8 GAME MESSAGING -------------------------------------------------------------------------------------------------
do -- (scoped: the harness's main chunk is at Luau's 200-local limit)
-- An envelope as another server's kernel publishes it on TypeTorch/game.
local function envelope(topic: string, data: any, fields: { [string]: any }?)
	local env = { v = 1, n = topic, d = data, j = "other-job-1", b = "prod", c = "prod", s = "public", p = 7 }
	for key, value in fields or {} do
		env[key] = value
	end
	return env
end
local function gamePublishes(): { any }
	local list = {}
	for _, entry in published do
		if entry.topic == "TypeTorch/game" then
			table.insert(list, entry.data)
		end
	end
	return list
end
local function subscribedTopics(): number
	local count = 0
	for _ in topics do
		count += 1
	end
	return count
end

if MODES38.messaging then
	check("messaging: boots", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() == "aaaaaaa-111111"
	end))
	local apiA = SMOKE.kernel
	check("messaging: the API has messagingSubscribe / messagingPublish / messagingStatus / onRollCall", type(apiA.messagingSubscribe) == "function" and type(apiA.messagingPublish) == "function" and type(apiA.messagingStatus) == "function" and type(apiA.onRollCall) == "function")
	check("messaging: lazy: no TypeTorch/game or TypeTorch/rollcall subscription before a listener", msgStub.calls["TypeTorch/game"] == nil and msgStub.calls["TypeTorch/rollcall"] == nil and status().messaging.state == "off")
	local heardA = {}
	local disconnectA = apiA:messagingSubscribe("anticheat", function(data, meta)
		table.insert(heardA, { data = data, meta = meta })
	end)
	apiA:onRollCall(function(data)
		SMOKE.askA = (SMOKE.askA or 0) + 1
	end)
	check("messaging: the first listener subscribes TypeTorch/game once, on a kernel thread", waitFor("subscribed", function()
		return status().messaging.state == "on"
	end) and msgStub.calls["TypeTorch/game"] == 1 and msgStub.owners["TypeTorch/game"] == kernelFolder.Kernel)
	check("messaging: onRollCall holds TypeTorch/rollcall (once, on a kernel thread)", waitFor("rollcall", function()
		return status().messaging.rollCall.state == "on"
	end) and msgStub.calls["TypeTorch/rollcall"] == 1 and msgStub.owners["TypeTorch/rollcall"] == kernelFolder.Kernel)
	-- Publish from this server: tagged, queued, delivered to every server (this one too).
	local report = apiA:messagingPublish("anticheat", { kind = "ban", userId = 5 })
	check("messaging: publish is queued at once (no yield) with its size", report.ok == true and report.queued == true and type(report.size) == "number" and report.size < 1000)
	check("messaging: the listener gets (data, meta): this server's tags, self = true", waitFor("own message", function()
		local first = heardA[1]
		return first ~= nil and first.data.kind == "ban" and first.data.userId == 5 and first.meta.self == true and first.meta.jobId == JOB and first.meta.branch == "prod" and first.meta.channel == "prod" and first.meta.serverType == "public" and first.meta.placeVersion == 7 and type(first.meta.sentAt) == "number"
	end))
	local wire = gamePublishes()[1]
	check("messaging: one envelope on TypeTorch/game { v = 1, n, d, j, b, c, s, p }", wire ~= nil and wire.v == 1 and wire.n == "anticheat" and wire.d.kind == "ban" and wire.j == JOB and wire.b == "prod" and wire.c == "prod" and wire.s == "public" and wire.p == 7 and wire.to == nil)
	-- Another server's messages: dispatched by game topic; malformed ones and `to` that excludes this server are dropped.
	publish("TypeTorch/game", envelope("anticheat", { kind = "ban", userId = 6 }))
	publish("TypeTorch/game", envelope("announce", "hello"))
	publish("TypeTorch/game", envelope("anticheat", { kind = "skip" }, { to = "branch", b = "dev" }))
	publish("TypeTorch/game", envelope("anticheat", { kind = "prod-only" }, { to = "prod", b = "dev", c = "dev" }))
	publish("TypeTorch/game", { v = 2, n = "anticheat", d = 1, j = "x", c = "prod", s = "public" })
	publish("TypeTorch/game", envelope("__reserved", 1))
	check("messaging: another server's message reaches the topic's listener (self = false); other topics don't", waitFor("other", function()
		return #heardA == 3 and heardA[2].data.userId == 6 and heardA[2].meta.self == false and heardA[2].meta.jobId == "other-job-1" and heardA[3].data.kind == "prod-only"
	end))
	local m = status().messaging
	check("messaging: to = branch from another branch is filtered; bad envelopes are ignored", m.filtered == 1 and m.ignored == 2)
	-- Limits, checked at once with clear errors.
	local big = apiA:messagingPublish("anticheat", { text = string.rep("x", 1000) })
	check(`messaging: over 1 KiB: too_big with the size, the limit and the envelope's overhead ({big.size} > {big.limit}, overhead {big.overhead})`, big.ok == false and big.error == "too_big" and big.size > 1000 and big.limit == 1000 and type(big.overhead) == "number" and big.overhead > 50 and big.overhead < 250)
	local quotes = apiA:messagingPublish("anticheat", { text = string.rep('"', 300) })
	check("messaging: the size counts JSON escapes (300 quotes: about 750 bytes of envelope, 1,400 escaped)", quotes.ok == false and quotes.error == "too_big")
	local badTopics = 0
	for _, topic in { "", "__x", "a b", string.rep("a", 65), 5 } do
		local result = apiA:messagingPublish(topic, 1)
		if result.ok == false and result.error == "bad_topic" then
			badTopics += 1
		end
	end
	check("messaging: bad topic names are refused (empty, __reserved, spaces, too long, not a string)", badTopics == 5)
	local cycle = {}
	cycle.self = cycle
	local badData = 0
	for _, data in { function() end, 0 / 0, math.huge, cycle, { 1, x = 2 }, { [1] = 1, [3] = 3 }, setmetatable({}, {}), { [true] = 1 } } do
		local result = apiA:messagingPublish("anticheat", data)
		if result.ok == false and result.error == "bad_data" and type(result.detail) == "string" then
			badData += 1
		end
	end
	check("messaging: data that can't travel as JSON is refused with the reason (function, NaN, inf, cycle, mixed, holes, metatable, key type)", badData == 8)
	local badTo = apiA:messagingPublish("anticheat", 1, { to = "everyone" })
	check("messaging: options.to must be all, prod or branch", badTo.ok == false and badTo.error == "bad_options")
	local ok, err = pcall(apiA.messagingSubscribe, apiA, "__tt", function() end)
	check("messaging: subscribe to a reserved topic errors", not ok and string.find(tostring(err), "reserved", 1, true) ~= nil)
	-- A failing PublishAsync is retried, then delivered.
	local before = #gamePublishes()
	msgStub.publishFailures["TypeTorch/game"] = 2
	apiA:messagingPublish("anticheat", { kind = "retry" })
	check("messaging: PublishAsync failed twice: retried and delivered", waitFor("retry", function()
		return #gamePublishes() == before + 1 and status().messaging.failed == 2 and heardA[#heardA].data.kind == "retry"
	end, 3))
	-- A swap: the next generation subscribes through the API again, but the kernel's subscription stays (no SubscribeAsync);
	-- a message that arrives after the old generation stopped and before the new one listens is replayed to it.
	local heardB = {}
	SMOKE.behave["bbbbbbb-222222"] = function(kernel)
		publish("TypeTorch/game", envelope("anticheat", { kind = "mid-swap" }, { j = "other-job-2" }))
		SMOKE.task.wait(0.1)
		kernel:messagingSubscribe("anticheat", function(data, meta)
			table.insert(heardB, { data = data, meta = meta })
		end)
		kernel:onRollCall(function()
			SMOKE.askB = (SMOKE.askB or 0) + 1
		end)
	end
	local heardABefore = #heardA
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("messaging: swapped to B", waitFor("swap", function()
		return running() == "bbbbbbb-222222"
	end))
	check("messaging: the swap didn't subscribe again (TypeTorch/game and TypeTorch/rollcall: still 1 SubscribeAsync each)", msgStub.calls["TypeTorch/game"] == 1 and msgStub.calls["TypeTorch/rollcall"] == 1)
	check("messaging: the message that arrived mid-swap is replayed to B's listener (meta.replayed), not to A", waitFor("replay", function()
		local first = heardB[1]
		return first ~= nil and first.data.kind == "mid-swap" and first.meta.replayed == true
	end) and #heardA == heardABefore and status().messaging.replayed == 1)
	publish("TypeTorch/game", envelope("anticheat", { kind = "after" }))
	check("messaging: after the swap only B's listener hears new messages (A's went with its generation)", waitFor("after", function()
		return heardB[#heardB] ~= nil and heardB[#heardB].data.kind == "after"
	end) and #heardA == heardABefore and status().messaging.listeners == 1)
	publish("TypeTorch/rollcall", { q = 1, j = "asker-1", t = nowMs() })
	check("messaging: a roll call ask goes to the running generation's handler only", waitFor("ask", function()
		return SMOKE.askB == 1
	end) and SMOKE.askA == nil)
	disconnectA() -- (a stopped generation's disconnect is harmless)
	-- The universe's rate on the game topic: at the soft limit publishes wait, then go.
	local seen = status().messaging.rate
	Constants.MESSAGING_TOPIC_SOFT = seen
	local beforeWait = #gamePublishes()
	local waiting = SMOKE.kernel:messagingPublish("anticheat", { kind = "waits" })
	task.wait(0.4)
	local m2 = status().messaging
	check(`messaging: at the soft limit ({seen} seen this minute) a publish waits in the queue (throttled, logged)`, waiting.ok == true and #gamePublishes() == beforeWait and m2.queued == 1 and m2.throttled == 1 and said("publishes are waiting"))
	Constants.MESSAGING_TOPIC_SOFT = 1000
	check("messaging: below the limit again it goes out", waitFor("released", function()
		return #gamePublishes() == beforeWait + 1 and status().messaging.queued == 0
	end, 4))
	-- Too old in the queue: dropped (counted, logged); a full queue refuses at once.
	Constants.MESSAGING_TOPIC_SOFT = 0
	Constants.MESSAGING_MAX_DELAY = 0.3
	local droppedBefore = status().messaging.dropped
	SMOKE.kernel:messagingPublish("anticheat", { kind = "stale" })
	check("messaging: a message older than MESSAGING_MAX_DELAY in the queue is dropped", waitFor("dropped", function()
		return status().messaging.dropped == droppedBefore + 1 and status().messaging.queued == 0
	end, 4) and said("dropped a message"))
	Constants.MESSAGING_MAX_DELAY = 30
	Constants.MESSAGING_QUEUE_MAX = 2
	SMOKE.kernel:messagingPublish("anticheat", 1)
	SMOKE.kernel:messagingPublish("anticheat", 2)
	local full = SMOKE.kernel:messagingPublish("anticheat", 3)
	check("messaging: a full queue refuses at once (queue_full)", full.ok == false and full.error == "queue_full")
	Constants.MESSAGING_TOPIC_SOFT = 1000
	Constants.MESSAGING_QUEUE_MAX = 100
	waitFor("drained", function()
		return status().messaging.queued == 0
	end, 4)
	local final = status().messaging
	check("messaging: status().messaging has the counters, the universe's rate and this server's budget", final.topic == "TypeTorch/game" and final.state == "on" and final.topics == 1 and type(final.rate) == "number" and final.softLimit == 1000 and final.budget == 150 and final.published >= 5 and final.received >= 8 and final.rollCall.asks == 1 and final.rollCall.handled == 1)
	check(`messaging: subscriptions held: deploy, pin, rekey, game, roll call ({subscribedTopics()}; Roblox allows 20 + 8 x players)`, subscribedTopics() == 5 and topics["TypeTorch/game"] ~= nil and topics["TypeTorch/rollcall"] ~= nil)
	finish()
end

if MODES38.messagingStudio then
	check("messaging-studio: boots the local payload", waitFor("boot", function()
		return SMOKE.kernel ~= nil and string.sub(running() or "", 1, 6) == "local-"
	end))
	local api = SMOKE.kernel
	local heard = {}
	api:messagingSubscribe("announce", function(data, meta)
		table.insert(heard, { data = data, meta = meta })
	end)
	api:onRollCall(function() end)
	local report = api:messagingPublish("announce", "hi")
	local prodOnly = api:messagingPublish("announce", "prod only", { to = "prod" })
	check("messaging-studio: publish loops back to this session (self = true), never MessagingService", waitFor("loopback", function()
		return heard[1] ~= nil and heard[1].data == "hi" and heard[1].meta.self == true and heard[1].meta.serverType == "studio"
	end) and report.ok == true and report.loopback == true and prodOnly.ok == true and #gamePublishes() == 0)
	task.wait(0.1)
	local m = status().messaging
	check("messaging-studio: no TypeTorch/game or roll call subscription; to = prod skips a dev session", msgStub.calls["TypeTorch/game"] == nil and msgStub.calls["TypeTorch/rollcall"] == nil and m.state == "local" and m.rollCall.state == "local" and #heard == 1 and m.filtered == 1)
	finish()
end

if MODES38.messagingMissing then
	check("messaging-missing: boots without Messaging.luau and says so", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() ~= nil
	end) and said("TypeTorchKernel.Messaging is missing"))
	check("messaging-missing: no messaging methods on the API (the framework says what is missing); status().messaging is nil", SMOKE.kernel.messagingPublish == nil and SMOKE.kernel.onRollCall == nil and status().messaging == nil)
	finish()
end
end

-- 0.3.8 THE SIGNED SETTINGS RECORD (plans/20) ---------------------------------------------------------------------------
if MODES38.settings then
	check("settings: boots", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() ~= nil
	end))
	local function settingsStatus()
		return status().settings
	end
	local first = settingsStatus()
	check("settings: the signed record is read at boot (seq 1, verified, its fields)", first.state == "ok" and first.seq == 1 and (first.verifiedBy == "sig" or first.verifiedBy == "sigF") and table.find(first.fields, "game") ~= nil and table.find(first.fields, "analytics") ~= nil and table.find(first.fields, "access") ~= nil and table.find(first.fields, "channels") ~= nil)
	local api = SMOKE.kernel
	local copy = api:settings()
	check("settings: api:settings() is a copy with seq, at and every field (server only)", copy ~= nil and copy.seq == 1 and copy.at == "2026-10-06T12:00:00.000Z" and copy.game["shop.price"] == 50 and copy.channels.dev == "dev" and copy.analytics.token == "analytics-ingest-token-0123456789")
	copy.game["shop.price"] = 1
	check("settings: changing the copy changes nothing in the kernel", api:settings().game["shop.price"] == 50)
	local owner = joinPlayer(5, "SettingsOwner")
	check("settings: access from the record (member 5 is an owner)", api:devInfo(owner).role == "owner" and api:devInfo(owner).reason == "member")
	-- Server only: nothing of it reaches clients (no attribute, no remote carries the analytics token).
	local leaked = false
	for _, instance in { services.ReplicatedStorage.TypeTorch, clientStandIn } do
		for _, value in internals[instance].attributes do
			if typeof(value) == "string" and string.find(value, "analytics-ingest-token", 1, true) then
				leaked = true
			end
		end
	end
	for _, call in firedToClient do
		for index = 2, #call do
			if typeof(call[index]) == "string" and string.find(call[index], "analytics-ingest-token", 1, true) then
				leaked = true
			end
		end
	end
	check("settings: no token in any replicated attribute or remote", not leaked)
	-- A write and a ping: re-read within the ping gap; the running generation hears it.
	local heard = {}
	api:onSettingsChanged(function(settings)
		table.insert(heard, settings)
	end)
	dataStore.data.settings = deepCopy(SMOKE.settings.s2)
	local readsBefore = dataStore.reads.settings or 0
	publish("TypeTorch/deploy", { k = "settings", s = 2 })
	check("settings: a ping re-reads at once; the generation hears the new copy (onSettingsChanged)", waitFor("seq 2", function()
		return settingsStatus().seq == 2 and #heard == 1 and heard[1].seq == 2 and heard[1].game["shop.price"] == 75
	end, 2) and (dataStore.reads.settings or 0) == readsBefore + 1)
	publish("TypeTorch/deploy", { k = "settings", s = 2 })
	publish("TypeTorch/deploy", { k = "settings", s = 1 })
	task.wait(0.2)
	check("settings: a ping for a seq it already holds reads nothing", (dataStore.reads.settings or 0) == readsBefore + 1)
	-- A bad signature (game code rewrote the body of a signed record): refused, #2 kept.
	local forged = deepCopy(SMOKE.settings.s5)
	forged.body = string.gsub(forged.body, "999", "1")
	dataStore.data.settings = forged
	publish("TypeTorch/deploy", { k = "settings", s = 5 })
	check("settings: a bad signature is refused; the last good copy (#2) stays", waitFor("refused", function()
		local now = settingsStatus()
		return now.refused ~= nil and now.refused.seq == 5 and string.find(now.refused.why, "signature", 1, true) ~= nil
	end, 2) and settingsStatus().seq == 2 and settingsStatus().state == "ok" and api:settings().game["shop.price"] == 75 and #heard == 1 and said("settings: signature"))
	-- An older signed record put back (a replay): refused.
	dataStore.data.settings = deepCopy(SMOKE.settings.s1)
	publish("TypeTorch/deploy", { k = "settings", s = 9 }) -- (a ping only asks for a read; the record decides)
	check("settings: an older seq (a replay of #1) is ignored", waitFor("older", function()
		local now = settingsStatus()
		return now.refused ~= nil and now.refused.seq == 1 and string.find(now.refused.why, "not newer", 1, true) ~= nil
	end, 2) and settingsStatus().seq == 2)
	-- Unsigned: refused.
	local unsigned = deepCopy(SMOKE.settings.s5)
	unsigned.sig, unsigned.sigF = nil, nil
	dataStore.data.settings = unsigned
	publish("TypeTorch/deploy", { k = "settings", s = 10 })
	check("settings: an unsigned record is refused", waitFor("unsigned", function()
		local now = settingsStatus()
		return now.refused ~= nil and string.find(now.refused.why, "unsigned", 1, true) ~= nil
	end, 2) and settingsStatus().seq == 2)
	-- The record deleted: the last good copy stays.
	dataStore.data.settings = nil
	publish("TypeTorch/deploy", { k = "settings", s = 11 })
	check("settings: a missing record keeps the last good copy", waitFor("gone", function()
		local now = settingsStatus()
		return now.refused ~= nil and string.find(now.refused.why, "gone", 1, true) ~= nil
	end, 2) and settingsStatus().seq == 2 and api:settings() ~= nil)
	-- No ping: the sync tick reads it (at most every SETTINGS_REFRESH_SECONDS).
	Constants.SETTINGS_REFRESH_SECONDS = 0.1
	Constants.POLL_SECONDS = 0.2
	dataStore.data.settings = deepCopy(SMOKE.settings.s5)
	check("settings: without a ping the periodic read takes a newer signed copy (#5)", waitFor("seq 5", function()
		return settingsStatus().seq == 5 and settingsStatus().refused == nil
	end, 3) and #heard == 2)
	finish()
end

if MODES38.settingsMissing then
	check("settings-missing: boots without Settings.luau and says so", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() ~= nil
	end) and said("TypeTorchKernel.Settings is missing"))
	check("settings-missing: the defaults; status says why; api:settings() is nil", status().settings.state == "missing" and string.find(status().settings.error or "", "Settings module", 1, true) ~= nil and SMOKE.kernel:settings() == nil and status().branch == "prod")
	finish()
end

if MODES38.detached then
	Constants.DETACHED_SLOW = 0.4
	check("detached: boots", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() == "aaaaaaa-111111"
	end))
	check("detached: the API has runDetached; status().detached starts at zero", type(SMOKE.kernel.runDetached) == "function" and status().detached.running == 0 and status().detached.max == 256)
	-- Generation B starts a thread of its own and a detached job, both 1.5 s long, then B is swapped out (hard stop).
	local seen = {}
	SMOKE.behave["bbbbbbb-222222"] = function(kernel)
		SMOKE.task.spawn(function()
			SMOKE.task.wait(1.5)
			seen.owned = true
		end)
		seen.id = kernel:runDetached(function()
			SMOKE.task.wait(1.5)
			kernel:persist("detached-save", function()
				return {}
			end).saved = true
			seen.ran = true
			return "saved"
		end, function(ok, result)
			seen.callback = { ok, result }
		end)
	end
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("detached: B runs and started its job (returns an id)", waitFor("B", function()
		return running() == "bbbbbbb-222222" and seen.id ~= nil
	end) and seen.id == 1 and status().detached.running == 1)
	publish("TypeTorch/deploy", deployMessage("M6", FIELDS.M6, { "sig" }))
	check("detached: swapped to F; B's job still runs after B's hard stop", waitFor("F", function()
		return running() == "fffffff-666666"
	end) and status().detached.running == 1 and seen.ran == nil)
	check("detached: the job finished (its persist write is there); B's own thread died with B", waitFor("job", function()
		return seen.ran == true
	end, 3) and SMOKE.kernel:persist("detached-save", function()
		return {}
	end).saved == true and seen.owned == nil)
	check("detached: B's callback was dropped (B stopped); counted as finished", seen.callback == nil and status().detached.running == 0 and status().detached.finished == 1 and status().detached.failed == 0)
	-- The running generation: results and errors reach done(ok, result); errors are logged with the generation.
	local api = SMOKE.kernel
	api:runDetached(function()
		return 42
	end, function(ok, value)
		seen.answer = { ok, value }
	end)
	check("detached: done(true, result) while the generation runs", waitFor("answer", function()
		return seen.answer ~= nil
	end) and seen.answer[1] == true and seen.answer[2] == 42)
	api:runDetached(function()
		error("profile store down", 0)
	end, function(ok, err)
		seen.failure = { ok, err }
	end)
	local lastError = nil
	check("detached: an error goes to done(false, err), the log (with the generation) and status().detached", waitFor("failure", function()
		return seen.failure ~= nil
	end) and seen.failure[1] == false and seen.failure[2] == "profile store down" and said("detached job #3 of fffffff-666666#") and said("failed: profile store down") and status().detached.failed == 1 and (function()
		lastError = status().detached.lastError
		return lastError ~= nil and string.sub(lastError.generation, 1, 14) == "fffffff-666666" and lastError.error == "profile store down"
	end)())
	check("detached: a job's error never counts toward the generation's health", status().health == nil or (status().health.errors or 0) == 0)
	-- Slow jobs are logged once; past the cap runDetached errors at once.
	Constants.DETACHED_MAX = 2
	api:runDetached(function()
		SMOKE.task.wait(0.8)
	end)
	api:runDetached(function()
		SMOKE.task.wait(0.8)
	end)
	local okCap, capError = pcall(function()
		api:runDetached(function() end)
	end)
	check("detached: past the cap it errors at once, naming the cap", okCap == false and string.find(tostring(capError), "the cap is 2", 1, true) ~= nil and status().detached.running == 2)
	local okArg, argError = pcall(function()
		api:runDetached("not a function")
	end)
	check("detached: a non-function is refused", okArg == false and string.find(tostring(argError), "pass a function", 1, true) ~= nil)
	check("detached: a job past DETACHED_SLOW is logged once (status: slow, oldest; B's job was slow too)", waitFor("slow", function()
		return status().detached.slow == 3
	end, 2) and said("still runs after 0.4 s") and (status().detached.oldest or -1) >= 0)
	check("detached: both finish; running back to 0", waitFor("drained", function()
		return status().detached.running == 0
	end, 3) and status().detached.started == 5 and status().detached.finished == 5)
	Constants.DETACHED_MAX = 256
	finish()
end

if MODES38.errors then
	local BASE = "https://backend.example.test/api"
	local function posts(path: string)
		local list = {}
		for _, request in httpRequests do
			if request.url == BASE .. path then
				table.insert(list, request)
			end
		end
		return list
	end
	local function postedItem(match: (any) -> boolean)
		for _, request in posts("/v1/errors") do
			for _, item in request.body.errors do
				if match(item) then
					return item, request
				end
			end
		end
		return nil, nil
	end
	check("errors: boots", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() == "aaaaaaa-111111"
	end))
	check("errors: settings.backend wins over settings.fleet: heartbeats go to <url>/v1/fleet/heartbeat with its key", waitFor("heartbeat", function()
		local list = posts("/v1/fleet/heartbeat")
		return #list > 0 and list[1].headers.Authorization == "Bearer " .. FLEET_TOKEN
	end) and status().fleet.source == "backend" and status().fleet.host == "backend.example.test")
	check("errors: heartbeats carry the budget summary bu (limits for the player count)", waitFor("bu", function()
		local list = posts("/v1/fleet/heartbeat")
		local body = list[#list].body
		return body.bu ~= nil and body.bu.ds.lr == 60 + 40 * #fakePlayers and body.bu.h.l == 500 and body.bu.by.k ~= nil
	end))
	local rider = joinPlayer(424242424, "Rider", nil, false)
	rider.DisplayName = "Speedy"
	services.Players.PlayerAdded:Fire(rider)
	check("errors: api:setAnalyticsId takes a pid (refuses junk)", SMOKE.kernel:setAnalyticsId(rider, "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f") == true and SMOKE.kernel:setAnalyticsId(rider, "not a pid") == false)
	services.ScriptContext.Error:Fire("ServerStorage.TypeTorch.Generations.aaaaaaa-111111#1.Server.round:12: Rider (424242424) fell", "ServerStorage.TypeTorch.Generations.aaaaaaa-111111#1.Server.round:12 function fall", nil)
	local item, request = nil, nil
	check("errors: a server error is posted to <url>/v1/errors", waitFor("errors post", function()
		item, request = postedItem(function(entry)
			return entry.realm == "server" and string.find(entry.template, "fell", 1, true) ~= nil
		end)
		return item ~= nil
	end, 4))
	check("errors: { v = 1, j = JobId } with the key", request ~= nil and request.body.v == 1 and request.body.j == JOB and request.headers.Authorization == "Bearer " .. FLEET_TOKEN)
	check("errors: templated (name, UserId, the generation), no name left", item ~= nil and item.template == "ServerStorage.TypeTorch.Generations.<gen>.Server.round:12: <player.name> (<player.user_id>) fell")
	check("errors: fingerprint, count, branch, build, stack, the named player's pid", item ~= nil and #item.fp == 16 and item.count == 1 and item.branch == "prod" and item.build == "aaaaaaa-111111" and item.stack == "ServerStorage.TypeTorch.Generations.<gen>.Server.round:12 function fall" and item.pids ~= nil and item.pids[1] == "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f")
	local net = services.ReplicatedStorage.TypeTorch.Net
	net.OnServerEvent:Fire(rider, "*", "__tt/errors", { e = { { m = "Players.Rider.PlayerScripts.ui:3: Speedy's bar is nil", s = "Players.Rider.PlayerScripts.ui:3", n = 4, g = "aaaaaaa-111111#1" } }, d = 2 })
	local clientItem = nil
	check("errors: a client batch (kernel channel __tt/errors) is templated on the server and posted", waitFor("client post", function()
		clientItem = postedItem(function(entry)
			return entry.realm == "client"
		end)
		return clientItem ~= nil
	end, 4) and clientItem.template == "Players.<player.name>.PlayerScripts.ui:3: <player.display_name>'s bar is nil" and clientItem.count == 4 and clientItem.pids[1] == "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f" and clientItem.build == "aaaaaaa-111111")
	local info = status().errors
	check("errors: status().errors counts (seen, sent, the client's drops) and shows templates only", info.enabled and info.seen.server >= 1 and info.seen.client == 4 and info.sent >= 2 and info.dropped.client == 2 and info.host == "backend.example.test" and #info.top >= 2)
	local leaked = false
	for _, entry in httpRequests do
		local text = serde.encode("json", entry.body)
		leaked = leaked or string.find(text, "Rider", 1, true) ~= nil or string.find(text, "Speedy", 1, true) ~= nil or string.find(text, "424242424", 1, true) ~= nil
	end
	check("errors: no player name or UserId in any request body", not leaked)
	local old = false
	for _, entry in httpRequests do
		old = old or string.find(entry.url, "old-fleet", 1, true) ~= nil
	end
	check("errors: nothing goes to the old settings.fleet URL", not old)
	local snapshot = SMOKE.kernel:budget()
	local function used(kind: string, name: string): number
		for _, row in snapshot.kinds[kind].rows do
			if row.name == name then
				return row.used
			end
		end
		return -1
	end
	local labels = {}
	for _, row in snapshot.detail do
		labels[`{row.caller}/{row.kind}/{row.op}`] = row.total
	end
	check("budget: the kernel's DataStore reads (settings, heads) and MemoryStore units are counted", used("datastore", "read") > 0 and (snapshot.kinds.datastore.callers.kernel or 0) > 0 and used("memorystore", "units") > 0)
	check("budget: HTTP per label (fleet heartbeats, error reports)", (labels["kernel/http/fleet"] or 0) > 0 and (labels["kernel/http/errors"] or 0) >= 2)
	check("budget: the kernel's subscriptions (deploy, pin, rekey)", used("messaging", "subscribe") >= 3)
	SMOKE.kernel:budgetCount("analytics", "datastore", "read", 2)
	SMOKE.kernel:budgetCount("kernel", "http", "sneaky", 1)
	snapshot = SMOKE.kernel:budget()
	check("budget: api:budgetCount counts for its caller (never as the kernel)", snapshot.kinds.datastore.callers.analytics == 2 and snapshot.kinds.http.callers.game == 1)
	check("budget: status().budget is the heartbeat summary; the snapshot lists the running generation", status().budget ~= nil and status().budget.h.l == 500 and snapshot.generations[1] ~= nil and snapshot.generations[1].running == true)
	finish()
end

if ACCESS_MODE then
	check("access: boots", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() ~= nil
	end))
	local member = joinPlayer(9, "Member")
	local api = SMOKE.kernel
	check("access: the settings (seq 1) list no members: a would-be member isn't a dev", api:devInfo(member).dev == false and status().settings.seq == 1)
	-- 0.3.8: `typetorch access push` writes a new signed record (seq 2) and pings: it applies within seconds.
	dataStore.data.settings = deepCopy(SMOKE.settings.access2)
	publish("TypeTorch/deploy", { k = "settings", s = 2 })
	check("access: a settings write + ping makes the member a dev at once", waitFor("dev", function()
		return api:devInfo(member).dev == true
	end, 1) and said("dev access from the settings: 1 member(s)"))
	dataStore.data.settings = deepCopy(SMOKE.settings.access3)
	publish("TypeTorch/deploy", { k = "settings", s = 3 })
	check("access: a revocation pushed the same way applies at once", waitFor("revoked", function()
		return api:devInfo(member).dev == false and api:devInfo(member).reason == "revoked"
	end, 1))
	-- In-universe code can write the DataStore: a forged record (seq 4, member 66 as owner, the old signatures) is refused.
	local forged = deepCopy(SMOKE.settings.access2)
	forged.seq = 4
	forged.body = '{"access":{"members":{"66":"owner"},"revoked":{}},"defaultBranch":"prod"}'
	dataStore.data.settings = forged
	publish("TypeTorch/deploy", { k = "settings", s = 4 })
	local intruder = joinPlayer(66, "Intruder")
	task.wait(0.3)
	check("access: a forged record (game code wrote it, bad signature) is refused; the last good lists stay", api:devInfo(intruder).dev == false and api:devInfo(member).reason == "revoked" and status().settings.seq == 3 and status().settings.refused ~= nil and string.find(status().settings.refused.why, "signature", 1, true) ~= nil)
	finish()
end

if KERNEL_CRASH_MODE then
	local held = joinPlayer(71, "Held")
	check("kernel-crash: the kernel errored after the hold: players are held (no character, Hold start)", waitFor("crash", function()
		return #kernelErrors == 1 and string.find(kernelErrors[1], "no service TextChatService", 1, true) ~= nil
	end, 2) and services.Players.CharacterAutoLoads == false and clientStandIn:GetAttribute("Hold") == "start" and held.Character == nil)
	check("kernel-crash: 5 s past the budget the dead man moves them anyway (a fresh server, bounce 1)", waitFor("moved", function()
		local list = teleportsOf("Held")
		return #list >= 1 and bounceData(list[1]).bounce == 1 and list[1].options.ServerInstanceId == nil
	end, 8) and clientStandIn:GetAttribute("Hold") == "move" and said("the kernel didn't finish its boot"))
	local late = joinPlayer(72, "Late")
	check("kernel-crash: new joiners are moved too", waitFor("late", function()
		return #teleportsOf("Late") >= 1
	end, 3) and late.Character == nil)
	-- The kernel error was the point of this mode.
	table.clear(kernelErrors)
	table.clear(scriptErrors)
	finish()
end

if CLIENT_FAIL_MODE then
	check("client-fail: boots the dev head", waitFor("boot", function()
		return SMOKE.kernel ~= nil and running() == "ddddddd-444444"
	end))
	local player = joinPlayer(61, "Client1")
	local net = services.ReplicatedStorage.TypeTorch.Net
	local generation = status().generation.name
	local function sentTo(who, channel: string): { any }
		local list = {}
		for _, call in firedToClient do
			if call[1] == who and call[3] == channel then
				table.insert(list, call[4])
			end
		end
		return list
	end
	net.OnServerEvent:Fire(player, "*", "__tt/client", { g = generation, ok = false, e = "client boom", ms = 40, retried = true })
	check("client-fail: failed after its retry: the server re-sends the client code once (PlayerGui.TypeTorchResend, __tt/resend)", waitFor("resend", function()
		local folder = player.PlayerGui:FindFirstChild("TypeTorchResend")
		local tree = folder and folder:FindFirstChild(generation)
		return tree ~= nil and tree:FindFirstChild("Client") ~= nil and #sentTo(player, "__tt/resend") == 1 and sentTo(player, "__tt/resend")[1].g == generation
	end) and status().clients.resent == 1)
	net.OnServerEvent:Fire(player, "*", "__tt/client", { g = generation, ok = false, e = "client boom again", ms = 40, resent = true })
	check("client-fail: the re-sent copy fails too: the player is told (hold move) and moved: no healthy peer, so a rejoin of this reserved server", waitFor("move", function()
		local list = teleportsOf("Client1")
		return #list == 1 and list[1].options.ReservedServerAccessCode == "smoke-access-code" and sentTo(player, "__tt/hold")[1] == "move"
	end, 3))
	check("client-fail: reported in status().clients and the fleet status `clients`, logged", status().clients.moved == 1 and fleet().clients ~= nil and fleet().clients.resent == 1 and fleet().clients.moved == 1 and hasEvent("client_moved", "userId", 61))
	local bounced = joinPlayer(62, "Client2", 3)
	net.OnServerEvent:Fire(bounced, "*", "__tt/client", { g = generation, ok = false, retried = true })
	net.OnServerEvent:Fire(bounced, "*", "__tt/client", { g = generation, ok = false, resent = true })
	check("client-fail: a player who already bounced 3 times is kicked instead (the client message)", waitFor("kick", function()
		return table.find(kicked, "Client2") ~= nil
	end, 3) and kickMessages.Client2 == "The game didn't load. Please rejoin." and #teleportsOf("Client2") == 0)
	-- The re-sent copies go with their generation (after the client tree grace).
	publish("TypeTorch/deploy", { b = "dev", a = 1002, i = "bbbbbbb-222222", s = 20, c = "bbbbbbb", ch = "dev", t = nowMs() })
	check("client-fail: after a swap the old generation's re-sent copy is removed", waitFor("cleanup", function()
		return running() == "bbbbbbb-222222" and player.PlayerGui.TypeTorchResend:FindFirstChild(generation) == nil
	end, 3))
	finish()
end

check("kernel booted the signed head from the durable copy (not the forged MemoryStore head)", waitFor("boot", function()
	return running() == "aaaaaaa-111111"
end))
if not SMOKE.kernel then
	print(`kernel errors: {table.concat(kernelErrors, "\n")}\nscript errors: {table.concat(scriptErrors, "\n")}`)
	for _, line in output do
		print(`  [{line.kind}] {line.text}`)
	end
	process.exit(1)
end
local s = status()
check("api.kernelBuild", SMOKE.kernel.kernelBuild == "abc1234")
check("status: appliedSeq 10", s.appliedSeq == 10)
check("outside Studio, ServerStorage.TypeTorchDev.Payload is ignored", s.localPayload == nil and s.serverType == "public" and localSource.Parent == devFolder)

if FALLBACK_MODE then
	-- The key asset never loaded: sigF decides, sig alone is refused, and the badge shows the fallback only.
	local keys = SMOKE.kernel:keys()
	check("fallback: mode is fallback only, the read error is kept", s.signing.mode == "fallback only" and keys.mode == "fallback only" and keys.loaded == false and keys.lastError ~= nil)
	check("fallback: running artifact verified by the fallback key only", s.generation.artifact.verified and not s.generation.artifact.verified.main and s.generation.artifact.verified.fallback)
	check("fallback: the signed settings verify by sigF (0.3.8)", s.settings.state == "ok" and s.settings.verifiedBy == "sigF" and s.settings.seq == 1)
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig" }))
	check("fallback: sig alone refused", waitFor("refusal", function()
		return rejected("deploy") == 1
	end) and running() == "aaaaaaa-111111")
	publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sigF" }))
	check("fallback: sigF accepted", waitFor("swap to B", function()
		return running() == "bbbbbbb-222222" and status().appliedSeq == 11
	end))
	finish()
end

check("status: signed only, key asset mode, build stamped", s.signedOnly == true and s.signing.mode == "key asset" and s.kernelBuild == "abc1234" and s.kernelVersion == "0.5.0")

-- 0.3.8: no settings record here (a game that never ran `typetorch settings push`): the defaults, reported as missing.
do
	local settings = status().settings
	check("settings: no record: state missing, the defaults (branch prod), nothing refused", settings ~= nil and settings.state == "missing" and settings.seq == nil and #settings.fields == 0 and status().branch == "prod" and settings.refused == nil)
end
check("status: running artifact verified main + fallback", s.generation.artifact.verified and s.generation.artifact.verified.main and s.generation.artifact.verified.fallback)

-- Unsigned deploy: refused.
publish("TypeTorch/deploy", deployMessage(nil, FIELDS.M4))
check("unsigned deploy refused", waitFor("refusal", function()
	return rejected("deploy") == 1
end) and running() == "aaaaaaa-111111")

-- Signed deploy: swaps.
publish("TypeTorch/deploy", deployMessage("M2", FIELDS.M2, { "sig", "sigF" }))
check("signed deploy swaps", waitFor("swap to B", function()
	return running() == "bbbbbbb-222222" and status().appliedSeq == 11
end))

-- Signed, but dev channel: refused.
publish("TypeTorch/deploy", deployMessage("M3", FIELDS.M3, { "sig", "sigF" }))
check("signed dev-channel deploy refused", waitFor("refusal", function()
	return rejected("deploy") == 2
end) and running() == "bbbbbbb-222222")

-- Replay of an older signed deploy: refused (seq).
publish("TypeTorch/deploy", deployMessage("H1", FIELDS.H1, { "sig" }))
check("replayed older signed deploy refused", waitFor("refusal", function()
	return rejected("deploy") == 3 and string.find(status().rejected.last.why, "not newer", 1, true) ~= nil
end) and running() == "bbbbbbb-222222")

-- Signed, but the payload holds a Script: refused at mount, not retried.
publish("TypeTorch/deploy", deployMessage("M5", FIELDS.M5, { "sig" }))
local slFailed = waitFor("mount failure", function()
	for _, line in output do
		if string.find(line.text, "holds more than Folders and ModuleScripts", 1, true) then
			return true
		end
	end
	return false
end)
check("S-L4: payload with a Script refused at mount", slFailed and running() == "bbbbbbb-222222" and status().appliedSeq == 11)

-- Signed, but LoadAsset fails twice: retried, then it runs (P-K2).
publish("TypeTorch/deploy", deployMessage("M6", FIELDS.M6, { "sig" }))
check("P-K2: failed loads retried, then the swap lands", waitFor("swap to F", function()
	return running() == "fffffff-666666" and status().appliedSeq == 15
end, 8))

-- Signed rollback to B.
publish("TypeTorch/deploy", deployMessage("M7", FIELDS.M7, { "sig" }))
check("signed rollback swaps", waitFor("rollback to B", function()
	return running() == "bbbbbbb-222222" and status().appliedSeq == 16
end))

-- Pins: unsigned refused; signed pin and unpin work.
local unsignedPin = table.clone(FIELDS.P2)
unsignedPin.t = nowMs()
publish("TypeTorch/pin", unsignedPin)
check("unsigned pin refused on a prod server", waitFor("pin refusal", function()
	return rejected("pin") == 1
end) and running() == "bbbbbbb-222222")
publish("TypeTorch/pin", deployMessage("P2", FIELDS.P2, { "sig" }))
check("signed pin runs the experiment", waitFor("pin", function()
	return running() == "aaaaaaa-111111" and status().experiment ~= nil
end))
publish("TypeTorch/pin", deployMessage("P3", FIELDS.P3, { "sig" }))
check("signed unpin goes back to the branch head", waitFor("unpin", function()
	return running() == "bbbbbbb-222222" and status().experiment == nil
end))

-- Key rotation after a rekey hint: the rotated key is trusted, the main key revoked.
Signing.MIN_INTERVAL.hint = 0
keyAsset.publicKeys = `{ROTATED}, {MAIN}`
keyAsset.revokedKeys = MAIN
bumpVersion(500)
publish("TypeTorch/rekey", { t = nowMs() })
check("rekey hint: change detected and marked hinted", waitFor("key change", function()
	local keys = SMOKE.kernel:keys()
	return keys.lastChange ~= nil and keys.lastChange.hinted == true and keys.trusted == 1
end))
SMOKE.hangStop = true -- the running generation's stop never returns
publish("TypeTorch/deploy", deployMessage("M8", FIELDS.M8, { "sigR" }))
check("deploy signed with the rotated key swaps (past a stuck onStop, P-K4)", waitFor("swap to F", function()
	return running() == "fffffff-666666" and status().appliedSeq == 17
end))
SMOKE.hangStop = false
local deadlineHit = false
for _, line in output do
	deadlineHit = deadlineHit or string.find(line.text, "stop took more than", 1, true) ~= nil
end
check("P-K4: the stuck stop was cut off at the deadline", deadlineHit)
publish("TypeTorch/deploy", deployMessage("M9", FIELDS.M9, { "sig", "sigF" }))
check("deploy signed with the revoked key refused (sigF ignored once the key asset loaded)", waitFor("refusal", function()
	return rejected("deploy") == 4
end) and running() == "fffffff-666666")

-- A re-signed head (r = "resign", same asset as running): the head and appliedSeq move, no swap.
local bootsBefore = #SMOKE.boots
publish("TypeTorch/deploy", deployMessage("M10", FIELDS.M10, { "sigR" }))
check("re-signed head: appliedSeq moves, no swap", waitFor("resign", function()
	return status().appliedSeq == 19
end) and running() == "fffffff-666666" and #SMOKE.boots == bootsBefore)
check("re-signed head: the stored head carries r = resign and verifies", (function()
	local head = memoryStore.data.heads.prod
	return head ~= nil and head.seq == 19 and head.r == "resign" and head.sig ~= nil
end)())

-- Dev menu pins on a prod server: refused (only signed remote pins work there).
local owner = newInstance("Player", "Owner")
owner.UserId = 1
local pinReport = SMOKE.kernel:pinArtifact(owner, 1002)
local experimentReport = SMOKE.kernel:pinArtifact(owner, 1002, { experiment = true })
check("dev menu pins refused on a prod server", pinReport.ok == false and string.find(pinReport.error, "typetorch pin", 1, true) ~= nil and experimentReport.ok == false and running() == "fffffff-666666")

-- Dev-facing data.
local keys = SMOKE.kernel:keys()
check("keys(): rows, fingerprints, fallback, counters", keys.mode == "key asset" and #keys.publicKeys == 2 and keys.fallback.fingerprint == "43f1e550" and keys.rejected.total >= 5 and keys.signedOnly == true)
local list = SMOKE.kernel:artifacts()
local signedEntries, unsignedEntries = 0, 0
for _, entry in list do
	if entry.verified then
		signedEntries += 1
	else
		unsignedEntries += 1
	end
	check(`artifacts(): no raw signatures ({entry.artifactId})`, entry.sig == nil and entry.sigF == nil)
end
check(`artifacts(): signed entries carry verified ({signedEntries} signed, {unsignedEntries} unsigned)`, signedEntries >= 3 and unsignedEntries >= 1)
finish()
