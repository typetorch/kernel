-- Smoke test for the whole server kernel (from kernel/): `lune run scripts/smoke-kernel.luau`, then again with
-- `--fallback` (the key asset never loads), `--dev` (a reserved dev-branch server), `--vip` (a non-dev's private server),
-- `--bootstrap`, `--bootstrap-only` (BootstrapHeads), `--blind` (the boot fail-safe) and `--empty` (nothing usable).
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

-- Instance emulator ------------------------------------------------------------------------------------------------

local internals = setmetatable({}, { __mode = "k" })
local Methods = {}
local instanceMeta = {}
local onScriptEnabled: (any) -> () = function() end
local GAME_ROOT = nil -- the DataModel stand-in (set below)

local function signal()
	local handlers = {}
	local object = {}
	function object:Connect(fn)
		local entry = { fn = fn, on = true }
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
				task.spawn(entry.fn, ...)
			end
		end
	end
	return object
end

local SIGNALS = { Event = true, OnServerEvent = true, Triggered = true }

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
	internals[self].attributes[name] = value
end

function Methods.GetAttribute(self, name)
	return internals[self].attributes[name]
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

local SMOKE = { boots = {}, stops = {} }
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
		task = task,
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
onScriptEnabled = function(scriptInstance)
	task.spawn(function()
		local ok, err = pcall(runSource, scriptInstance)
		if not ok then
			table.insert(scriptErrors, `{scriptInstance:GetFullName()}: {err}`)
		end
	end)
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
	local store = { data = data }
	function store:GetAsync(key)
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
local topics = {}
local assets = {}
local assetVersions = {} -- version -> asset id

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
			return false
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
			topics[topic] = fn
			return { Disconnect = function() end }
		end,
	},
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
game = setmetatable({}, {
	__index = function(_, key)
		if key == "GetService" then
			return function(_, name)
				return services[name] or error(`smoke: no service {name}`)
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
for name, file in { Kernel = "Kernel.server.luau", Api = "Api.luau", Access = "Access.luau", Logs = "Logs.luau", Registry = "Registry.luau", Transport = "Transport.luau", Signing = "Signing.luau" } do
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
if DEV_MODE or VIP_MODE then
	GAME_ROOT_PROPS.PrivateServerId = "ps-smoke"
	GAME_ROOT_PROPS.PrivateServerOwnerId = if VIP_MODE then 777 else 0
	dataStore.data["private/ps-smoke"] = { branch = "dev", setBy = 1, setAt = "2026-10-04T00:00:00Z" }
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

local BOOT_SOURCE = [[
return {
	boot = function(kernel)
		SMOKE.kernel = kernel
		table.insert(SMOKE.boots, kernel.artifact.id)
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
end

-- Boot ---------------------------------------------------------------------------------------------------------------

local Constants = requireInstance(shared.Constants)
Constants.PUBLIC_JITTER_SECONDS = 0.05
Constants.CONFIG_BOOT_WAIT = 0.1
Constants.LOAD_RETRY_DELAYS = { 0.1, 0.1, 0.1 }
Constants.STOP_DEADLINE = 0.3
if BLIND_MODE then
	Constants.POLL_SECONDS = 0.3 -- the forged newer head must meet several polls
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
task.spawn(function()
	local ok, err = pcall(runSource, kernelFolder.Kernel)
	if not ok then
		table.insert(kernelErrors, tostring(err))
	end
end)

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

local function finish()
	check("no kernel or script errors", #kernelErrors == 0 and #scriptErrors == 0)
	for _, line in output do
		if line.kind == "warn" and string.find(line.text, "swap failed", 1, true) and not string.find(line.text, "eeeeeee", 1, true) and not string.find(line.text, "1006", 1, true) and not string.find(line.text, "ccccccc", 1, true) then
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
	local mode = if FALLBACK_MODE then "--fallback" elseif DEV_MODE then "--dev" elseif VIP_MODE then "--vip" elseif BOOTSTRAP_ONLY_MODE then "--bootstrap-only" elseif BOOTSTRAP_MODE then "--bootstrap" elseif BLIND_MODE then "--blind" elseif EMPTY_MODE then "--empty" else "public server"
	print(`{passes} passed, {failures} failed ({mode})`)
	process.exit(if failures == 0 then 0 else 1)
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
	check("blind: event booted_unverified", (function()
		for _, event in (dataStore.data.events or { list = {} }).list do
			if event.action == "booted_unverified" and event.assetId == 1001 then
				return true
			end
		end
		return false
	end)())
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

check("status: signed only, key asset mode, build stamped", s.signedOnly == true and s.signing.mode == "key asset" and s.kernelBuild == "abc1234" and s.kernelVersion == "0.3.0")
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
