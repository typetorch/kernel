--!nocheck
-- The loader's decisions (src/loader/LoaderCore.luau; kernel 0.4.1, plans/22): `lune run scripts/test-loader.luau`.
-- Signed settings records come from scripts/loader-vectors.json, made with node:crypto from the PUBLIC test keys of
-- scripts/test-signing.luau (never real keys) and checked with the real Signing.luau. Packages are Lune instances.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Core = require("../src/loader/LoaderCore")
local Signing = require("../src/server/Signing")

local VECTORS = serde.decode("json", fs.readFile("scripts/loader-vectors.json"))
local MAIN, FALLBACK = VECTORS.keys.main, VECTORS.keys.fallback
local decode = function(text)
	return serde.decode("json", text)
end

local passed, failed = 0, 0
local function check(name: string, condition: boolean, detail: any?)
	if condition then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}{if detail ~= nil then `: {tostring(detail)}` else ""}`)
	end
end

-- Signing, set up like the loader does (attributes on the loader Script), with a fake key asset.
local keyAssetLoads = 0
local function setupSigning(keyAssetLoads_ok: boolean)
	Signing.init({
		GetAttribute = function(_, name)
			if name == "KeyAssetId" then
				return 4242
			elseif name == "FallbackPublicKey" then
				return FALLBACK
			end
			return nil
		end,
	}, decode)
	local now = 0
	Signing.configure({
		now = function()
			now += 1000 -- every refresh passes the rate limit
			return now
		end,
		unixNow = os.time,
		warn = function() end,
		print = function() end,
		loadKeys = function()
			keyAssetLoads += 1
			if not keyAssetLoads_ok then
				error("Asset is not approved", 0)
			end
			return { publicKeys = MAIN, revokedKeys = "", version = 1 }
		end,
	})
end

-- Pure parts ---------------------------------------------------------------------------------------------------------
check("compareVersions", Core.compareVersions("0.4.0", "0.3.12") == 1 and Core.compareVersions("0.4.0", "0.4.0") == 0 and Core.compareVersions("0.3.9", "0.4") == -1)
check("classify moderated", Core.classify("Asset 123 is not approved (moderated)") == "unavailable")
check("classify 403", Core.classify("HTTP 403 (Forbidden)") == "unavailable")
check("classify timeout", Core.classify("timed out (the loader's budget)") == "timeout")
check("classify other", Core.classify("something odd") == "error")
local body = decode(VECTORS.both.body)
check("branchChannel", Core.branchChannel(body, "prod") == "prod" and Core.branchChannel(body, "dev") == "dev" and Core.branchChannel(body, "feature-x") == "dev")
local p, channel = Core.pickPointer(body, { serverType = "public" })
check("public -> prod", channel == "prod" and p.versionId == 777001)
p, channel = Core.pickPointer(body, { serverType = "private", privateBranch = "dev" })
check("player-owned private -> prod", channel == "prod" and p.versionId == 777001)
p, channel = Core.pickPointer(body, { serverType = "reserved", privateBranch = "feature-x" })
check("reserved dev branch -> dev", channel == "dev" and p.versionId == 777002)
p, channel = Core.pickPointer(body, { serverType = "reserved", privateBranch = "prod" })
check("reserved prod branch -> prod", channel == "prod")
p, channel = Core.pickPointer({ kernel = { prod = body.kernel.prod } }, { serverType = "reserved", privateBranch = "dev" })
check("no dev pointer -> prod", channel == "prod" and p.versionId == 777001)
p, channel = Core.pickPointer({ defaultBranch = "prod" }, { serverType = "public" })
check("no kernel pointer", p == nil and string.find(channel, "no kernel pointer", 1, true) ~= nil)
check("validate ok", (Core.validatePointer(body.kernel.prod, "0.4.0")))
local okMin, whyMin = Core.validatePointer(body.kernel.prod, "0.5.0")
check("MinKernelVersion", not okMin and string.find(whyMin, "MinKernelVersion", 1, true) ~= nil)
local okApi, whyApi = Core.validatePointer({ versionId = 1, hash = string.rep("a", 64), loaderApi = 2 }, nil)
check("loader api", not okApi and string.find(whyApi, "install%-loader") ~= nil, whyApi)
check("no versionId", not (Core.validatePointer({ hash = string.rep("a", 64) }, nil)))

-- The record: sigF always, sig as well once the key asset loaded ---------------------------------------------------------
setupSigning(false)
Signing.refresh("boot")
check("key asset not loaded", not Signing.loaded())
local b, by = Core.verifyRecord(VECTORS.both, Signing, decode)
check("not loaded: both -> sigF", b ~= nil and by == "sigF", by)
b, by = Core.verifyRecord(VECTORS.sigFOnly, Signing, decode)
check("not loaded: sigF only -> ok", b ~= nil, by)
b, by = Core.verifyRecord(VECTORS.sigOnly, Signing, decode)
check("not loaded: sig only -> refused (needs sigF)", b == nil and string.find(by, "sigF", 1, true) ~= nil, by)
b, by = Core.verifyRecord(VECTORS.wrongF, Signing, decode)
check("wrong sigF -> refused", b == nil, by)
setupSigning(true)
Signing.refresh("boot")
check("key asset loaded", Signing.loaded())
b, by = Core.verifyRecord(VECTORS.both, Signing, decode)
check("loaded: both -> sig+sigF", b ~= nil and by == "sig+sigF", by)
b, by = Core.verifyRecord(VECTORS.sigFOnly, Signing, decode)
check("loaded: sigF only -> refused (sig needed)", b == nil and string.find(by, "matches no key", 1, true) ~= nil, by)
b, by = Core.verifyRecord({ seq = 1, at = "x", body = "{}" }, Signing, decode)
check("unsigned -> refused", b == nil and by == "the settings record is unsigned", by)
local tampered = table.clone(VECTORS.both)
tampered.body = string.gsub(tampered.body, "777001", "777009")
b, by = Core.verifyRecord(tampered, Signing, decode)
check("a changed pointer -> refused", b == nil, by)

-- Packages -----------------------------------------------------------------------------------------------------------
local Instance = roblox.Instance
local function make(className, name, parent, props)
	local instance = Instance.new(className)
	instance.Name = name
	for key, value in props or {} do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end
local function package(hash, options)
	options = options or {}
	local root = make("Model", "TypeTorchKernelPackage")
	root:SetAttribute("KernelHash", hash)
	root:SetAttribute("KernelVersion", "0.4.0")
	local sss = make("Folder", "ServerScriptService", root)
	local kernel = make("Folder", "TypeTorchKernel", sss)
	make("Script", "Kernel", kernel, { Disabled = not options.enabled })
	make("ModuleScript", "Signing", kernel)
	make("Script", "Entry", kernel, { Disabled = true })
	if options.trustRoot then
		kernel:SetAttribute("FallbackPublicKey", FALLBACK)
	end
	if not options.noShared then
		make("ModuleScript", "Constants", make("Folder", "TypeTorchKernelShared", make("Folder", "ReplicatedStorage", root)))
	end
	make("LocalScript", "TypeTorchKernelClient", make("Folder", "ReplicatedFirst", root), { Disabled = true })
	if options.extra then
		make("Part", "Brick", kernel)
	end
	return root
end
local HASH = VECTORS.hashes.prod
local pointer = body.kernel.prod
check("package ok", #Core.checkPackage(package(HASH), pointer) == 0, table.concat(Core.checkPackage(package(HASH), pointer), "; "))
check("package hash", string.find(table.concat(Core.checkPackage(package("x"), pointer), ";"), "KernelHash", 1, true) ~= nil)
check("package missing slot", string.find(table.concat(Core.checkPackage(package(HASH, { noShared = true }), pointer), ";"), "TypeTorchKernelShared", 1, true) ~= nil)
check("package enabled script", string.find(table.concat(Core.checkPackage(package(HASH, { enabled = true }), pointer), ";"), "not disabled", 1, true) ~= nil)
check("package stray class", string.find(table.concat(Core.checkPackage(package(HASH, { extra = true }), pointer), ";"), "holds a Part", 1, true) ~= nil)
check("package trust root", string.find(table.concat(Core.checkPackage(package(HASH, { trustRoot = true }), pointer), ";"), "trust root", 1, true) ~= nil)
check("package not a model", #Core.checkPackage(Instance.new("Folder"), pointer) == 1)
local container = Instance.new("Model")
package(HASH).Parent = container
check("unwrap a container", Core.unwrap(container).Name == "TypeTorchKernelPackage")

-- Core.run with fake deps ---------------------------------------------------------------------------------------------
local function deps(overrides)
	local installs = {}
	local d = {
		now = os.clock,
		spawn = task.spawn,
		wait = task.wait,
		log = function() end,
		budget = 0.5,
		studio = false,
		serverType = "public",
		privateServerId = "",
		signing = Signing,
		decode = decode,
		directKernel = function()
			return false
		end,
		baked = function()
			return "BAKED"
		end,
		readSettings = function()
			return VECTORS.both
		end,
		readPrivate = function()
			return nil
		end,
		loadAssetVersion = function(versionId)
			local c = Instance.new("Model")
			package(if versionId == 777002 then VECTORS.hashes.dev else HASH).Parent = c
			return c
		end,
		install = function(source, root, pointerArg, info)
			table.insert(installs, { source = source, root = root, pointer = pointerArg, info = info })
			return true
		end,
	}
	for key, value in overrides or {} do
		d[key] = value
	end
	return d, installs
end

local d, installs = deps()
local result = Core.run(d)
check("run: asset", result.source == "asset" and #installs == 1 and installs[1].source == "asset" and installs[1].pointer.versionId == 777001, result.error)
check("run: by sig+sigF (key asset loaded)", result.by == "sig+sigF", result.by)

d, installs = deps({ readSettings = function()
	error("DataStore request was rejected", 0)
end })
result = Core.run(d)
check("run: settings error -> baked", result.source == "baked" and result.class == "settings" and installs[1].source == "baked" and installs[1].info.class == "settings", result.error)

d, installs = deps({ readSettings = function()
	return VECTORS.sigFOnly
end })
result = Core.run(d)
check("run: sigF only with the key asset loaded -> baked (unsigned)", result.source == "baked" and result.class == "unsigned", result.error)

d, installs = deps({ loadAssetVersion = function()
	error("Asset 555 version 777001 is not approved", 0)
end })
result = Core.run(d)
check("run: moderated -> baked, unavailable", result.source == "baked" and result.class == "unavailable" and string.find(result.error, "moderated or unavailable", 1, true) ~= nil and string.find(result.error, "kernel asset 555 version 777001", 1, true) ~= nil, result.error)
check("run: the error reaches install", installs[1].info.error == result.error)

d, installs = deps({ loadAssetVersion = function()
	task.wait(2)
	return nil
end })
local started = os.clock()
result = Core.run(d)
check("run: a slow asset -> baked within the budget", result.source == "baked" and result.class == "timeout" and os.clock() - started < 1.5, `{result.class} {os.clock() - started}`)

d, installs = deps({ directKernel = function()
	return true
end })
result = Core.run(d)
check("run: a direct kernel -> the loader stands down", result.source == "direct" and #installs == 0)

d, installs = deps({ studio = true })
result = Core.run(d)
check("run: Studio -> baked, no error", result.source == "baked" and result.error == nil and installs[1].source == "baked")

d, installs = deps({ serverType = "reserved", privateServerId = "abc", readPrivate = function()
	return { branch = "feature-x" }
end })
result = Core.run(d)
check("run: a reserved dev server -> the dev pointer", result.source == "asset" and result.channel == "dev" and installs[1].pointer.versionId == 777002, result.error)

d, installs = deps({ baked = function()
	return nil
end, loadAssetVersion = function()
	error("HTTP 404 (Not Found)", 0)
end })
result = Core.run(d)
check("run: no baked kernel either -> none", result.source == "none" and #installs == 0)

d, installs = deps({ minKernelVersion = "0.9.0" })
result = Core.run(d)
check("run: below MinKernelVersion -> baked (invalid)", result.source == "baked" and result.class == "invalid", result.error)

d, installs = deps({ install = function(source)
	if source == "asset" then
		return false, "boom"
	end
	return true
end })
result = Core.run(d)
check("run: a failed asset install -> baked", result.source == "baked" and result.class == "error", result.error)

d, installs = deps({ readSettings = function()
	return VECTORS.noKernel
end })
result = Core.run(d)
check("run: no pointer -> baked (settings)", result.source == "baked" and result.class == "settings", result.error)

print(`{passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
