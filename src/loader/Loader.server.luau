--!nonstrict
-- TypeTorch loader (kernel 0.4.0; plans/22 "The kernel as an uploaded asset"): ServerScriptService.TypeTorchLoader,
-- baked into the place once (`typetorch kernel install-loader`). At boot it installs the kernel the signed settings
-- record points at (a group-owned Model asset VERSION), else the fallback kernel baked into the place
-- (ServerStorage.TypeTorchKernelBaked). The decisions live in the child ModuleScript `Core` (LoaderCore.luau, tested
-- under Lune); this script holds the Roblox side: the hold, the reads, LoadAssetVersion and the install.
--
-- Attributes on this script (stamped by install-loader; the place's trust roots, never in the asset):
--   KeyAssetId, FallbackPublicKey, BootstrapHeads   the kernel's trust roots (copied onto the installed kernel folder)
--   BootScreen, KernelScreen, OverrideOwnerOnly     game settings kernel deploy used to stamp (copied as well)
--   MinKernelVersion                                a pointer to an older kernel is refused (old signed records)
-- Written by the loader at boot (read by the kernel and the dev menu):
--   KernelSource      "asset" | "baked" | "direct" | "none"
--   KernelLoadError   why the asset wasn't used ("kernel asset <id> version <v>: moderated or unavailable (...)")
--   KernelLoadClass   "unavailable" | "timeout" | "settings" | "unsigned" | "invalid" | "error"
--   LoaderSeconds     how long the loader took

local startedAt = os.clock()
local Players = game:GetService("Players")

-- 1. THE HOLD, before anything yields (the kernel's first line does the same; its Fallback.hold takes this one over
-- through the Players attribute TypeTorchLoaderHeld). A game that opted out (TypeTorchHoldCharacters = false), or
-- whose CharacterAutoLoads is already off, is left alone.
local held = false
if Players:GetAttribute("TypeTorchHoldCharacters") ~= false and Players.CharacterAutoLoads == true then
	Players.CharacterAutoLoads = false
	Players:SetAttribute("TypeTorchLoaderHeld", true)
	held = true
end

local Core = require(script:WaitForChild("Core"))
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local loader = script
local DATASTORE = "TypeTorch"
local SETTINGS_KEY = "settings"
-- A copy of the client kernel for players who joined before it was installed: ReplicatedFirst replicates once, at join
-- (kernel 0.3.9), so the loader's client script clones this one into their PlayerScripts.
local LATE_CLIENT = "TypeTorchKernelClientLate"

local function serverType(): string
	if game.PrivateServerId ~= "" then
		return if game.PrivateServerOwnerId ~= 0 then "private" else "reserved"
	end
	return "public"
end

local bakedRoot = ServerStorage:FindFirstChild(Core.BAKED)

-- The baked kernel's Signing (and its Ed25519 vendor): the place's own copy verifies the pointer.
local Signing
do
	local service = bakedRoot and bakedRoot:FindFirstChild(Core.KERNEL_SLOT.service)
	local kernelFolder = service and service:FindFirstChild(Core.KERNEL_SLOT.name)
	local module = kernelFolder and kernelFolder:FindFirstChild("Signing")
	local ok, value = false, "no baked kernel"
	if module then
		ok, value = pcall(require, module)
	end
	if ok then
		Signing = value
	else
		warn(`[TypeTorch] loader: the baked kernel's Signing can't be used ({tostring(value)}): the asset kernel can't be verified`)
		Signing = {
			refresh = function()
				return false, false
			end,
			loaded = function()
				return false
			end,
			settingsCanonical = function()
				return nil
			end,
			signatures = function()
				return nil
			end,
		}
	end
end

-- The key asset loader, as the kernel does it (S13: the version lookup sees a new version within about 1 s).
local function loadKeyAsset(assetId: number, knownVersion: number?)
	local versionOk, version = pcall(InsertService.GetLatestAssetVersionAsync, InsertService, assetId)
	if versionOk and typeof(version) == "number" then
		if knownVersion ~= nil and version == knownVersion then
			return { unchanged = true, version = version }
		end
	else
		version = nil
	end
	local ok, container = false, nil
	if version then
		ok, container = pcall(InsertService.LoadAssetVersion, InsertService, version)
	end
	if not ok then
		version = nil
		ok, container = pcall(InsertService.LoadAsset, InsertService, assetId)
	end
	if not ok then
		error(tostring(container), 0)
	end
	local publicKeys, revokedKeys = nil, ""
	local candidates = container:GetDescendants()
	table.insert(candidates, 1, container)
	for _, instance in candidates do
		local value = instance:GetAttribute("PublicKeys")
		if typeof(value) == "string" then
			publicKeys = value
			local revoked = instance:GetAttribute("RevokedKeys")
			revokedKeys = if typeof(revoked) == "string" then revoked else ""
			break
		end
	end
	container:Destroy()
	return { publicKeys = publicKeys, revokedKeys = revokedKeys, version = version }
end

if Signing.init then
	Signing.init(loader, function(text)
		return HttpService:JSONDecode(text)
	end)
	Signing.configure({ now = os.clock, unixNow = os.time, warn = warn, print = print, loadKeys = loadKeyAsset })
end

local store = nil
local function getStore()
	store = store or DataStoreService:GetDataStore(DATASTORE)
	return store
end

-- Puts a kernel's three slots in place (a clone of the baked one; the asset's own instances), stamps the trust roots
-- and the loader's findings on the kernel folder, enables the client script, then the server kernel.
local function install(source: string, root, pointer, info)
	local placed = {}
	for _, slot in Core.SLOTS do
		local holder = root:FindFirstChild(slot.service)
		local instance = holder and holder:FindFirstChild(slot.name)
		if instance == nil then
			return false, `no {slot.service}.{slot.name}`
		end
		placed[slot.name] = if source == "baked" then instance:Clone() else instance
	end
	local kernelFolder = placed[Core.KERNEL_SLOT.name]
	for _, name in Core.TRUST_ROOTS do
		kernelFolder:SetAttribute(name, loader:GetAttribute(name))
	end
	kernelFolder:SetAttribute("KernelSource", source)
	kernelFolder:SetAttribute("BootStartedAt", startedAt)
	kernelFolder:SetAttribute("KernelLoadError", if info then info.error else nil)
	kernelFolder:SetAttribute("KernelLoadClass", if info then info.class else nil)
	kernelFolder:SetAttribute("KernelChannel", if info then info.channel else nil)
	if pointer then
		kernelFolder:SetAttribute("KernelAssetId", pointer.asset)
		kernelFolder:SetAttribute("KernelAssetVersionId", pointer.versionId)
	end
	for _, slot in Core.SLOTS do
		placed[slot.name].Parent = game:GetService(slot.service)
	end
	-- The client: enabled for players who join from now on; a copy for the ones already here (LoaderClient).
	local client = placed["TypeTorchKernelClient"]
	local late = client:Clone()
	late.Name = LATE_CLIENT
	late.Disabled = true
	client.Disabled = false
	local oldLate = ReplicatedStorage:FindFirstChild(LATE_CLIENT)
	if oldLate then
		oldLate:Destroy()
	end
	late.Parent = ReplicatedStorage
	-- The server kernel last: it requires the shared slot and stamps the client script.
	local main = kernelFolder:FindFirstChild(Core.KERNEL_SCRIPT)
	if main == nil then
		return false, `the kernel folder has no {Core.KERNEL_SCRIPT} script`
	end
	main.Disabled = false
	return true, nil
end

local studio = RunService:IsStudio()
local devFolder = ServerStorage:FindFirstChild("TypeTorchDev")
local result = Core.run({
	now = os.clock,
	spawn = task.spawn,
	wait = task.wait,
	log = warn,
	studio = studio,
	useAssetInStudio = devFolder ~= nil and devFolder:GetAttribute("UseAssetKernel") == true,
	serverType = serverType(),
	privateServerId = game.PrivateServerId,
	minKernelVersion = loader:GetAttribute("MinKernelVersion"),
	signing = Signing,
	decode = function(text)
		return HttpService:JSONDecode(text)
	end,
	directKernel = function()
		return ServerScriptService:FindFirstChild(Core.KERNEL_SLOT.name) ~= nil
	end,
	baked = function()
		return bakedRoot
	end,
	readSettings = function()
		return getStore():GetAsync(SETTINGS_KEY)
	end,
	readPrivate = function(id)
		return getStore():GetAsync("private/" .. id)
	end,
	loadAssetVersion = function(versionId)
		return InsertService:LoadAssetVersion(versionId)
	end,
	install = install,
})

loader:SetAttribute("KernelSource", result.source)
loader:SetAttribute("KernelLoadError", result.error)
loader:SetAttribute("KernelLoadClass", result.class)
loader:SetAttribute("LoaderSeconds", math.floor((result.seconds or 0) * 1000 + 0.5) / 1000)
local summary = table.concat(result.steps, " | ")
if result.source == "asset" then
	print(`[TypeTorch] loader: kernel {tostring(result.pointer and result.pointer.version)} from asset {tostring(result.pointer and result.pointer.asset)} version {tostring(result.pointer and result.pointer.versionId)} ({result.channel}, {result.by}) in {string.format("%.2f", result.seconds)} s`)
elseif result.source == "baked" then
	if result.error then
		warn(`[TypeTorch] loader: the BAKED fallback kernel runs: {result.error} ({summary})`)
	else
		print(`[TypeTorch] loader: the baked kernel runs (Studio)`)
	end
elseif result.source == "direct" then
	print("[TypeTorch] loader: a kernel is installed directly in the place; the loader stands down")
else
	-- Nothing can run: give the players their characters back rather than holding them forever.
	warn(`[TypeTorch] loader: NO KERNEL RUNS on this server: {tostring(result.error)} ({summary})`)
	if held then
		Players.CharacterAutoLoads = true
		Players:SetAttribute("TypeTorchLoaderHeld", nil)
		for _, player in Players:GetPlayers() do
			if player.Character == nil then
				task.spawn(player.LoadCharacter, player)
			end
		end
	end
end
