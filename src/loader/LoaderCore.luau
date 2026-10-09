--!nonstrict
-- TypeTorch loader core (kernel 0.4.1; plans/22 "The kernel as an uploaded asset"). The decisions of the loader, with
-- every Roblox call injected (deps), so they run under Lune: scripts/test-loader.luau.
--
-- The loader (Loader.server.luau, ServerScriptService.TypeTorchLoader) runs instead of a kernel baked into the place:
--   1. the hold (characters don't spawn) and the boot clock;
--   2. in parallel, each with the budget: the signed settings record (DataStore TypeTorch / settings), the key asset
--      (the baked kernel's Signing), and for a reserved server its private record (TypeTorch / private/<id>);
--   3. the record must carry sigF (the place's FallbackPublicKey) AND, once the key asset loaded, sig: a kernel pointer
--      is stricter than other settings (plans/22: a key-asset writer alone can't change the kernel);
--   4. the pointer: settings body `kernel = { prod = {...}, dev = {...} }`; public and player-owned private servers use
--      prod, a reserved server uses dev when its stored branch is dev-channel;
--   5. InsertService:LoadAssetVersion(pointer.versionId), and the package checks (one Model, the three slots, only
--      Folders and scripts, every script disabled, KernelHash = the pointer's);
--   6. install it; on ANY failure, or past the budget, install the baked fallback kernel
--      (ServerStorage.TypeTorchKernelBaked) instead. Never an empty server.
-- A place that still has a kernel installed directly (ServerScriptService.TypeTorchKernel: an older kernel deploy, or
-- Rojo in Studio) runs that one: the loader stands down.

local Core = {}

-- The contract between the loader and the kernel package. A pointer whose `loaderApi` is above it is refused.
Core.LOADER_API = 1
-- Seconds from the loader's start until the baked kernel takes over (plans/22; inside the kernel's 15 s boot budget).
Core.BUDGET = 4
-- Where the baked fallback kernel lives (a Folder per service holding that service's slot; nothing runs there).
Core.BAKED = "TypeTorchKernelBaked"
-- The kernel slots, in install order: shared first (the kernel requires its Constants), then the client, the server.
Core.SLOTS = {
	{ service = "ReplicatedStorage", name = "TypeTorchKernelShared" },
	{ service = "ReplicatedFirst", name = "TypeTorchKernelClient" },
	{ service = "ServerScriptService", name = "TypeTorchKernel" },
}
-- The kernel folder (identity and trust roots go on it) and its main script.
Core.KERNEL_SLOT = { service = "ServerScriptService", name = "TypeTorchKernel" }
Core.KERNEL_SCRIPT = "Kernel"
-- Copied from the loader Script onto the installed kernel folder: the asset never carries trust roots.
Core.TRUST_ROOTS = { "KeyAssetId", "FallbackPublicKey", "BootstrapHeads", "BootScreen", "KernelScreen", "OverrideOwnerOnly" }
-- Players attribute: the loader turned CharacterAutoLoads off (the kernel's Fallback.hold takes the hold over).
Core.LOADER_HELD = "TypeTorchLoaderHeld"
local ALLOWED = { Folder = true, Script = true, LocalScript = true, ModuleScript = true }

-- "0.4.0" vs "0.3.12": -1, 0 or 1 (numeric parts; missing parts are 0; anything else compares as text).
function Core.compareVersions(a: string, b: string): number
	local partsA, partsB = string.split(a, "."), string.split(b, ".")
	for index = 1, math.max(#partsA, #partsB) do
		local x, y = tonumber(partsA[index] or "0"), tonumber(partsB[index] or "0")
		if x == nil or y == nil then
			local sa, sb = partsA[index] or "", partsB[index] or ""
			if sa ~= sb then
				return if sa < sb then -1 else 1
			end
		elseif x ~= y then
			return if x < y then -1 else 1
		end
	end
	return 0
end

-- What a failure was, for the fleet (plans/22 "Moderation and outages"): "unavailable" (the asset or version is
-- moderated, archived, deleted or not ours), "timeout", "settings" (no usable record), "unsigned", "invalid" (the
-- package or the pointer is wrong), "error" (anything else). The exact Roblox texts are unverified (spike K4).
function Core.classify(message: string): string
	local text = string.lower(tostring(message))
	if string.find(text, "timed out", 1, true) or string.find(text, "timeout", 1, true) or string.find(text, "budget", 1, true) then
		return "timeout"
	end
	for _, word in { "moderat", "not approved", "archived", "deleted", "not trusted", "not authorized", "unauthorized", "forbidden", "403", "404", "not found", "does not exist", "access" } do
		if string.find(text, word, 1, true) then
			return "unavailable"
		end
	end
	return "error"
end

local function wholeNumber(value): boolean
	return typeof(value) == "number" and value == value and value > 0 and value % 1 == 0 and value <= 2 ^ 53
end

-- The channel of a branch by the signed settings (kernel 0.3.9 rule): prod = the default branch or a branch the
-- settings configure prod, dev = every other branch.
function Core.branchChannel(body, branch: string): string
	local channels = if typeof(body) == "table" and typeof(body.channels) == "table" then body.channels else {}
	if channels[branch] == "prod" or channels[branch] == "dev" then
		return channels[branch]
	end
	local default = if typeof(body) == "table" and typeof(body.defaultBranch) == "string" then body.defaultBranch else "prod"
	return if branch == default then "prod" else "dev"
end

-- The pointer this server runs: (pointer, channel) or (nil, why). context = { serverType = "public" | "private" |
-- "reserved", privateBranch = string? }.
function Core.pickPointer(body, context)
	if typeof(body) ~= "table" or typeof(body.kernel) ~= "table" then
		return nil, "the settings record has no kernel pointer"
	end
	local channel = "prod"
	if context.serverType == "reserved" and typeof(context.privateBranch) == "string" and Core.branchChannel(body, context.privateBranch) == "dev" then
		channel = "dev"
	end
	local pointer = body.kernel[channel]
	if typeof(pointer) ~= "table" and channel == "dev" then
		channel, pointer = "prod", body.kernel.prod -- no dev pointer: dev servers run prod's kernel
	end
	if typeof(pointer) ~= "table" then
		return nil, `the settings record has no kernel.{channel} pointer`
	end
	return pointer, channel
end

-- The pointer's own checks: (true) or (false, why). `minVersion` = the loader's MinKernelVersion attribute.
function Core.validatePointer(pointer, minVersion: string?): (boolean, string?)
	if not wholeNumber(pointer.versionId) then
		return false, "the pointer has no versionId"
	end
	if typeof(pointer.hash) ~= "string" or #pointer.hash < 16 then
		return false, "the pointer has no kernel hash"
	end
	local api = pointer.loaderApi or 1
	if not wholeNumber(api) or api > Core.LOADER_API then
		return false, `the kernel needs loader API {tostring(api)}, this loader has {Core.LOADER_API}: install the new loader (typetorch kernel install-loader)`
	end
	if typeof(minVersion) == "string" and minVersion ~= "" then
		if typeof(pointer.version) ~= "string" or Core.compareVersions(pointer.version, minVersion) < 0 then
			return false, `kernel {tostring(pointer.version)} is below this place's MinKernelVersion {minVersion} (an old signed record?)`
		end
	end
	return true, nil
end

-- The signed settings record: (body, by) or (nil, why). The kernel pointer rule: sigF (the place's fallback key) always,
-- and sig as well once the key asset has loaded. `signing` is the baked kernel's Signing module, initialised from the
-- loader's attributes.
function Core.verifyRecord(record, signing, decode: (string) -> any)
	if typeof(record) ~= "table" then
		return nil, "no settings record"
	end
	if typeof(record.body) ~= "string" or record.seq == nil then
		return nil, "the settings record is malformed"
	end
	local canonical = signing.settingsCanonical(record.seq, record.at, record.body)
	if not canonical then
		return nil, "the settings record is malformed"
	end
	local signatures = signing.signatures(canonical, record.sig, record.sigF)
	if signatures == nil then
		return nil, "the settings record is unsigned"
	end
	if not signatures.fallback then
		return nil, "the settings record's sigF doesn't match this place's FallbackPublicKey (or it is revoked)"
	end
	if signing.loaded() and not signatures.main then
		return nil, "the settings record's sig matches no key of the key asset"
	end
	local ok, body = pcall(decode, record.body)
	if not ok or typeof(body) ~= "table" then
		return nil, "the settings body is not JSON"
	end
	return body, if signatures.main then "sig+sigF" else "sigF"
end

-- The package's problems (an empty list = fine). `root` is what LoadAssetVersion returned (a Model, or the Model inside
-- a container), already unwrapped by Core.unwrap.
function Core.checkPackage(root, pointer): { string }
	local problems = {}
	if root == nil or root.ClassName ~= "Model" then
		table.insert(problems, "the asset is not one Model")
		return problems
	end
	local hash = root:GetAttribute("KernelHash")
	if hash ~= pointer.hash then
		table.insert(problems, `the asset's KernelHash {tostring(hash)} is not the pointer's {tostring(pointer.hash)}`)
	end
	for _, slot in Core.SLOTS do
		local folder = root:FindFirstChild(slot.service)
		local instance = if folder then folder:FindFirstChild(slot.name) else nil
		if instance == nil then
			table.insert(problems, `the asset has no {slot.service}.{slot.name}`)
		end
	end
	local kernelFolder = root:FindFirstChild(Core.KERNEL_SLOT.service)
	kernelFolder = if kernelFolder then kernelFolder:FindFirstChild(Core.KERNEL_SLOT.name) else nil
	if kernelFolder and not kernelFolder:FindFirstChild(Core.KERNEL_SCRIPT) then
		table.insert(problems, `the asset's kernel folder has no {Core.KERNEL_SCRIPT} script`)
	end
	for _, descendant in root:GetDescendants() do
		if not ALLOWED[descendant.ClassName] then
			table.insert(problems, `the asset holds a {descendant.ClassName} ({descendant:GetFullName()})`)
			break
		end
		if (descendant.ClassName == "Script" or descendant.ClassName == "LocalScript") and descendant.Disabled ~= true then
			table.insert(problems, `{descendant:GetFullName()} is not disabled in the asset`)
			break
		end
	end
	for _, name in Core.TRUST_ROOTS do
		if kernelFolder and kernelFolder:GetAttribute(name) ~= nil and kernelFolder:GetAttribute(name) ~= "" then
			table.insert(problems, `the asset carries the trust root {name} (only the place may)`)
			break
		end
	end
	return problems
end

-- LoadAssetVersion returns a container Model holding the asset's root: the package root (named TypeTorchKernelPackage
-- or carrying KernelHash).
function Core.unwrap(container)
	if container == nil then
		return nil
	end
	if container:GetAttribute("KernelHash") ~= nil then
		return container
	end
	for _, child in container:GetChildren() do
		if child.ClassName == "Model" and (child:GetAttribute("KernelHash") ~= nil or child.Name == "TypeTorchKernelPackage") then
			return child
		end
	end
	return container
end

-- Runs `fn` on a new thread; returns a getter for (done, ...results).
local function background(deps, fn)
	local state = { done = false, results = nil }
	deps.spawn(function()
		local results = table.pack(pcall(fn))
		state.results = results
		state.done = true
	end)
	return state
end

-- Waits until every state is done or the deadline passes (polling; deps.wait yields).
local function waitAll(deps, states, deadline: number)
	while deps.now() < deadline do
		local all = true
		for _, state in states do
			if not state.done then
				all = false
				break
			end
		end
		if all then
			return true
		end
		deps.wait(0.05)
	end
	return false
end

local function outcome(state)
	if not state.done then
		return false, "timed out (the loader's budget)"
	end
	local results = state.results
	if not results[1] then
		return false, tostring(results[2])
	end
	return true, results[2], results[3]
end

-- The whole decision. deps: see Loader.server.luau. Returns {
--   source = "asset" | "baked" | "direct" | "none", channel?, pointer?, by?, error?, class?, seconds, steps = {...} }
-- and has installed the kernel it names (except "direct": one was installed already; "none": no baked kernel either).
function Core.run(deps)
	local startedAt = deps.now()
	local deadline = startedAt + (deps.budget or Core.BUDGET)
	local steps = {}
	local function step(text: string)
		table.insert(steps, string.format("%.2f %s", deps.now() - startedAt, text))
	end
	local result = { source = "none", steps = steps }

	if deps.directKernel() then
		result.source = "direct"
		step("a kernel is installed directly in the place: the loader stands down")
		result.seconds = deps.now() - startedAt
		return result
	end

	local function fallback(class: string, why: string)
		result.error = why
		result.class = class
		step(`fallback: {class}: {why}`)
		local baked = deps.baked()
		if baked == nil then
			result.source = "none"
			deps.log(`[TypeTorch] loader: {why}, and the place has no baked kernel (ServerStorage.{Core.BAKED}): nothing to run`)
			return
		end
		local ok, err = deps.install("baked", baked, nil, { error = why, class = class, channel = result.channel })
		if ok then
			result.source = "baked"
		else
			result.source = "none"
			result.error = `{why}; installing the baked kernel failed too: {tostring(err)}`
		end
	end

	if deps.studio and not deps.useAssetInStudio then
		fallback("studio", "Studio runs the baked kernel (ServerStorage.TypeTorchDev.UseAssetKernel = true loads the asset)")
		result.class = nil
		result.error = nil
		result.seconds = deps.now() - startedAt
		return result
	end

	-- 2. In parallel: the settings record, the key asset (Signing.refresh), the private record of a reserved server.
	local settingsState = background(deps, deps.readSettings)
	local keysState = background(deps, function()
		return deps.signing.refresh("boot")
	end)
	local privateState = if deps.serverType == "reserved" and deps.privateServerId ~= "" then background(deps, function()
		return deps.readPrivate(deps.privateServerId)
	end) else nil
	local states = { settingsState, keysState }
	if privateState then
		table.insert(states, privateState)
	end
	waitAll(deps, states, deadline)
	step(`reads done (key asset {if deps.signing.loaded() then "loaded" else "not loaded"})`)

	local okSettings, record, readError = outcome(settingsState)
	if not okSettings or record == nil then
		local why = if not okSettings then record else (readError or "no settings record")
		fallback(if string.find(tostring(why), "timed out", 1, true) then "timeout" else "settings", `the settings record: {tostring(why)}`)
		result.seconds = deps.now() - startedAt
		return result
	end
	local body, by = Core.verifyRecord(record, deps.signing, deps.decode)
	if body == nil then
		fallback("unsigned", tostring(by))
		result.seconds = deps.now() - startedAt
		return result
	end
	result.by = by
	local privateBranch = nil
	if privateState then
		local okPrivate, private = outcome(privateState)
		if okPrivate and typeof(private) == "table" and typeof(private.branch) == "string" then
			privateBranch = private.branch
		end
	end
	local pointer, channel = Core.pickPointer(body, { serverType = deps.serverType, privateBranch = privateBranch })
	if pointer == nil then
		fallback("settings", tostring(channel))
		result.seconds = deps.now() - startedAt
		return result
	end
	result.channel = channel
	result.pointer = pointer
	local valid, invalid = Core.validatePointer(pointer, deps.minKernelVersion)
	if not valid then
		fallback("invalid", tostring(invalid))
		result.seconds = deps.now() - startedAt
		return result
	end
	step(`pointer {channel}: kernel {tostring(pointer.version)} asset {tostring(pointer.asset)} version {pointer.versionId}`)

	-- 5. The asset version, within what is left of the budget.
	local loadState = background(deps, function()
		return deps.loadAssetVersion(pointer.versionId)
	end)
	waitAll(deps, { loadState }, deadline)
	local okLoad, container = outcome(loadState)
	if not okLoad or container == nil then
		local why = tostring(container or "LoadAssetVersion returned nothing")
		local class = Core.classify(why)
		fallback(class, `kernel asset {tostring(pointer.asset)} version {pointer.versionId}: {if class == "unavailable" then "moderated or unavailable" else class} ({why})`)
		result.seconds = deps.now() - startedAt
		return result
	end
	local root = Core.unwrap(container)
	local problems = Core.checkPackage(root, pointer)
	if #problems > 0 then
		fallback("invalid", `kernel asset {tostring(pointer.asset)} version {pointer.versionId}: {table.concat(problems, "; ")}`)
		result.seconds = deps.now() - startedAt
		return result
	end
	step("package checked")
	local ok, err = deps.install("asset", root, pointer, { channel = channel, by = by })
	if not ok then
		fallback("error", `installing kernel asset {tostring(pointer.asset)} version {pointer.versionId} failed: {tostring(err)}`)
		result.seconds = deps.now() - startedAt
		return result
	end
	result.source = "asset"
	step("installed")
	result.seconds = deps.now() - startedAt
	return result
end

return Core
