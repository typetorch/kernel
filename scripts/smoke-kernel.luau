-- Smoke test for the whole server kernel (from kernel/): `lune run scripts/smoke-kernel.luau`, then again with
-- `--fallback` (the key asset never loads), `--dev` (a reserved dev-branch server), `--vip` (a non-dev's private server),
-- `--bootstrap`, `--bootstrap-only` (BootstrapHeads), `--blind` (the boot fail-safe), `--empty` (nothing usable) and
-- `--studio-local` (0.3.1: a Studio session mounting ServerStorage.TypeTorchDev.Payload; every other mode has the same
-- folder in ServerStorage and checks that a non-Studio server ignores it), and 0.3.2's `--health` (a reserved dev
-- server: the health window, the last-known-good chain, heartbeat and deploy reports, the busy-flag hazard, client
-- reports, onClose, subscribe and private-read retries, revocations unknown), `--health-prod` (the same failures on a
-- signed public server) and `--lkg-boot` (a prod head that fails to start at boot: the signed deployment history,
-- never an unsigned entry). Every mode also checks that no swap ran on a thread its own stopped generation owned.
-- Boots the real src/server/*.luau as a PUBLIC (prod) server under Lune, with a small Instance emulator and stubbed
-- services (InsertService, MessagingService, DataStore, MemoryStore, ConfigService unavailable), then drives it:
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

function Methods.WaitForChild(self, name)
	local child = self:FindFirstChild(name)
	if not child then
		error(`smoke: {self:GetFullName()} has no child {name}`, 2)
	end
	return child
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

function Methods.FireClient() end
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

local SMOKE = { boots = {}, stops = {}, closed = {}, behave = {}, task = ownedTask }
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
	end
end

local DateTimeMock
local Enum = {
	CreatorType = { User = "CreatorType.User", Group = "CreatorType.Group" },
	MessageType = { MessageOutput = 1, MessageInfo = 2, MessageWarning = 3, MessageError = 4 },
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
	local store = { data = data, failGets = {} } -- failGets[key] = n: the next n reads of key throw
	function store:GetAsync(key)
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
-- 0.3.2: MemoryStore sorted maps (heartbeat, reports): data[key] = { value, ttl }; `failWrites` makes SetAsync throw.
local sortedMaps = {}
local function sortedMap(name: string)
	local existing = sortedMaps[name]
	if existing then
		return existing
	end
	local map = { data = {}, writes = 0, failWrites = 0 }
	function map:SetAsync(key, value, ttl)
		assert(type(key) == "string" and #key <= 128, "bad sorted map key")
		assert(type(ttl) == "number" and ttl > 0, "SetAsync needs an expiration")
		if self.failWrites > 0 then
			self.failWrites -= 1
			error("MemoryStore throttled (smoke)")
		end
		self.writes += 1
		self.data[key] = { value = deepCopy(value), ttl = ttl }
		return true
	end
	function map:RemoveAsync(key)
		self.data[key] = nil
	end
	sortedMaps[name] = map
	return map
end
local topics = {}
local subscribeFailures = {} -- topic -> number of SubscribeAsync calls that fail first
local assets = {}
local assetVersions = {} -- version -> asset id
local closeCallbacks = {} -- game:BindToClose

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
	LogService = { MessageOut = signal() },
	RunService = {
		IsStudio = function()
			return table.find(process.args, "--studio-local") ~= nil
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
	},
	Players = {
		MaxPlayers = 10,
		PlayerAdded = signal(),
		PlayerRemoving = signal(),
		GetPlayers = function()
			return {}
		end,
		GetPlayerByUserId = function()
			return nil
		end,
	},
	MessagingService = {
		SubscribeAsync = function(_, topic, fn)
			if (subscribeFailures[topic] or 0) > 0 then
				subscribeFailures[topic] -= 1
				error("MessagingService unavailable (smoke)")
			end
			topics[topic] = fn
			return { Disconnect = function() end }
		end,
	},
	ScriptContext = { Error = signal(true) },
	ConfigService = {
		GetConfigAsync = function()
			error("ConfigService unavailable (smoke)")
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
			return false
		end,
	},
	GroupService = {
		GetGroupsAsync = function()
			return {}
		end,
	},
	TeleportService = {},
	InsertService = {
		LoadAsset = function(_, id)
			local asset = assets[id] or error(`smoke: asset {id} not found`)
			asset.loads = (asset.loads or 0) + 1
			if asset.failLoads > 0 then
				asset.failLoads -= 1
				error("HTTP 500 (smoke)")
			end
			local container = newInstance("Model", "Model")
			asset.build().Parent = container
			return container
		end,
		GetLatestAssetVersionAsync = function(_, id)
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
for _, name in { "ReplicatedStorage", "ServerScriptService", "ServerStorage", "TextChatService" } do
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
for name, file in { Kernel = "Kernel.server.luau", Api = "Api.luau", Access = "Access.luau", Logs = "Logs.luau", Registry = "Registry.luau", Reports = "Reports.luau", Transport = "Transport.luau", Signing = "Signing.luau" } do
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
local CLIENT_MODE = table.find(process.args, "--client") ~= nil
local HEALTH_MODE = table.find(process.args, "--health") ~= nil
local HEALTH_PROD_MODE = table.find(process.args, "--health-prod") ~= nil
local LKG_BOOT_MODE = table.find(process.args, "--lkg-boot") ~= nil
if DEV_MODE or VIP_MODE or HEALTH_MODE then
	GAME_ROOT_PROPS.PrivateServerId = "ps-smoke"
	GAME_ROOT_PROPS.PrivateServerOwnerId = if VIP_MODE then 777 else 0
	dataStore.data["private/ps-smoke"] = { branch = "dev", setBy = 1, setAt = "2026-10-04T00:00:00Z", code = if HEALTH_MODE then "smoke-access-code" else nil }
end
if HEALTH_MODE then
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
		table.insert(SMOKE.boots, kernel.artifact.id)
		if kernel.onClose then
			kernel:onClose(function()
				table.insert(SMOKE.closed, kernel.artifact.id)
			end)
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

local function payload(artifactId: string, channel: string?, extraScript: boolean?)
	return function()
		local model = newInstance("Model", "TypeTorchPayload")
		model:SetAttribute("ArtifactId", artifactId)
		model:SetAttribute("Channel", channel)
		model:SetAttribute("Commit", string.sub(artifactId, 1, 7))
		model:SetAttribute("KernelApi", 1)
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

addAsset(1001, payload("aaaaaaa-111111", "prod"))
addAsset(1002, payload("bbbbbbb-222222", "prod"))
addAsset(1003, payload("ccccccc-333333", "dev"))
addAsset(1004, payload("ddddddd-444444", "prod"))
addAsset(1005, payload("eeeeeee-555555", "prod", true))
addAsset(1006, payload("fffffff-666666", "prod"), 2)
-- 0.3.2 health tests (behaviors set per mode): G errors after ready, H's onStart fails, I fails to start.
addAsset(1007, payload("ggggggg-777777", "prod"))
addAsset(1008, payload("hhhhhhh-888888", "prod"))
addAsset(1009, payload("iiiiiii-999999", "prod"))

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

-- Boot ---------------------------------------------------------------------------------------------------------------

local Constants = requireInstance(shared.Constants)
Constants.PUBLIC_JITTER_SECONDS = 0.05
Constants.CONFIG_BOOT_WAIT = 0.1
Constants.LOAD_RETRY_DELAYS = { 0.1, 0.1, 0.1 }
Constants.STOP_DEADLINE = 0.3
Constants.SUBSCRIBE_RETRY_DELAYS = { 0.05 }
Constants.PRIVATE_READ_RETRY_DELAYS = { 0.05, 0.05, 0.05 }
Constants.WRITE_RETRY_DELAYS = { 0.05, 0.05 }
Constants.HEARTBEAT_MIN_GAP = 0.1
Constants.CLOSE_DEADLINE = 1
if HEALTH_MODE or HEALTH_PROD_MODE or LKG_BOOT_MODE then
	Constants.HEALTH_WINDOW = 1.5
	Constants.HEARTBEAT_SECONDS = 0.4
	Constants.HEARTBEAT_JITTER = 0.05
	Constants.POLL_SECONDS = 0.3
end
if BLIND_MODE then
	Constants.POLL_SECONDS = 0.3 -- the forged newer head must meet several polls
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
	for _, line in output do
		if line.kind == "warn" and string.find(line.text, "swap failed", 1, true) and not string.find(line.text, "eeeeeee", 1, true) and not string.find(line.text, "1006", 1, true) and not string.find(line.text, "ccccccc", 1, true) and not string.find(line.text, "Sneaky", 1, true) then
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
	local mode = if FALLBACK_MODE then "--fallback" elseif DEV_MODE then "--dev" elseif VIP_MODE then "--vip" elseif BOOTSTRAP_ONLY_MODE then "--bootstrap-only" elseif BOOTSTRAP_MODE then "--bootstrap" elseif BLIND_MODE then "--blind" elseif EMPTY_MODE then "--empty" elseif STUDIO_MODE then "--studio-local" elseif HEALTH_MODE then "--health" elseif HEALTH_PROD_MODE then "--health-prod" elseif LKG_BOOT_MODE then "--lkg-boot" elseif CLIENT_MODE then "--client" else "public server"
	print(`{passes} passed, {failures} failed ({mode})`)
	process.exit(if failures == 0 then 0 else 1)
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
	services.Players.LocalPlayer = localPlayer
	services.ReplicatedFirst = newInstance("ReplicatedFirst")
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
					return { boot = function(kernel) SMOKE.clientKernel = kernel return function() end end }]]
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
	runScript(clientScript, function(err)
		table.insert(kernelErrors, err)
	end)
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
	task.wait(0.1)
	root:SetAttribute("ActiveGeneration", "aaaaaaa-111111#1")
	check("client: a generation that fails once starts on the retry (fresh copy of its tree)", waitFor("client A", function()
		local report = lastReport()
		return report ~= nil and report.g == "aaaaaaa-111111#1" and report.ok == true and report.retried == true and typeof(report.ms) == "number"
	end) and SMOKE.clientKernel ~= nil and localPlayer.PlayerScripts:FindFirstChild("TypeTorchRetry") ~= nil)
	root:SetAttribute("ActiveGeneration", "bbbbbbb-222222#2")
	check("client: a generation that keeps failing is reported failed after its one retry", waitFor("client B", function()
		local report = lastReport()
		return report ~= nil and report.g == "bbbbbbb-222222#2" and report.ok == false and report.retried == true and string.find(report.e or "", "client boot boom", 1, true) ~= nil
	end) and SMOKE.clientFailures["bbbbbbb-222222#2"] == 3)
	check("client: the retry copy of the stopped generation was destroyed", #localPlayer.PlayerScripts.TypeTorchRetry:GetChildren() == 0)
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
	check("studio: no heartbeat or deploy reports (0.3.2: Studio writes nothing)", sortedMaps.TypeTorchServers == nil and sortedMaps.TypeTorchReports == nil and SMOKE.kernel:heartbeat().enabled == false)
	finish()
end

-- 0.3.2 helpers: this server's report of a seq, its heartbeat entry (value, ttl), and the running Entry clone.
local JOB = GAME_ROOT_PROPS.JobId
local function reportOf(seq: number)
	local map = sortedMaps.TypeTorchReports
	local item = map and map.data[string.format("%010d/%s", seq, JOB)]
	return if item then item.value else nil, if item then item.ttl else nil
end
local function heartbeatOf()
	local map = sortedMaps.TypeTorchServers
	local item = map and map.data[JOB]
	return if item then item.value else nil, if item then item.ttl else nil
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

	-- P-O1: reports and the heartbeat, written by the kernel.
	check("P-O1: a booted report for seq 5", waitFor("booted report", function()
		return reported(5, "booted")
	end))
	local booted, bootedTtl = reportOf(5)
	check(
		"P-O1: report fields {s,b,a,j,r,d,t,g,k,p}, TTL 7 days",
		booted ~= nil and booted.s == 5 and booted.b == "dev" and booted.a == "ddddddd-444444" and booted.j == JOB and typeof(booted.t) == "number" and booted.g == 1 and booted.k == Constants.KERNEL_VERSION and booted.p == 0 and typeof(booted.d) == "number" and booted.e == nil and bootedTtl == 7 * 24 * 3600
	)
	check("P-O1: the kernel writes the heartbeat", waitFor("heartbeat", function()
		return heartbeatOf() ~= nil
	end))
	local hb, hbTtl = heartbeatOf()
	check(
		"P-O1: heartbeat {t,b,c,a,n,m,s,u,p,k,v} plus q, g, h, sv = 2, TTL 150 s",
		hb ~= nil and hb.t == "reserved" and hb.b == "dev" and hb.c == status().channel and hb.c ~= nil and hb.a == "ddddddd-444444" and hb.n == 0 and hb.m == 10 and typeof(hb.s) == "number" and typeof(hb.u) == "number" and hb.p == 42 and hb.k == "smoke-access-code" and hb.x == nil and hb.v == Constants.KERNEL_VERSION and hb.q == 5 and hb.g == 1 and hb.h == "ok" and hb.sv == 2 and hbTtl == 150
	)
	check("api: heartbeat() and accessCode() (from the private record)", SMOKE.kernel:heartbeat().enabled == true and SMOKE.kernel:accessCode() == "smoke-access-code")

	-- S-M2: the registry never loaded (ConfigService is down here), so revocations are unknown.
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
	check("P-O1: the heartbeat says degraded after the rollback", waitFor("degraded", function()
		local entry = heartbeatOf()
		return entry ~= nil and entry.h == "degraded" and entry.a == "bbbbbbb-222222" and entry.e ~= nil
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

	-- P-O1: a report write that fails is retried; a good deploy brings the heartbeat back to ok.
	sortedMaps.TypeTorchReports.failWrites = 1
	devDeploy(1004, "ddddddd-444444", 25)
	check("P-O1: a failed report write is retried", waitFor("D", function()
		return running() == "ddddddd-444444" and reported(25, "swapped")
	end) and SMOKE.kernel:heartbeat().reports.failures >= 1)
	check("P-O1: the heartbeat is ok again after a good deploy", waitFor("ok", function()
		local hbNow = heartbeatOf()
		return hbNow ~= nil and hbNow.h == "ok" and hbNow.q == 25 and hbNow.a == "ddddddd-444444"
	end))

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
	check("onClose: the generation's handler runs and the heartbeat entry is removed", waitFor("close", function()
		return closeDone
	end) and table.find(SMOKE.closed, "ddddddd-444444") ~= nil and heartbeatOf() == nil)
	devDeploy(1002, "bbbbbbb-222222", 26)
	task.wait(0.4)
	check("onClose: no swaps after BindToClose", running() == "ddddddd-444444" and heartbeatOf() == nil)
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

check("status: signed only, key asset mode, build stamped", s.signedOnly == true and s.signing.mode == "key asset" and s.kernelBuild == "abc1234" and s.kernelVersion == "0.3.2")
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
