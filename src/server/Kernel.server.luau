--!nonstrict
-- TypeTorch kernel (server). The only TypeTorch code baked into the place; changing it needs a server restart.
-- Design: ../../../plans/01-kernel.md. Prototype and measurements: ../../../spikes/RESULTS.md.
--
-- Boot: pick this server's branch (public -> registry default, private/reserved -> its own choice), LoadAsset the
-- branch's payload, mount it side by side (server tree in ServerStorage, client tree in ReplicatedStorage), start it
-- through a cloned Entry script. Swap: soft stop (the generation's stop function), hard stop (disable its Entry),
-- start the next one; a generation that fails to start is rolled back automatically.
--
-- 0.3: prod servers (public servers, and private/reserved servers on a prod branch) load only what the owner signed:
-- deploy messages and stored heads need a valid signature (Signing.luau), the "prod" Channel attribute and a seq newer
-- than the applied one; remote pins need a signature too. Dev servers stay unsigned. See plans/01 "Signed deploys".
--
-- 0.3.1: in Studio only, ServerStorage.TypeTorchDev.Payload (a Model shaped like an uploaded payload) is mounted instead
-- of LoadAsset, a fresh clone per mount; see "Studio local payload" below and plans/01.
--
-- 0.3.2 (bad deploys are safe): a health window after ready (a failed onStart, or HEALTH_ERRORS errors from the new
-- generation's own scripts, rolls the server back; P-F1), a last-known-good chain that skips artifacts that failed
-- here (P-K3), a kernel-owned heartbeat and per-deploy reports in MemoryStore (P-O1, Reports.luau), client generation
-- reports (P-K7), onClose per generation, and every swap game code starts runs on a kernel thread (busy-flag hazard).

local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Stats = game:GetService("Stats")
local TeleportService = game:GetService("TeleportService")
local TextChatService = game:GetService("TextChatService")

local Constants = require(ReplicatedStorage:WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))
local Signing = require(script.Parent.Signing)

-- 0.3: the trust roots and the build identity, read ONCE from this folder's attributes (stamped by `typetorch kernel
-- deploy`) before anything else runs, so no payload can change them for this server's lifetime.
local kernelFolder = script.Parent
Signing.init(kernelFolder, function(text)
	return HttpService:JSONDecode(text)
end)
local KERNEL_BUILD = kernelFolder:GetAttribute("KernelCommit") -- P-V1: short commit ("abc1234", "*" = dirty)
local KERNEL_HASH = kernelFolder:GetAttribute("KernelHash")
KERNEL_BUILD = if typeof(KERNEL_BUILD) == "string" and KERNEL_BUILD ~= "" then KERNEL_BUILD else nil
KERNEL_HASH = if typeof(KERNEL_HASH) == "string" and KERNEL_HASH ~= "" then KERNEL_HASH else nil

local Access = require(script.Parent.Access)
local Api = require(script.Parent.Api)
local Logs = require(script.Parent.Logs)
local Registry = require(script.Parent.Registry)
local Transport = require(script.Parent.Transport)

-- 0.3.2: Reports.luau is a new file. A place project that doesn't map it yet (an older template studio.project.json
-- lists the kernel's files one by one) still boots, without heartbeat and reports, and says so.
local Reports
do
	local module = script.Parent:FindFirstChild("Reports")
	if module then
		Reports = require(module)
	else
		warn("[TypeTorch] TypeTorchKernel.Reports is missing (map src/server/Reports.luau in the place project): no heartbeat or deploy reports on this server")
		local function noop() end
		Reports = {
			clip = function(text, max)
				return if text == nil then nil else string.sub(tostring(text), 1, max)
			end,
			configure = noop,
			heartbeat = noop,
			poke = noop,
			startHeartbeat = noop,
			close = noop,
			report = noop,
			enabled = function()
				return false
			end,
			info = function()
				return { enabled = false, missing = true }
			end,
		}
	end
end

Logs.start()

-- 0.3.2 (busy-flag hazard, plans/12): work that game code starts (reload, rollback, switchBranch, pins) runs on a
-- thread the KERNEL owns. Run on the caller's thread, a swap dies in the caller's own generation's hard stop (its Entry
-- is disabled halfway through the swap), leaving `busy` set for good. A BindableEvent's handlers run on threads of the
-- script that connected them, so this one's jobs are kernel threads. Jobs stay in a table (functions don't cross
-- BindableEvents).
local kernelJobs = Instance.new("BindableEvent")
local jobQueue: { [number]: () -> () } = {}
local nextJobId = 0
kernelJobs.Event:Connect(function(id)
	local job = jobQueue[id]
	jobQueue[id] = nil
	if job then
		job()
	end
end)

-- Runs fn(...) on a kernel thread; returns at once.
local function spawnOnKernel(fn, ...)
	local args = table.pack(...)
	nextJobId += 1
	jobQueue[nextJobId] = function()
		fn(table.unpack(args, 1, args.n))
	end
	kernelJobs:Fire(nextJobId)
end

-- Runs fn(...) on a kernel thread and waits for its result (a report table). If the caller's generation is stopped
-- meanwhile (the call swapped it out), the caller dies but the kernel thread finishes the work.
local function callOnKernel(fn, ...)
	local done, result = false, nil
	spawnOnKernel(function(...)
		local ok, value = pcall(fn, ...)
		result = if ok then value else { ok = false, error = tostring(value) }
		done = true
	end, ...)
	while not done do
		task.wait()
	end
	return result
end

-- An error line in the output that never counts toward a generation's health: it is raised on a kernel thread.
local function logError(text: string)
	spawnOnKernel(function()
		error(text, 0)
	end)
end

local clip = Reports.clip

local function folder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = parent
	return created
end

local serverGenerations = folder(folder(ServerStorage, "TypeTorch"), "Generations")
local replicatedRoot = folder(ReplicatedStorage, "TypeTorch")
local clientGenerations = folder(replicatedRoot, "Generations")
local entries = folder(ServerScriptService, "TypeTorchEntries")
Transport.start(replicatedRoot)

local startedAt = os.time()
local current = nil -- the running generation
local generationCount = 0
local busy = false
local pendingHead = nil -- latest head requested while a swap was running
local appliedSeq = -1 -- registry seq this server last moved to; server-local rollbacks don't change it
local history = {} -- successful generations, oldest first
local lastMessage = nil
local registryError = nil
local myBranch = nil
local bootPin = nil -- a private/reserved server's stored pin (Registry private/<id>.pin), read at boot
local storedPin = false -- whether this server's private/<id> record holds a pin (cleared by reload)
local lastPin = nil -- 0.2.3: the last pin message this server acted on (status().lastPin)
-- 0.3.2 (P-K3): artifacts that failed to run on THIS server (start, mount or the health window), by asset id:
-- { assetId, artifactId, seq, why, at }. The last-known-good chain and automatic deploys skip them; explicit dev actions
-- (reload, pin, branch) may still run them, and a success clears the mark.
local failedHere: { [number]: any } = {}
local startingGeneration = nil -- 0.3.2: the generation being started (its scripts' errors count toward its health)
local restoring = false -- 0.3.2: restoreLastKnownGood is running (a failed candidate doesn't start another one)
local lastErrorText, lastErrorAt = nil, nil -- 0.3.2: the newest error worth a look (heartbeat `e`)
local lastHealthRollback = nil -- 0.3.2: { from, to?, why, at } of the last health-window rollback
local closing = false -- 0.3.2: BindToClose ran: no more swaps
local failing = nil -- P-K2: { seq, assetId, attempts, nextAt } of the deploy that failed here (see noteFailure)
local ownAccessCode = nil -- 0.3.2: a reserved server's own access code (private/<id>.code), for the heartbeat's `k`

local function noteLastError(text: string?)
	if text then
		lastErrorText = clip(text, 200)
		lastErrorAt = os.time()
	end
end

local function serverType(): string
	if RunService:IsStudio() then
		return "studio"
	end
	if game.PrivateServerId ~= "" then
		return if game.PrivateServerOwnerId ~= 0 then "private" else "reserved"
	end
	return "public"
end

-- 0.3.1: Studio local payload ---------------------------------------------------------------------------------------
-- In Studio only, ServerStorage.TypeTorchDev.Payload (a Model shaped like an uploaded payload: Server, Shared, Client,
-- include) is mounted instead of LoadAsset, so a dev can run their local build with the real kernel (the template's
-- studio.project.json: rbxtsc -w + rojo serve + Play). Every mount takes a fresh CLONE, so the source stays for Reload,
-- and goes through the same mount checks (only Folders and ModuleScripts; dev channel). Such a session never follows
-- the branch head on its own (deploy messages, the poll); only dev actions move it, and Reload remounts the local copy.
-- Outside Studio the folder is ignored: every path below checks RunService:IsStudio() itself.
local localHeads: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any -- head tables made by localHead()
local localMode = false -- set at boot: Studio with a local payload
local localMounts = 0
local lastLocalBase = nil

-- The local payload's source Model, or nil (always nil outside Studio).
local function localPayloadSource(): Instance?
	if not RunService:IsStudio() then
		return nil
	end
	local dev = ServerStorage:FindFirstChild("TypeTorchDev")
	local source = dev and dev:FindFirstChild("Payload")
	if source and source:IsA("Model") then
		return source
	end
	return nil
end

-- A new head for the local payload (one per mount): artifact id "local-<HHMMSS UTC>" (plus the mount number when two
-- mounts share a second), dev channel, this server's branch. nil outside Studio or without a source.
local function localHead()
	if not RunService:IsStudio() or not localPayloadSource() then
		return nil
	end
	localMounts += 1
	local now = os.date("!*t")
	local base = string.format("local-%02d%02d%02d", now.hour, now.min, now.sec)
	local id = if base == lastLocalBase then `{base}-{localMounts}` else base
	lastLocalBase = base
	local head = { artifactId = id, channel = "dev", branch = myBranch }
	localHeads[head] = true
	return head
end

-- A fresh clone of the local payload, stamped with the head's id and the dev channel (the source keeps its own).
local function loadLocalPayload(head): Instance
	local source = localPayloadSource()
	if not source then
		error("no local payload (ServerStorage.TypeTorchDev.Payload, Studio only)")
	end
	if not (source:FindFirstChild("Server") and source:FindFirstChild("Client")) then
		error("ServerStorage.TypeTorchDev.Payload has no Server/Client (build first: rbxtsc)")
	end
	local payload = source:Clone()
	if not payload then
		error("ServerStorage.TypeTorchDev.Payload could not be cloned (Archivable is off)")
	end
	payload:SetAttribute("ArtifactId", head.artifactId)
	payload:SetAttribute("Channel", "dev")
	return payload
end

-- 0.3: signatures --------------------------------------------------------------------------------------------------

-- A head (or deployment entry) of `branch` that the owner signed for the prod channel.
local function signedProd(branch: string, head): boolean
	if typeof(head) ~= "table" or head.channel ~= "prod" then
		return false
	end
	local ok = Signing.verifyHead(branch, head)
	return ok
end

-- A head a prod server may follow: signed for prod, or exactly the BootstrapHeads entry kernel deploy stamped for
-- `branch` (the unsigned prod head of the 0.2 days; anything newer must be signed).
local function trustedProd(branch: string, head): boolean
	return signedProd(branch, head) or Signing.matchesBootstrap(branch, head)
end

-- A branch's channel from sources game code can't write: ConfigService's `channels`, the default branch (prod), a
-- BootstrapHeads entry, or a signed prod head of that branch. Unsigned stored heads don't count (game code can write
-- them).
local function trustedChannelOf(branch: string?): string
	if typeof(branch) ~= "string" then
		return "dev"
	end
	local state = Registry.state()
	local configured = state.channels[branch]
	if configured == "prod" or configured == "dev" then
		return configured
	end
	if branch == state.defaultBranch or Signing.bootstrapHead(branch) ~= nil then
		return "prod"
	end
	local fromConfig, fromStore = Registry.headCandidates(branch)
	if signedProd(branch, fromConfig) or signedProd(branch, fromStore) then
		return "prod"
	end
	return "dev"
end

-- Whether this server, on `branch`, takes only signed prod artifacts: every public server, and private/reserved
-- servers whose branch is prod-channel. Studio never (a dev's own session; Open Cloud messages don't reach it).
local function requiresSignatures(branch: string?): boolean
	local kind = serverType()
	if kind == "studio" then
		return false
	elseif kind == "public" then
		return true
	end
	return trustedChannelOf(branch) == "prod"
end

-- Strictest of the branch channel, the artifact channel and "prod" for public servers (plans/10). 0.3: the branch
-- channel comes from trusted sources only (an unsigned stored head can't make a prod branch look dev).
local function effectiveChannel(branch: string, artifactChannel: string?): string
	if serverType() == "public" then
		return "prod"
	end
	if trustedChannelOf(branch) == "prod" or artifactChannel == "prod" then
		return "prod"
	end
	return "dev"
end

-- Heads a prod server may swap to, by table identity (fields can't fake it): "signed" (a verified deploy message or
-- head), "bootstrap" (the stamped BootstrapHeads entry, or a stored head matching it), "pin" (a signed remote pin).
local admitted: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

local function admit(head, how: string)
	admitted[head] = how
	return head
end

-- A copy of a head that keeps its admission (and, 0.3.1, whether it is the Studio local payload).
local function cloneHead(head)
	local copy = table.clone(head)
	admitted[copy] = admitted[head]
	localHeads[copy] = localHeads[head]
	return copy
end

-- The bootstrap head of `branch` as a head table (one per branch, so its admission sticks), or nil.
local bootstrapTables: { [string]: any } = {}
local function bootstrapFor(branch: string)
	local cached = bootstrapTables[branch]
	if cached then
		return cached
	end
	local entry = Signing.bootstrapHead(branch)
	if not entry then
		return nil
	end
	local head = { assetId = entry.assetId, artifactId = entry.artifactId, seq = entry.seq, channel = "prod", branch = branch, bootstrap = true }
	bootstrapTables[branch] = admit(head, "bootstrap")
	return head
end

-- What a prod server follows on `branch` (user decision 2026-10-04): the newest trusted head (signed, or matching
-- BootstrapHeads exactly) from ConfigService or the stores; else the bootstrap head itself; else nil. Admitted.
local function signedHead(branch: string)
	local head = Registry.branchHead(branch, function(candidate)
		return trustedProd(branch, candidate)
	end)
	if head then
		return admit(head, if signedProd(branch, head) then "signed" else "bootstrap")
	end
	return bootstrapFor(branch)
end

-- 0.3 boot fail-safe: a verified head (signed or the bootstrap match) for the asset an unverified generation already
-- runs vouches for it: the flag clears and the generation keeps running (no swap).
local function vouchFor(head)
	local how = head and admitted[head]
	if current and current.unverified and (how == "signed" or how == "bootstrap") and head.assetId == current.artifact.assetId then
		current.unverified = nil
		current.head = cloneHead(head)
		for _, entry in history do
			if entry.name == current.name then
				entry.head = current.head -- a later /tt rollback to it is a rollback to a verified head
			end
		end
		replicatedRoot:SetAttribute("Unverified", nil)
		print(`[TypeTorch] {current.artifact.id} is verified now (seq {tostring(head.seq)}); the boot fail-safe state ended`)
	end
end

-- The head this server should follow on `branch`: signed only when this server requires signatures.
local function headFor(branch: string)
	if requiresSignatures(branch) then
		return signedHead(branch)
	end
	return Registry.branchHead(branch)
end

-- Refused messages and heads: a warning (at most one per kind per 3 s) and an event (one per kind per 60 s), so a
-- flood of forged messages can't flood the logs or the DataStore. status().refusals keeps the last 10.
local refusals = {}
local refusalWarnAt: { [string]: number } = {}
local refusalEventAt: { [string]: number } = {}
local refusalsSuppressed: { [string]: number } = {} -- warnings held back per kind since its last warning
local rejectedTotal = 0
local rejectedByKind: { [string]: number } = {}

-- Counters since boot: { total, byKind = { deploy, head, pin, swap, ... }, last = { kind, why, at, ... } }.
local function rejectedInfo()
	return { total = rejectedTotal, byKind = table.clone(rejectedByKind), last = if #refusals > 0 then table.clone(refusals[#refusals]) else nil }
end

local function refuse(kind: string, why: string, detail)
	rejectedTotal += 1
	rejectedByKind[kind] = (rejectedByKind[kind] or 0) + 1
	local entry = { kind = kind, why = why, at = os.time() }
	for key, value in detail or {} do
		entry[key] = value
	end
	table.insert(refusals, entry)
	while #refusals > 10 do
		table.remove(refusals, 1)
	end
	local now = os.clock()
	if not refusalWarnAt[kind] or now - refusalWarnAt[kind] >= 3 then
		refusalWarnAt[kind] = now
		local held = refusalsSuppressed[kind] or 0
		local suppressed = if held > 0 then ` ({held} more not shown)` else ""
		refusalsSuppressed[kind] = 0
		warn(`[TypeTorch] refused {kind}: {why}{suppressed} {HttpService:JSONEncode(detail or {})}`)
	else
		refusalsSuppressed[kind] = (refusalsSuppressed[kind] or 0) + 1
	end
	if not refusalEventAt[kind] or now - refusalEventAt[kind] >= 60 then
		refusalEventAt[kind] = now
		local event = table.clone(entry)
		event.at = nil
		event.action = "refused"
		event.job = game.JobId
		Registry.logEvent(event)
	end
end

-- Verifies a deploy message's signatures; on failure, re-reads the key asset once (rate-limited) in case the keys were
-- just rotated, and tries again. Yields when it re-reads.
local function verifyDeploy(fields, sig, sigF): (boolean, string?)
	local ok, why = Signing.verifyDeploy(fields, sig, sigF)
	if not ok and (sig ~= nil or sigF ~= nil) then
		local _, changed = Signing.refresh("failure")
		if changed then
			ok, why = Signing.verifyDeploy(fields, sig, sigF)
		end
	end
	return ok, why
end

local function verifyPin(data): (boolean, string?)
	local ok, why = Signing.verifyPin(data)
	if not ok and (data.sig ~= nil or data.sigF ~= nil) then
		local _, changed = Signing.refresh("failure")
		if changed then
			ok, why = Signing.verifyPin(data)
		end
	end
	return ok, why
end

-- The key asset loader (Signing calls it, rate-limited). S13: a live server sees a PATCH through
-- GetLatestAssetVersionAsync + LoadAssetVersion within about 1 s, while plain LoadAsset lags 13-17 s; so look the
-- version up first, skip the load when it is unchanged, and fall back to LoadAsset when the lookup fails.
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

Signing.configure({
	now = os.clock,
	unixNow = os.time,
	warn = warn,
	print = print,
	logEvent = function(entry)
		entry.job = game.JobId
		Registry.logEvent(entry)
	end,
	loadKeys = loadKeyAsset,
})

-- Registry merges: a signed prod head is never pushed out of the stores' copies by an unsigned one.
Registry.setTrust(function(branch: string, head)
	if trustedProd(branch, head) then
		return "trusted"
	end
	local state = Registry.state()
	local configured = state.channels[branch]
	if configured == "prod" or (configured == nil and (branch == state.defaultBranch or Signing.bootstrapHead(branch) ~= nil)) then
		return "untrusted"
	end
	return nil
end)

-- 0.2.3: a stable bucket 0..99 per server (djb2 over the JobId, mod 2^32, mod 100). Rollouts (`ro` on deploy
-- messages) and random A/B pins (`pct` on pin messages) both pick "bucket < percent", so the same servers come first
-- in both. The framework's devtools/ab.ts has the same function.
local function jobBucket(jobId: string): number
	local hash = 5381
	for index = 1, #jobId do
		hash = (hash * 33 + string.byte(jobId, index)) % 4294967296
	end
	return hash % 100
end

-- Whether this server takes a deploy rolled out to `percent` of servers (nil = everyone). Studio always does.
local function inRollout(percent: number?): boolean
	if typeof(percent) ~= "number" or percent >= 100 or serverType() == "studio" then
		return true
	end
	return jobBucket(game.JobId) < percent
end

local function notice(player: Player, text: string)
	Transport.kernelSend(player, Constants.CHANNEL_NOTICE, text)
end

-- Last dev decision sent per player ("<dev>/<role>"), so the running generation hears about changes (0.2.2).
local lastDev: { [Player]: string } = {}

local function sendDevStatus(player: Player)
	local dev, reason, role = Access.check(player)
	Transport.kernelSend(player, Constants.CHANNEL_DEV, {
		dev = dev,
		reason = reason,
		role = role,
		channel = if current then current.channel else nil,
	})
	if player.Parent == nil then
		return -- left while Access.check yielded
	end
	-- A change after the first decision (revoked, new member, badge granted) goes to api:onDevChanged.
	local key = `{dev}/{role or ""}`
	local before = lastDev[player]
	lastDev[player] = key
	if before ~= nil and before ~= key and current and current.devHandler then
		task.spawn(current.devHandler, player, { dev = dev, reason = reason, role = role })
	end
end

-- Payload loading and mounting -------------------------------------------------------------------------------------

local function findPayloadRoot(container: Instance): Instance?
	if container:FindFirstChild("Server") and container:FindFirstChild("Client") then
		return container
	end
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("Model") and descendant:FindFirstChild("Server") and descendant:FindFirstChild("Client") then
			return descendant
		end
	end
	return nil
end

-- Loader adapter: InsertService today; AssetService:LoadAssetAsync later (plans/01). Fresh instances every call, so a
-- generation never shares ModuleScripts (or require caches) with another.
local function loadPayload(assetId: number): Instance
	local ok, container = pcall(InsertService.LoadAsset, InsertService, assetId)
	if not ok then
		error(`LoadAsset({assetId}) failed: {container}`)
	end
	local payload = findPayloadRoot(container)
	if not payload then
		error(`asset {assetId} has no payload root (Server/Shared/Client/include)`)
	end
	return payload
end

-- `policy` (0.3) = { requireChannel = "prod"?, modulesOnly = boolean }, decided by swapTo from this server's type and
-- branch (never from head fields, which may come from game-written stores). 0.3.1: Studio local payloads are always
-- modulesOnly.
local function mount(payload: Instance, head, policy)
	local artifactId = payload:GetAttribute("ArtifactId")
	if head.artifactId and artifactId ~= head.artifactId then
		error(`asset {head.assetId} is artifact {artifactId}, expected {head.artifactId}`)
	end
	artifactId = artifactId or `asset-{head.assetId}`
	-- Prod servers (0.3) and pins on public servers need the payload's own Channel attribute to be exactly "prod"
	-- (missing = refused).
	local payloadChannel = payload:GetAttribute("Channel")
	local requireChannel = policy.requireChannel or head.requireChannel
	if requireChannel and payloadChannel ~= requireChannel then
		error(`artifact {artifactId} is {tostring(payloadChannel)}-channel; this server only takes {requireChannel}`)
	end
	-- 0.3 (audit S-L4): on prod servers a payload holds only Folders and ModuleScripts (the CLI checks this at build
	-- time too). Nothing in it may run by itself.
	if policy.modulesOnly then
		local others = {}
		for _, descendant in payload:GetDescendants() do
			if not descendant:IsA("ModuleScript") and descendant.ClassName ~= "Folder" then
				table.insert(others, `{descendant:GetFullName()} ({descendant.ClassName})`)
				if #others >= 5 then
					break
				end
			end
		end
		if #others > 0 then
			error(`artifact {artifactId} holds more than Folders and ModuleScripts: {table.concat(others, ", ")}`)
		end
	end
	local needsApi = payload:GetAttribute("KernelApi") or 1
	if needsApi > Constants.KERNEL_API then
		error(`artifact {artifactId} needs kernel API {needsApi}; this kernel is {Constants.KERNEL_API}`)
	end
	for _, part in { "Server", "Shared", "Client", "include" } do
		assert(payload:FindFirstChild(part), `payload has no {part}`)
	end

	generationCount += 1
	local name = `{artifactId}#{generationCount}`
	local serverTree = Instance.new("Folder")
	serverTree.Name = name
	local clientTree = Instance.new("Folder")
	clientTree.Name = name
	for _, tree in { serverTree, clientTree } do
		tree:SetAttribute("ArtifactId", artifactId)
	end
	-- Both trees keep the payload's root layout, so the compiled relative requires resolve in each of them.
	payload.Shared:Clone().Parent = clientTree
	payload.include:Clone().Parent = clientTree
	payload.Client.Parent = clientTree
	payload.Server.Parent = serverTree
	payload.Shared.Parent = serverTree
	payload.include.Parent = serverTree
	serverTree.Parent = serverGenerations

	-- A pinned head may come from another branch (head.branch); the payload's own Channel attribute wins.
	local artifactChannel = payload:GetAttribute("Channel") or head.channel
	-- 0.3.2 (P-N1): the payload's network protocol hash (stamped at build time), or nil.
	local protocolHash = payload:GetAttribute("ProtocolHash")
	protocolHash = if typeof(protocolHash) == "string" and protocolHash ~= "" and #protocolHash <= 128 then protocolHash else nil
	local branch = myBranch
	local generation = {
		name = name,
		number = generationCount,
		branch = branch,
		channel = effectiveChannel(branch, artifactChannel),
		head = head,
		pinned = head.pinned == true,
		startedAt = os.time(),
		serverTree = serverTree,
		clientTree = clientTree,
		-- 0.3.2 (P-F1): errors from this generation's own scripts, a failed onStart (reported by the framework), and
		-- when it was ready (os.clock); the health window is HEALTH_WINDOW seconds from readyAt.
		health = { errors = 0, startFailed = nil, lastError = nil, lastErrorAt = nil, readyAt = nil, failed = nil },
		artifact = {
			id = artifactId,
			assetId = head.assetId,
			channel = artifactChannel or Registry.channelOf(head.branch or branch),
			branch = head.branch or branch,
			commit = payload:GetAttribute("Commit") or head.commit,
			commitHash = head.commitHash,
			builtAt = payload:GetAttribute("BuiltAt"),
			seq = head.seq,
			protocolHash = protocolHash,
		},
	}
	-- 0.2.2: the artifact's identity on both trees, so the client API can report it too.
	local artifact = generation.artifact
	for _, tree in { serverTree, clientTree } do
		for name, value in { AssetId = artifact.assetId, Commit = artifact.commit, CommitHash = artifact.commitHash, Branch = artifact.branch, Channel = artifact.channel, BuiltAt = artifact.builtAt, Seq = artifact.seq, ProtocolHash = artifact.protocolHash } do
			local kind = typeof(value)
			if kind == "string" or kind == "number" or kind == "boolean" then
				tree:SetAttribute(name, value)
			end
		end
	end
	return generation
end

local function startGeneration(generation): (boolean, string?)
	generation.readyEvent = Instance.new("BindableEvent")
	local entry = script.Parent.Entry:Clone()
	entry.Name = generation.name
	local rootValue = Instance.new("ObjectValue")
	rootValue.Name = "Root"
	rootValue.Value = generation.serverTree
	rootValue.Parent = entry
	local kernelValue = Instance.new("ObjectValue")
	kernelValue.Name = "Kernel"
	kernelValue.Value = script.Parent.Api
	kernelValue.Parent = entry
	generation.entry = entry
	Api.register(entry, generation)

	-- The client tree goes live only once the server half is up, so clients never start a generation the server
	-- rejected.
	local result = nil
	local connection = generation.readyEvent.Event:Connect(function(ok, err)
		result = { ok, err }
	end)
	entry.Parent = entries
	entry.Enabled = true
	local deadline = os.clock() + Constants.READY_TIMEOUT
	while result == nil and os.clock() < deadline do
		task.wait()
	end
	connection:Disconnect()
	if result == nil then
		return false, "timed out waiting for ready"
	end
	if result[1] then
		generation.health.readyAt = os.clock() -- 0.3.2: the health window starts now
	end
	return result[1], result[2]
end

-- Soft stop, then hard stop. Returns seconds taken. `info` (0.2.2: {reason, branch, next}) goes to the generation's
-- stop function, so it can tell game code what replaces it; older frameworks ignore it.
local function stopGeneration(generation, info): number
	local started = os.clock()
	generation.stopping = true -- 0.3.2: its errors from here on don't count (a stop is not a health failure)
	Transport.detach()
	if generation.stop then
		-- 0.3 (audit P-K4): the stop function gets STOP_DEADLINE seconds; a stop that yields longer is cancelled and
		-- the hard stop below runs anyway, so one stuck onStop can't hold every swap (and this server) hostage.
		local done, ok, err = false, true, nil
		local thread = task.spawn(function()
			ok, err = pcall(generation.stop, info)
			done = true
		end)
		local deadline = os.clock() + Constants.STOP_DEADLINE
		while not done and os.clock() < deadline do
			task.wait()
		end
		if not done then
			pcall(task.cancel, thread)
			warn(`[TypeTorch] {generation.name} stop took more than {Constants.STOP_DEADLINE} s; hard stop`)
		elseif not ok then
			warn(`[TypeTorch] {generation.name} stop threw: {err}`)
		end
	end
	generation.stop = nil
	if generation.entry then
		generation.entry.Enabled = false
		Api.unregister(generation.entry)
		generation.entry:Destroy()
	end
	generation.serverTree:Destroy()
	local clientTree = generation.clientTree
	task.delay(Constants.CLIENT_TREE_GRACE, function()
		clientTree:Destroy()
	end)
	return os.clock() - started
end

local function publishActive(generation)
	-- 0.2.2: why it started, whether it is pinned, and the server type, for the client API.
	replicatedRoot:SetAttribute("Reason", generation.reason)
	replicatedRoot:SetAttribute("Pinned", generation.pinned == true)
	-- 0.2.3: this server runs an A/B experiment pin (its artifact id), or nil.
	replicatedRoot:SetAttribute("Experiment", if generation.head.experiment then generation.artifact.id else nil)
	replicatedRoot:SetAttribute("ServerType", serverType())
	replicatedRoot:SetAttribute("ArtifactId", generation.artifact.id)
	replicatedRoot:SetAttribute("Branch", generation.branch)
	replicatedRoot:SetAttribute("Channel", generation.channel)
	-- 0.3: this generation came from the boot fail-safe (an unverified prod head), or nil.
	replicatedRoot:SetAttribute("Unverified", if generation.unverified then true else nil)
	replicatedRoot:SetAttribute("ActiveGeneration", generation.name)
end

-- 0.2.3: holds the running generation where it is (a pin, optionally an A/B experiment) or releases it, without a
-- swap. `experiment` = { artifactId, assetId, by, since } or nil.
local function setHold(pinned: boolean, experiment)
	if not current then
		return
	end
	current.pinned = pinned
	-- A copy: the running head may be the registry's own table (Registry.branchHead), which must never carry pins.
	current.head = cloneHead(current.head)
	current.head.pinned = if pinned then true else nil
	current.head.experiment = experiment
	replicatedRoot:SetAttribute("Pinned", pinned)
	replicatedRoot:SetAttribute("Experiment", if experiment then current.artifact.id else nil)
end

-- Swap reasons as game code sees them (api.start.reason, the stop info, pending notices). Registry and poll moves are
-- deploys the server caught up with.
local PUBLIC_REASONS = {
	boot = "boot",
	deploy = "deploy",
	registry = "deploy",
	poll = "deploy",
	rollback = "rollback",
	branch = "branch",
	pin = "pin",
	reload = "reload",
	["server-rollback"] = "server_rollback",
	["auto-rollback"] = "auto_rollback",
}

local function publicReason(reason: string): string
	return PUBLIC_REASONS[reason] or "unknown"
end

-- Mean load + swap seconds of the last few swaps (2 s before the first one).
local function estimateSwapSeconds(): number
	local total, count = 0, 0
	for index = #history, math.max(1, #history - 4), -1 do
		local entry = history[index]
		total += (entry.loadSeconds or 0) + (entry.swapSeconds or 0)
		count += 1
	end
	return if count > 0 then total / count else 2
end

-- 0.2.2: tells the running generation (api:onPending) and every client that a swap to `head` is coming in about
-- `delay` + the usual swap time, or that it was called off (`cancelled`).
local function notifyPending(head, reason: string, delay: number, cancelled: boolean?)
	local info = {
		reason = publicReason(reason),
		branch = myBranch,
		artifactId = head.artifactId,
		commit = head.commit,
		eta = if cancelled then 0 else delay + estimateSwapSeconds(),
		cancelled = cancelled or nil,
	}
	if current and current.pendingHandler then
		task.spawn(current.pendingHandler, table.clone(info))
	end
	Transport.kernelBroadcast(Constants.CHANNEL_PENDING, info)
end

local lastGeneration = nil -- the last generation that started (it may be stopped now), for api.start.previous

-- 0.3.2: reasons that are deploys of this server's branch (reported in TypeTorchReports); dev actions aren't.
local DEPLOY_REASONS = { deploy = true, registry = true, poll = true, rollback = true }
-- 0.3.2: reasons that are a dev's explicit choice: they may run an artifact that failed here before.
local EXPLICIT_REASONS = { reload = true, pin = true, branch = true, ["server-rollback"] = true }

-- 0.3.2 (P-O1): one deploy outcome of `head` ("swapped", "failed", "rolled_back", "skipped", "booted") in
-- TypeTorchReports. `extra` = { e = error?, d = seconds? }. Heads without a seq aren't deploys: nothing is written.
local function reportOutcome(head, result: string, extra)
	if typeof(head) ~= "table" or typeof(head.seq) ~= "number" then
		return
	end
	Reports.report({
		s = head.seq,
		b = head.branch or myBranch,
		a = head.artifactId or (if typeof(head.assetId) == "number" then `asset-{head.assetId}` else nil),
		r = result,
		e = extra and extra.e,
		d = extra and extra.d,
		g = if current then current.number else 0,
	})
end

-- Outcomes the 60 s poll would repeat ("skipped") are written once per seq and result.
local reportedOnce: { [string]: boolean } = {}
local function reportOnce(head, result: string, extra)
	if typeof(head) ~= "table" or typeof(head.seq) ~= "number" then
		return
	end
	local key = `{head.seq}:{result}`
	if reportedOnce[key] then
		return
	end
	reportedOnce[key] = true
	reportOutcome(head, result, extra)
end

-- 0.3.2 (P-K3): marks an artifact as failed on this server (start, mount or health); see failedHere.
local function markFailed(assetId: any, artifactId: string?, seq: any, why: string)
	if typeof(assetId) ~= "number" then
		return
	end
	failedHere[assetId] = { assetId = assetId, artifactId = artifactId, seq = if typeof(seq) == "number" then seq else nil, why = clip(why, 300), at = os.time() }
	noteLastError(why)
end

-- Why an automatic move to `head` is skipped here (it failed on this server before), or nil.
local function failedBefore(head): string?
	local entry = typeof(head) == "table" and typeof(head.assetId) == "number" and failedHere[head.assetId]
	return if entry then `{entry.artifactId or `asset-{entry.assetId}`} failed on this server: {entry.why}` else nil
end

-- 0.3.2 (P-F1) health window ----------------------------------------------------------------------------------------
-- A generation is unhealthy when, from its mount until HEALTH_WINDOW seconds after ready, the framework reports a
-- failed onStart, or its own scripts (inside its server tree, or its Entry clone) raise HEALTH_ERRORS errors. It is
-- then rolled back to the last known good artifact and marked failed here. Errors from anything outside the
-- generation (the kernel, place scripts, other generations, a generation being stopped) never count.

local healthRollback -- (generation, why), defined with the last-known-good chain below
-- Assets restarted after a health rollback found nothing else to run: no second window (it would loop).
local healthExempt: { [number]: boolean } = {}

-- Whether `scriptInstance` belongs to `generation` (its server tree, or its Entry clone and what it holds).
local function owns(generation, scriptInstance): boolean
	if not generation or generation.stopping then
		return false
	end
	local ok, inside = pcall(function()
		local entry = generation.entry
		if entry and (scriptInstance == entry or scriptInstance:IsDescendantOf(entry)) then
			return true
		end
		return scriptInstance:IsDescendantOf(generation.serverTree)
	end)
	return ok and inside == true
end

local function generationOf(scriptInstance)
	if typeof(scriptInstance) ~= "Instance" then
		return nil
	end
	if owns(current, scriptInstance) then
		return current
	end
	if owns(startingGeneration, scriptInstance) then
		return startingGeneration
	end
	return nil
end

-- Rolls the running generation back when its health check failed inside the window (once per generation).
local function checkHealth(generation)
	local health = generation.health
	if generation ~= current or health.failed or health.readyAt == nil or closing or healthExempt[generation.artifact.assetId] then
		return
	end
	if localMode then
		return -- a Studio local payload: errors are counted, the dev's own code is never swapped for an upload
	end
	if os.clock() > health.readyAt + Constants.HEALTH_WINDOW then
		return -- after the window: counted (status, heartbeat "degraded"), never rolled back
	end
	local why = nil
	if health.startFailed then
		why = `onStart failed: {health.startFailed}`
	elseif health.errors >= Constants.HEALTH_ERRORS then
		why = `{health.errors} errors within {Constants.HEALTH_WINDOW} s of ready, last: {health.lastError}`
	end
	if why then
		health.failed = why
		spawnOnKernel(healthRollback, generation, why)
	end
end

local function noteError(generation, message: string, startFailed: boolean?)
	local health = generation.health
	local text = clip(message, 200)
	health.lastError = text
	health.lastErrorAt = os.time()
	noteLastError(text)
	if startFailed then
		health.startFailed = health.startFailed or text
	else
		health.errors += 1
	end
	checkHealth(generation)
end

ScriptContext.Error:Connect(function(message, _trace, scriptInstance)
	local generation = generationOf(scriptInstance)
	if generation then
		noteError(generation, tostring(message))
	end
end)

-- Api: the framework reports a failed lifecycle hook ({kind = "onStart" | ..., module, message}). A failed onStart is
-- a health failure; anything else counts as one error. The kernel prints it as an error line from its own thread (so
-- it doesn't count twice). Returns whether it was taken.
local reportsLogged = 0
local function reportError(generation, info): boolean
	if typeof(info) ~= "table" or generation.stopping or (generation ~= current and generation ~= startingGeneration) then
		return false
	end
	local kind = if typeof(info.kind) == "string" then clip(info.kind, 40) else "error"
	local module = if typeof(info.module) == "string" then clip(info.module, 80) else "?"
	local message = clip(if info.message ~= nil then tostring(info.message) else "?", 2000)
	if reportsLogged < 200 then
		reportsLogged += 1
		logError(`[TypeTorch] {module}.{kind} failed: {message}`)
	end
	noteError(generation, `{module}.{kind}: {message}`, kind == "onStart")
	return true
end

-- 0.3.2: "ok" | "failed" (nothing runs) | "unverified" (boot fail-safe) | "degraded" (a deploy failed here, or the
-- running generation failed or keeps erroring). The heartbeat's `h`.
local function healthState(): string
	if not current then
		return "failed"
	end
	if current.unverified then
		return "unverified"
	end
	local health = current.health
	if failing ~= nil or health.failed or health.startFailed or health.errors >= Constants.HEALTH_ERRORS then
		return "degraded" -- (a failed onStart after the window too: that module isn't running)
	end
	return "ok"
end

-- 0.3.2 (P-O1): this server's entry in TypeTorchServers (the contract is in Reports.luau). The framework's admin
-- heartbeat (kernels before 0.3.2) wrote t..v; the kernel adds q, g, h, e and sv. `e` only while it is recent (15 min)
-- or the server isn't healthy.
local function heartbeatEntry()
	local kind = serverType()
	local health = healthState()
	local recentError = lastErrorText ~= nil and (health ~= "ok" or (lastErrorAt ~= nil and os.time() - lastErrorAt <= 900))
	return {
		t = kind,
		b = myBranch,
		c = if current then current.channel else nil,
		a = if current then current.artifact.id else nil,
		n = #Players:GetPlayers(),
		m = Players.MaxPlayers,
		s = startedAt,
		u = os.time(),
		p = game.PlaceId,
		k = if kind == "reserved" then ownAccessCode else nil,
		x = if current and current.head.experiment then 1 else nil,
		v = Constants.KERNEL_VERSION,
		q = appliedSeq,
		g = if current then current.number else 0,
		h = health,
		e = if recentError then lastErrorText else nil,
		sv = 2,
	}
end

Reports.configure({
	memory = MemoryStoreService,
	jobId = game.JobId,
	studio = serverType() == "studio",
	entry = heartbeatEntry,
	players = function()
		return #Players:GetPlayers()
	end,
	warn = warn,
})

-- Swap to a registry head { assetId, artifactId?, seq?, ... }. Returns a report table. `by` is the user id that asked
-- (dev menu, /tt, game code); `announced` means notifyPending already ran for this swap.
local restoreLastKnownGood -- (excludeAssetId, why) -> report?, defined below
local swapTo
swapTo = function(head, reason: string, by: number?, announced: boolean?)
	if closing then
		return { ok = false, reason = reason, error = "the server is closing", stage = "gate" }
	end
	if busy then
		pendingHead = { head = head, reason = reason, by = by }
		return { ok = false, queued = true }
	end
	-- 0.3: the last gate on prod servers. Every way in (deploy messages, heads, pins, reloads, rollbacks) admits the
	-- head table it checked; anything else is refused here.
	local signedOnly = requiresSignatures(myBranch)
	-- "blind" (the boot fail-safe) counts only for this server's first generation, or to restore the generation that
	-- was just running when its replacement failed to start (auto-rollback); never for updates.
	local how = admitted[head]
	local blindOk = how == "blind" and ((reason == "boot" and lastGeneration == nil) or reason == "auto-rollback")
	if signedOnly and (not how or (how == "blind" and not blindOk)) then
		refuse("swap", if how == "blind" then "an unverified head after boot" else "not a signed head", { reason = reason, assetId = head.assetId, artifactId = head.artifactId })
		return { ok = false, reason = reason, assetId = head.assetId, artifactId = head.artifactId, error = "refused: not signed", stage = "gate" }
	end
	-- 0.3.1: the Studio local payload (a head made by localHead); never outside Studio.
	local isLocal = localHeads[head] == true
	if isLocal and not RunService:IsStudio() then
		return { ok = false, reason = reason, artifactId = head.artifactId, error = "local payloads run only in Studio", stage = "gate" }
	end
	busy = true
	local report = { reason = reason, assetId = head.assetId, artifactId = head.artifactId, ok = false }
	local old = current
	local oldStopped = false
	if old and not announced then
		notifyPending(head, reason, 0)
	end
	local ok, err = pcall(function()
		local loadStarted = os.clock()
		report.stage = "load"
		local payload = if isLocal then loadLocalPayload(head) else loadPayload(head.assetId)
		report.loadSeconds = os.clock() - loadStarted
		report.stage = "mount"
		-- Signed deploys and heads (and bootstrap heads) on prod servers: Channel exactly "prod"; pins keep their own rule
		-- (head.requireChannel); experiments (signed remote pins) may be any channel. Local payloads: modules only.
		local generation = mount(payload, head, {
			requireChannel = if signedOnly and (how == "signed" or how == "bootstrap" or how == "blind") then "prod" else nil,
			modulesOnly = signedOnly or isLocal,
		})
		generation.localPayload = isLocal or nil
		-- 0.3 boot fail-safe: a generation from an unverified head is flagged until a verified head replaces or vouches
		-- for it (status().unverified, an Attention error, no verified badge).
		generation.unverified = signedOnly and how == "blind" or nil
		-- 0.2.2: how this generation starts, for api.start (the kernel adds stopSeconds and swapSeconds below).
		local previous = lastGeneration
		generation.reason = publicReason(reason)
		generation.start = {
			kind = if previous then "swap" else "boot",
			reason = generation.reason,
			requestedBy = by,
			previous = if previous
				then {
					artifact = table.clone(previous.artifact),
					branch = previous.branch,
					channel = previous.channel,
					generation = previous.number,
				}
				else nil,
			branchChanged = previous ~= nil and previous.branch ~= generation.branch,
			startedAt = generation.startedAt,
			loadSeconds = report.loadSeconds,
		}

		local swapStarted = os.clock()
		report.stage = "start"
		report.kind = generation.start.kind
		if old then
			local artifact = generation.artifact
			report.stopSeconds = stopGeneration(old, {
				reason = generation.reason,
				branch = generation.branch,
				next = {
					id = artifact.id,
					assetId = artifact.assetId,
					branch = artifact.branch,
					commit = artifact.commit,
					channel = artifact.channel,
				},
			})
			oldStopped = true
			current = nil
			generation.start.stopSeconds = report.stopSeconds
		end
		generation.clientTree.Parent = clientGenerations
		startingGeneration = generation -- 0.3.2: errors from its scripts count toward its health from now on
		local started, startError = startGeneration(generation)
		startingGeneration = nil
		report.swapSeconds = os.clock() - swapStarted
		if not started then
			report.error = startError
			warn(`[TypeTorch] {generation.name} failed to start: {startError}`)
			stopGeneration(generation)
			-- 0.3.2 (P-K3): never again automatically on this server; then the last known good (the previous head first).
			markFailed(head.assetId, generation.artifact.id, head.seq, `start: {startError}`)
			if old and not restoring then
				report.rollbackTo = if failedHere[old.artifact.assetId] then nil else old.artifact.id
				report.rollbackScheduled = true
				local failedAsset = head.assetId
				task.defer(function()
					restoreLastKnownGood(failedAsset, `{generation.artifact.id} failed to start`)
				end)
			end
			return
		end
		report.stage = nil
		-- Same table the generation got as api.start, so it can read the whole swap time once it is running.
		generation.start.swapSeconds = report.swapSeconds
		generation.deploy = DEPLOY_REASONS[reason] or reason == "boot" or nil
		current = generation
		lastGeneration = generation
		table.insert(history, {
			name = generation.name,
			artifactId = generation.artifact.id,
			branch = generation.artifact.branch,
			head = head,
			at = DateTime.now():ToIsoDate(),
			reason = reason,
			loadSeconds = report.loadSeconds,
			swapSeconds = report.swapSeconds,
		})
		while #history > 30 do
			table.remove(history, 1)
		end
		publishActive(generation)
		report.generation = generation.name
		report.ok = true
	end)
	busy = false
	startingGeneration = nil
	if not ok then
		report.error = tostring(err)
		warn(`[TypeTorch] swap failed: {err}`)
		-- 0.3.2: a payload refused at mount (channel, scripts, kernel API, wrong id) fails the same way every time.
		if report.stage == "mount" then
			markFailed(head.assetId, head.artifactId, head.seq, `mount: {err}`)
		end
	end
	if not report.ok then
		noteLastError(report.error)
	end
	if not report.ok and old and not oldStopped then
		notifyPending(head, reason, 0, true) -- load or mount failed: the old generation keeps running
	end
	print("[TypeTorch] swap " .. HttpService:JSONEncode(report))
	for _, player in Players:GetPlayers() do
		sendDevStatus(player)
	end
	if report.ok then
		local generation = current
		-- 0.3.2: a dev ran it on purpose and it started: no longer "failed here".
		if EXPLICIT_REASONS[reason] and typeof(head.assetId) == "number" then
			failedHere[head.assetId] = nil
			healthExempt[head.assetId] = nil
		end
		-- 0.3.2 (P-O1): the server's first generation is a boot report; a heartbeat soon shows the new artifact.
		if report.kind == "boot" then
			reportOutcome(head, "booted", { d = (report.loadSeconds or 0) + (report.swapSeconds or 0) })
		end
		task.defer(Reports.poke) -- deferred: callers record appliedSeq right after swapTo returns
		-- 0.3.2 (P-F1): a failure reported before ready (a thrown onStart, early errors) is judged now.
		if generation then
			checkHealth(generation)
		end
	end
	if pendingHead then
		local next = pendingHead
		pendingHead = nil
		task.defer(swapTo, next.head, next.reason, next.by)
	end
	return report
end

-- Branch selection and updates --------------------------------------------------------------------------------------

-- The branch a private/reserved server's stored record asks for (and its pin and access code), by the boot rules.
local function branchFromOverride(override): string
	local state = Registry.state()
	if typeof(override.code) == "string" and override.code ~= "" then
		ownAccessCode = override.code -- 0.3.2: Migrate and newServer store it; the heartbeat's `k`
	end
	-- 0.3: private/<id> is written by game servers, so in-universe code could rewrite it. A player-owned private
	-- server follows a stored branch other than the default only when its owner is a dev; otherwise game code
	-- could move a server full of players to a dev branch (which takes unsigned deploys).
	if serverType() == "private" and override.branch ~= state.defaultBranch and not Access.isDevUserId(game.PrivateServerOwnerId) then
		refuse("private-branch", `the owner ({game.PrivateServerOwnerId}) is not a dev; this server stays on {state.defaultBranch}`, { branch = override.branch })
		return state.defaultBranch
	end
	bootPin = override.pin
	storedPin = override.pin ~= nil
	return override.branch
end

-- 0.3.2 (P-K8): the record couldn't be read at boot (after PRIVATE_READ_RETRY_DELAYS); the sync loop keeps trying.
local privateReadPending = false

local function chooseBranch(): string
	local state = Registry.state()
	local kind = serverType()
	if kind == "private" or kind == "reserved" then
		local override, readError = Registry.privateOverride(game.PrivateServerId)
		for _, delay in Constants.PRIVATE_READ_RETRY_DELAYS do
			if not readError then
				break
			end
			task.wait(delay)
			override, readError = Registry.privateOverride(game.PrivateServerId)
		end
		if readError then
			privateReadPending = true
			warn(`[TypeTorch] this server's stored branch is unreadable ({readError}); booting {state.defaultBranch} and retrying`)
		end
		if override then
			return branchFromOverride(override)
		end
	elseif kind == "studio" then
		local dev = ServerStorage:FindFirstChild("TypeTorchDev")
		local branch = dev and dev:GetAttribute("Branch")
		if typeof(branch) == "string" then
			return branch
		end
		if localMode then
			return "dev" -- 0.3.1: a local payload runs on TypeTorchDev.Branch, else "dev"
		end
	end
	return state.defaultBranch
end

-- 0.3: every deploy (message or head) goes through one worker, newest seq first. appliedSeq moves only when the swap
-- succeeded (audit P-K2). A payload that fails to LOAD is retried after LOAD_RETRY_DELAYS; one that fails to mount or
-- start is not retried, and the poll leaves it alone until a newer deploy (`failing`).
local wanted = nil -- { head, reason, jitter }: the newest deploy this server should move to
local workerRunning = false
-- `failing` = { seq, assetId, attempts, nextAt } (declared with the server state above).

local function blockedByFailure(head): boolean
	return failing ~= nil and failing.seq == head.seq and failing.assetId == head.assetId and os.clock() < failing.nextAt
end

local runWorker

local function want(head, reason: string, jitter: boolean)
	if wanted and typeof(wanted.head.seq) == "number" and typeof(head.seq) == "number" and head.seq < wanted.head.seq then
		return -- a newer deploy is already waiting
	end
	wanted = { head = head, reason = reason, jitter = jitter }
	if not workerRunning then
		workerRunning = true
		task.spawn(runWorker)
	end
end

local function noteFailure(head, reason: string, report)
	if typeof(head.seq) ~= "number" then
		return
	end
	if failing and failing.seq == head.seq and failing.assetId == head.assetId then
		failing.attempts += 1
	else
		failing = { seq = head.seq, assetId = head.assetId, attempts = 1, nextAt = 0 }
	end
	local delay = if report.stage == "load" then Constants.LOAD_RETRY_DELAYS[failing.attempts] else nil
	if not delay then
		failing.nextAt = math.huge
		local what = if report.stage == "load" then `failed to load {failing.attempts} times` else `failed ({report.stage or "swap"})`
		local keeps = if current then current.artifact.id elseif report.rollbackScheduled then "its last known good" else "nothing"
		warn(`[TypeTorch] deploy #{head.seq} ({head.artifactId or head.assetId}) {what}; this server keeps {keeps} until a newer deploy`)
		Registry.logEvent({ action = "deploy_failed", seq = head.seq, assetId = head.assetId, artifactId = head.artifactId, stage = report.stage, attempts = failing.attempts, error = clip(report.error, 300), job = game.JobId })
		-- 0.3.2 (P-O1): the deploy's outcome on this server.
		reportOutcome(head, "failed", { e = `{report.stage or "swap"}: {report.error or "?"}` })
		return
	end
	failing.nextAt = os.clock() + delay
	print(`[TypeTorch] deploy #{head.seq} failed to load (attempt {failing.attempts}); retrying in {delay} s`)
	local record = failing
	task.delay(delay, function()
		if failing == record and head.seq > appliedSeq then
			want(head, reason, false)
		end
	end)
end

runWorker = function()
	while wanted and not closing do
		local job = wanted
		local head = job.head
		local announced = false
		-- 0.3.2 (P-K3): an artifact that failed on this server isn't run again automatically.
		local failedWhy = failedBefore(head)
		if failedWhy then
			wanted = nil
			reportOnce(head, "skipped", { e = failedWhy })
			continue
		end
		if job.jitter and serverType() == "public" and current then
			local delay = math.random() * Constants.PUBLIC_JITTER_SECONDS
			notifyPending(head, job.reason, delay)
			announced = true
			task.wait(delay)
		end
		if wanted ~= job then
			continue -- a newer deploy arrived during the wait: that one goes next
		end
		wanted = nil
		-- S-M1, re-checked after the wait: another swap (a newer deploy, a pin) may have moved this server meanwhile.
		local seq = head.seq
		if current and typeof(seq) == "number" and seq <= appliedSeq then
			if announced then
				notifyPending(head, job.reason, 0, true)
			end
			continue
		end
		if current and ((head.artifactId and head.artifactId == current.artifact.id) or head.assetId == current.artifact.assetId) then
			vouchFor(head)
			if DEPLOY_REASONS[job.reason] and typeof(seq) == "number" and seq > appliedSeq then
				reportOutcome(head, "swapped", { d = 0 }) -- 0.3.2: already running it
			end
			appliedSeq = math.max(appliedSeq, if typeof(seq) == "number" then seq else appliedSeq)
			continue
		end
		while busy do
			task.wait(0.1) -- a dev's swap is running; the deploy goes right after it
		end
		local report = swapTo(head, job.reason, nil, announced)
		if report.ok then
			if typeof(seq) == "number" then
				appliedSeq = math.max(appliedSeq, seq)
			end
			failing = nil
			if DEPLOY_REASONS[job.reason] and report.kind ~= "boot" then
				reportOutcome(head, "swapped", { d = (report.loadSeconds or 0) + (report.swapSeconds or 0) })
			end
		elseif not report.queued then
			noteFailure(head, job.reason, report)
			-- 0.3.2 (P-K3): nothing runs (a boot, or an empty server) and swapTo had no previous generation to restore:
			-- the last known good of this server or its branch, if any. A deploy that failed to LOAD is still retried.
			if not current and not report.rollbackScheduled and not closing then
				restoreLastKnownGood(head.assetId, `{head.artifactId or head.assetId} failed ({report.stage or "swap"})`)
			end
		end
	end
	workerRunning = false
end

-- Heads this server already reported as refused (branch#seq@asset), so the 60 s poll doesn't repeat them.
local refusedHeads: { [string]: boolean } = {}

-- Moves to the branch head when the registry has a newer seq than this server last applied. 0.3: prod servers only
-- consider signed prod heads; a newer head that isn't one is reported (once) and triggers one rate-limited key re-read.
local function followHead(reason: string, jitter: boolean?)
	-- 0.3.1: a Studio session on the local payload moves only when a dev acts (Reload remounts the local copy).
	if not myBranch or localMode then
		return
	end
	local head = headFor(myBranch)
	if requiresSignatures(myBranch) then
		local best = if head and typeof(head.seq) == "number" then head.seq else -1
		local fromConfig, fromStore = Registry.headCandidates(myBranch)
		for _, candidate in { fromConfig, fromStore } do
			local candidateSeq = if typeof(candidate) == "table" and typeof(candidate.seq) == "number" then candidate.seq else nil
			if candidate ~= head and candidateSeq and candidateSeq > best and candidateSeq > appliedSeq then
				local key = `{myBranch}#{candidateSeq}@{tostring(candidate.assetId)}`
				if not refusedHeads[key] then
					local ok, why = Signing.verifyHead(myBranch, candidate)
					if ok and candidate.channel ~= "prod" then
						ok, why = false, `channel {tostring(candidate.channel)}, not prod`
					end
					if not ok and (candidate.sig ~= nil or candidate.sigF ~= nil) then
						local _, changed = Signing.refresh("failure") -- the keys may have just rotated
						if changed then
							head = headFor(myBranch)
							ok = head == candidate
						end
					end
					if not ok then
						refusedHeads[key] = true
						refuse("head", why or "not signed", { branch = myBranch, seq = candidateSeq, assetId = candidate.assetId, artifactId = candidate.artifactId })
					end
				end
			end
		end
	end
	if not head or typeof(head.assetId) ~= "number" then
		return
	end
	local seq = if typeof(head.seq) == "number" then head.seq else 0
	if seq <= appliedSeq and current then
		return
	end
	if blockedByFailure(head) then
		return
	end
	-- `ro` is unsigned: prod servers ignore it (plans/03 "Fields outside the signature").
	local rollout = if requiresSignatures(myBranch) then nil else head.rollout
	if current and ((head.artifactId and head.artifactId == current.artifact.id) or head.assetId == current.artifact.assetId) then
		if current.pinned and inRollout(rollout) then
			setHold(false, nil) -- the pinned artifact is the head now (seq > appliedSeq here)
		end
		vouchFor(head)
		appliedSeq = seq
		return
	end
	-- 0.2.3: a deploy rolled out to some servers only (`ro`). The others keep what they run (appliedSeq stays, so a
	-- wider rollout of the same deploy, or the next deploy, still reaches them); new servers boot it (no `current`).
	if current and not inRollout(rollout) then
		reportOnce(head, "skipped", { e = `outside the {rollout}% rollout` })
		return
	end
	-- 0.3.2 (P-K3): an artifact that failed on this server isn't run again automatically (a newer deploy still is).
	local failedWhy = failedBefore(head)
	if failedWhy then
		reportOnce(head, "skipped", { e = failedWhy })
		return
	end
	want(head, reason, jitter == true)
end

Registry.onChange(function(state)
	Access.setConfig(state, Registry.known())
	-- Public servers always run the default branch. ConfigService may arrive after boot (P-K5) or change it.
	if myBranch and serverType() == "public" and typeof(state.defaultBranch) == "string" and state.defaultBranch ~= myBranch then
		print(`[TypeTorch] default branch is now {state.defaultBranch} (was {myBranch})`)
		myBranch = state.defaultBranch
		appliedSeq = -1 -- a new branch (from ConfigService, which game code can't write); its newest head wins
	end
	for _, player in Players:GetPlayers() do
		sendDevStatus(player)
	end
	task.spawn(followHead, "registry", true)
end)

-- 0.3.2 (P-O1): a deploy message for this server's branch that a prod server refused (signature, channel) is a
-- "failed" report, so `deploy --wait` hears about a bad key or channel instead of timing out. At most one per 60 s per
-- server, since anything in the universe can publish forged messages; a later real outcome of that seq overwrites it.
local refusalReportAt = -math.huge
local function reportRefusal(detail, why: string)
	-- An old seq never: a forged copy must not overwrite the report of a deploy this server already applied.
	if typeof(detail.seq) ~= "number" or detail.seq <= appliedSeq or os.clock() - refusalReportAt < 60 then
		return
	end
	refusalReportAt = os.clock()
	reportOutcome(detail, "failed", { e = `refused: {why}` })
end

-- Deploy messages: {b = branch, a = assetId, i = artifactId, s = seq, c = commit, ch = channel, t = sent ms,
-- r = rollback?, ro = rollout % (0.2.3, 1-99)?, sig?, sigF? (0.3)}. Every server records the head (any branch) so
-- servers started later boot it even without a ConfigService registry. With `ro`, only servers whose jobBucket is below
-- it swap; the others keep their current artifact (plans/12 P-R1). 0.3: on prod servers a message counts only with a
-- valid signature, `ch` = "prod" and a seq newer than the applied one (plans/03 "Signed prod messages").
local function onDeployMessage(message)
	local ok, data = pcall(HttpService.JSONDecode, HttpService, message.Data)
	if not ok or typeof(data) ~= "table" then
		return
	end
	lastMessage = {
		data = data,
		receivedMs = DateTime.now().UnixTimestampMillis,
		sentMs = if typeof(message.Sent) == "number" then math.floor(message.Sent * 1000) else nil,
	}
	if typeof(data.b) ~= "string" or typeof(data.a) ~= "number" then
		return
	end
	-- 0.2.3: `ro` must be a whole percent; 100 means everyone. Anything else is a malformed message: ignore all of it.
	local rollout = nil
	if data.ro ~= nil then
		if typeof(data.ro) ~= "number" or data.ro % 1 ~= 0 or data.ro < 1 or data.ro > 100 then
			warn(`[TypeTorch] deploy message for {data.b} ignored: bad rollout {tostring(data.ro)}`)
			return
		end
		rollout = if data.ro < 100 then data.ro else nil
	end
	local seq = tonumber(data.s)
	local channel = if data.ch == "prod" or data.ch == "dev" then data.ch else nil
	local timeOk, sentAt = pcall(DateTime.fromUnixTimestampMillis, if typeof(data.t) == "number" then data.t else nil)
	if not timeOk then
		sentAt = DateTime.now()
	end
	-- 0.3: the signatures travel with the head and the history, so other prod servers (and the dev menu) can check them.
	local t = if typeof(data.t) == "number" then data.t else nil
	local sig = if typeof(data.sig) == "string" and #data.sig <= 100 then data.sig else nil
	local sigF = if typeof(data.sigF) == "string" and #data.sigF <= 100 then data.sigF else nil
	-- `r`: 1 = rollback; "resign" (0.3) = the CLI re-signed the running head after `keys rotate` (same asset, new seq).
	local r = if data.r == 1 or data.r == "resign" then data.r else nil
	-- Deployment history: this deploy plus the head it replaces (so heads from before 0.2.0 stay listed).
	local previous = Registry.branchHead(data.b)
	local entries = {
		{
			seq = seq,
			branch = data.b,
			channel = channel,
			artifactId = data.i,
			assetId = data.a,
			commit = data.c,
			at = sentAt:ToIsoDate(),
			rollback = if data.r == 1 then true else nil,
			r = r,
			rollout = rollout,
			t = t,
			sig = sig,
			sigF = sigF,
		},
	}
	if previous and typeof(previous.assetId) == "number" then
		table.insert(entries, {
			seq = previous.seq,
			branch = data.b,
			channel = previous.channel,
			artifactId = previous.artifactId,
			assetId = previous.assetId,
			commit = previous.commit,
			at = previous.deployedAt,
			rollback = previous.rollback,
			r = previous.r,
			t = previous.t,
			sig = previous.sig,
			sigF = previous.sigF,
		})
	end
	-- 0.3.2: the deployment entries go with the head: only the server whose MemoryStore update wins writes them durably.
	Registry.saveHead(data.b, {
		assetId = data.a,
		artifactId = data.i,
		seq = seq or 0,
		commit = data.c,
		channel = channel,
		deployedAt = DateTime.now():ToIsoDate(),
		rollback = if data.r == 1 then true else nil,
		r = r,
		rollout = rollout,
		t = t,
		sig = sig,
		sigF = sigF,
	}, entries)
	if data.b ~= myBranch then
		return
	end
	if localMode then
		print(`[TypeTorch] deploy {tostring(data.i)} for {data.b} not applied: this Studio session runs the local payload`)
		return
	end
	local signedOnly = requiresSignatures(myBranch)
	if signedOnly then
		-- `ro` isn't in the signed string (tt1), so a prod server ignores it (plans/03 "Fields outside the signature").
		rollout = nil
		if current and typeof(seq) == "number" and seq <= appliedSeq and data.i == current.artifact.id then
			return -- the deploy this server runs, delivered again
		end
		local detail = { branch = data.b, seq = seq, assetId = data.a, artifactId = data.i }
		local verified, why = verifyDeploy(data, sig, sigF)
		if not verified then
			refuse("deploy", why or "bad signature", detail)
			reportRefusal(detail, why or "bad signature")
			return
		end
		if data.ch ~= "prod" then
			refuse("deploy", `channel {tostring(data.ch)}, not prod`, detail)
			reportRefusal(detail, `channel {tostring(data.ch)}, not prod`)
			return
		end
		if typeof(seq) ~= "number" or seq <= appliedSeq then
			refuse("deploy", `seq {tostring(seq)} is not newer than the applied {appliedSeq} (replay?)`, detail)
			return
		end
	end
	local reportHead = { seq = seq, branch = data.b, artifactId = data.i, assetId = data.a }
	if current and (data.i == current.artifact.id or data.a == current.artifact.assetId) then
		-- Already running it (also a re-signed head, r = "resign": the stored head and appliedSeq move, no swap). A newer
		-- deploy of the pinned (or experiment) artifact ends the hold: it is the head now.
		if current.pinned and seq and seq > appliedSeq and inRollout(rollout) then
			setHold(false, nil)
		end
		if seq and seq > appliedSeq and r == "resign" then
			print(`[TypeTorch] re-signed head for {data.b}: {data.i} #{seq} (no swap)`)
		end
		if typeof(seq) == "number" and seq > appliedSeq then
			reportOutcome(reportHead, "swapped", { d = 0 }) -- 0.3.2: already running it
		end
		if signedOnly then
			-- Verified above: it vouches for an unverified (boot fail-safe) generation running this asset.
			vouchFor(admit({ assetId = data.a, artifactId = data.i, seq = seq, commit = data.c, channel = channel, branch = data.b, t = t, r = r, rollback = if r == 1 then true else nil, sig = sig, sigF = sigF }, "signed"))
		end
		appliedSeq = math.max(appliedSeq, seq or appliedSeq)
		return
	end
	-- A pin holds until a newer deploy seq for this branch arrives (late or repeated messages don't undo it).
	if current and current.pinned and seq and seq <= appliedSeq then
		return
	end
	-- Outside a partial rollout: keep the current artifact (pinned or not). appliedSeq stays, see followHead.
	if current and not inRollout(rollout) then
		print(`[TypeTorch] deploy {data.i} for {data.b} rolled out to {rollout}%; this server (bucket {jobBucket(game.JobId)}) keeps {current.artifact.id}`)
		reportOnce(reportHead, "skipped", { e = `outside the {rollout}% rollout` })
		return
	end
	-- 0.3.2 (P-K3): an artifact that failed on this server isn't run again automatically.
	local failedWhy = failedBefore(reportHead)
	if failedWhy then
		print(`[TypeTorch] deploy {data.i} for {data.b} skipped: {failedWhy}`)
		reportOnce(reportHead, "skipped", { e = failedWhy })
		return
	end
	print(`[TypeTorch] {if r == 1 then "rollback" elseif r == "resign" then "re-signed head" else "deploy"} message for {data.b}: {data.i}{if rollout then ` ({rollout}% rollout)` else ""}{if signedOnly then " (signed)" else ""}`)
	local head = {
		assetId = data.a,
		artifactId = data.i,
		seq = seq,
		commit = data.c,
		channel = channel,
		branch = data.b,
		deployedAt = sentAt:ToIsoDate(),
		rollout = rollout,
		rollback = if data.r == 1 then true else nil,
		r = r,
		t = t,
		sig = sig,
		sigF = sigF,
	}
	if signedOnly then
		admit(head, "signed")
	end
	failing = nil -- a new deploy message: its own retries
	want(head, if r == 1 then "rollback" else "deploy", true)
end

-- Control (dev menu, /tt) ------------------------------------------------------------------------------------------

local function requireDev(player: Player?): (boolean, string?)
	if player and not Access.isDev(player) then
		return false, "not a dev"
	end
	return true, nil
end

-- Known branch names (registry + stored heads, cached for 30 s). Yields when the cache is stale.
local function knownBranches(): { string }
	local names = {}
	for name in Registry.state().branches do
		names[name] = true
	end
	for _, name in Registry.storedBranches() do
		names[name] = true
	end
	if myBranch then
		names[myBranch] = true
	end
	local list = {}
	for name in names do
		table.insert(list, name)
	end
	table.sort(list)
	return list
end

-- Same artifact: same asset, and the same deploy seq when both sides know it.
local function sameDeploy(a, entry): boolean
	if not a or a.assetId ~= entry.assetId then
		return false
	end
	return typeof(a.seq) ~= "number" or typeof(entry.seq) ~= "number" or a.seq == entry.seq
end

-- Every known deployment, newest first (Registry.deployments + known heads + this server's history). Yields.
local function deploymentEntries()
	local names = knownBranches()
	Registry.refreshDeployments()
	local heads = {}
	for _, name in names do
		local head = Registry.branchHead(name)
		if head and typeof(head.assetId) == "number" then
			table.insert(heads, {
				seq = head.seq,
				branch = name,
				channel = head.channel or Registry.channelOf(name),
				artifactId = head.artifactId,
				assetId = head.assetId,
				commit = head.commit,
				at = head.deployedAt,
				rollback = head.rollback,
				r = head.r,
				rollout = head.rollout,
				t = head.t,
				sig = head.sig,
				sigF = head.sigF,
			})
		end
	end
	-- Heads from before kernel 0.2.0 (or from missed messages) become permanent entries.
	Registry.recordDeployments(heads)
	local extra = {}
	local keep = table.clone(heads)
	for index, entry in history do
		local head = entry.head
		if head and typeof(head.assetId) == "number" then
			local seed = {
				seq = head.seq,
				branch = head.branch or entry.branch or myBranch,
				channel = head.channel,
				artifactId = head.artifactId,
				assetId = head.assetId,
				commit = head.commit,
				at = head.deployedAt,
				rollback = head.rollback,
				r = head.r,
				t = head.t,
				sig = head.sig,
				sigF = head.sigF,
			}
			table.insert(extra, seed)
			if index == #history then
				table.insert(keep, seed) -- the running generation is always listed
			end
		end
	end
	return Registry.deployments(extra, keep)
end

-- The artifact picker list: deployments newest first, each with `live` (its branch's current head) and `running`
-- (this server's current generation). 0.3: `verified` = { main, fallback } for signed entries (Signing.signatures:
-- each signature checked on its own, cached), nil for unsigned (dev) ones; the signatures themselves stay here.
local function artifacts()
	local list = deploymentEntries()
	for _, entry in list do
		entry.channel = entry.channel or Registry.channelOf(entry.branch)
		entry.live = sameDeploy(Registry.branchHead(entry.branch), entry)
		entry.running = current ~= nil and sameDeploy(current.artifact, entry)
		entry.verified = Signing.headSignatures(entry.branch, entry)
		entry.sig, entry.sigF = nil, nil
	end
	return list
end

-- A known deployment of `assetId` (arbitrary ids are refused), preferring `branch`.
local function findArtifact(assetId: number, branch: string?)
	local found = nil
	for _, entry in deploymentEntries() do
		if entry.assetId == assetId then
			if entry.branch == branch then
				return entry
			end
			found = found or entry
		end
	end
	return found
end

local function pinHead(entry)
	return {
		assetId = entry.assetId,
		artifactId = entry.artifactId,
		seq = entry.seq,
		commit = entry.commit,
		channel = entry.channel or Registry.channelOf(entry.branch),
		branch = entry.branch,
		deployedAt = entry.at,
		pinned = true,
		-- 0.3: the deploy's signatures, so a stored pin can be checked when a prod private server boots it.
		rollback = entry.rollback,
		r = entry.r,
		t = entry.t,
		sig = entry.sig,
		sigF = entry.sigF,
	}
end

-- The seq a pin on `branch` must stay at: the branch head's seq (or the pinned deploy's, if it's newer on that branch).
local function pinSeq(branch: string, entry): number
	local head = Registry.branchHead(branch)
	local seq = if head and typeof(head.seq) == "number" then head.seq else 0
	if entry.branch == branch and typeof(entry.seq) == "number" then
		seq = math.max(seq, entry.seq)
	end
	return seq
end

-- 0.3.2 (P-K3) last-known-good chain ---------------------------------------------------------------------------------
-- After a failure (a generation that failed to start or failed its health window; a deploy that failed while nothing
-- ran), the server tries, in order: its own generation history (newest first, so the generation that just ran comes
-- first), then its branch's deployment history (newest first), then on prod servers the BootstrapHeads entry. It skips
-- the failing artifact, everything in failedHere, Studio local payloads and repeats, and tries at most LKG_MAX_TRIES.
-- The prod rules stay exactly as they are: on a signed-only server a history head counts because it was admitted when
-- it ran ("one this server already ran", the boot fail-safe's head included, as before), a deployment entry only when
-- it verifies (signed prod, or the exact BootstrapHeads match), and swapTo's gate still checks every head.

local function lkgCandidates(exclude: number?): { any }
	local list, seen = {}, {}
	local signedOnly = requiresSignatures(myBranch)
	local function consider(head)
		if typeof(head) ~= "table" or localHeads[head] or typeof(head.assetId) ~= "number" then
			return
		end
		if head.assetId == exclude or failedHere[head.assetId] or seen[head.assetId] then
			return
		end
		if current and head.assetId == current.artifact.assetId then
			return
		end
		if signedOnly and not admitted[head] then
			return
		end
		seen[head.assetId] = true
		table.insert(list, head)
	end
	for index = #history, 1, -1 do
		consider(history[index].head)
	end
	local ok, entries = pcall(deploymentEntries)
	if ok then
		for _, entry in entries do
			if entry.branch == myBranch and typeof(entry.assetId) == "number" and not seen[entry.assetId] then
				local head = pinHead(entry)
				head.pinned = nil
				if signedOnly and trustedProd(myBranch, head) then
					admit(head, if signedProd(myBranch, head) then "signed" else "bootstrap")
				end
				consider(head)
			end
		end
	else
		warn(`[TypeTorch] last-known-good: the deployment history is unreadable: {entries}`)
	end
	if signedOnly then
		consider(bootstrapFor(myBranch))
	end
	return list
end

-- Runs the first last-known-good candidate that starts. Returns its swap report, or nil. Kernel threads only.
restoreLastKnownGood = function(exclude: number?, why: string)
	if restoring or closing then
		return nil
	end
	if localMode then
		warn(`[TypeTorch] the local payload failed ({why}); fix it, then Stop + Play or Reload`)
		return nil -- Studio local payload: never swapped for an uploaded artifact
	end
	restoring = true
	while busy do
		task.wait(0.1)
	end
	local result, tries = nil, 0
	local ok, err = pcall(function()
		for _, head in lkgCandidates(exclude) do
			if tries >= Constants.LKG_MAX_TRIES or closing then
				break
			end
			tries += 1
			print(`[TypeTorch] last known good after "{why}": trying {head.artifactId or `asset-{head.assetId}`}`)
			local report = swapTo(head, "auto-rollback")
			if report.ok then
				result = report
				break
			elseif report.queued then
				break -- another swap took over
			end
		end
	end)
	restoring = false
	if not ok then
		warn(`[TypeTorch] last-known-good failed: {err}`)
	end
	if result then
		Registry.logEvent({ action = "auto_rollback", to = result.artifactId, generation = result.generation, why = clip(why, 300), job = game.JobId })
	else
		warn(`[TypeTorch] no last-known-good artifact could run (after: {why}); {if current then `{current.artifact.id} keeps running` else "nothing runs"}`)
		Registry.logEvent({ action = "auto_rollback_failed", tries = tries, why = clip(why, 300), job = game.JobId })
	end
	return result
end

-- 0.3.2 (P-F1): the running generation failed its health window: mark it failed here, never retry its deploy
-- automatically (a newer deploy still applies), and run the last known good. Kernel threads only.
healthRollback = function(generation, why: string)
	while busy do
		task.wait(0.1)
	end
	if generation ~= current or generation.rolledBack or closing then
		return
	end
	generation.rolledBack = true
	local artifact, head = generation.artifact, generation.head
	warn(`[TypeTorch] {generation.name} failed its health check ({why}); rolling back`)
	markFailed(artifact.assetId, artifact.id, head.seq, `health: {why}`)
	if typeof(head.seq) == "number" then
		failing = { seq = head.seq, assetId = head.assetId, attempts = 1, nextAt = math.huge }
	end
	Registry.logEvent({ action = "health_rollback", from = artifact.id, assetId = artifact.assetId, seq = head.seq, why = clip(why, 300), job = game.JobId })
	local restored = restoreLastKnownGood(artifact.assetId, `{artifact.id}: {why}`)
	if not restored and not current and not closing then
		-- Every candidate failed after the unhealthy generation was stopped: a degraded game beats an empty server. It
		-- runs without a health window (healthExempt), so this can't loop.
		warn(`[TypeTorch] nothing else runs: restarting {artifact.id} (degraded)`)
		if typeof(artifact.assetId) == "number" then
			healthExempt[artifact.assetId] = true
		end
		swapTo(head, "auto-rollback")
	end
	local to = restored and (restored.artifactId or restored.generation)
	lastHealthRollback = { from = artifact.id, to = to, why = clip(why, 300), at = os.time() }
	if generation.deploy then
		-- The deploy's outcome here: rolled back, or failed when nothing else could run (it keeps running, degraded).
		if restored then
			reportOutcome(head, "rolled_back", { e = `{why}; now {to}` })
		else
			reportOutcome(head, "failed", { e = `{why}; no last-known-good, it keeps running` })
		end
	end
end

local function reload(player: Player?)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	-- 0.3.1: a Studio session on the local payload reloads a fresh clone of it.
	local head = if localMode then localHead() else headFor(myBranch)
	if not head then
		if localMode then
			return { ok = false, error = "no ServerStorage.TypeTorchDev.Payload to reload" }
		end
		return { ok = false, error = `branch {myBranch} has no {if requiresSignatures(myBranch) then "signed " else ""}artifact` }
	end
	local kind = serverType()
	if storedPin and (kind == "private" or kind == "reserved") then
		-- Back to the branch head for good: drop the stored pin (keeps the branch).
		if Registry.setPrivateBranch(game.PrivateServerId, myBranch, if player then player.UserId else 0) then
			storedPin = false
		end
	end
	local report = swapTo(head, "reload", if player then player.UserId else nil)
	if report.ok and typeof(head.seq) == "number" then
		appliedSeq = head.seq -- P-K2: only once it runs
	end
	return report
end

local function rollback(player: Player?)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	if player and current and current.channel == "prod" and not Access.isAdmin(player) then
		return { ok = false, error = "only admins can roll back a prod-channel server" }
	end
	for index = #history - 1, 1, -1 do
		local entry = history[index]
		if not current or entry.artifactId ~= current.artifact.id then
			Registry.logEvent({ action = "server_rollback", from = current and current.artifact.id, to = entry.artifactId, by = player and player.UserId, job = game.JobId })
			return swapTo(entry.head, "server-rollback", if player then player.UserId else nil)
		end
	end
	return { ok = false, error = "no earlier artifact on this server" }
end

-- Swaps THIS server to a known artifact and holds it there until a newer deploy seq for this server's branch arrives.
-- Devs on private/reserved/studio servers; on public servers only owner/admin, and only prod-channel artifacts.
-- 0.2.3: `options.experiment = true` is an A/B experiment pin (owner/admin only): ANY known artifact, any channel,
-- also on public servers. The effective channel stays "prod" there (public), so devtools stay read-only. It holds until
-- the next deploy of this server's branch (that reaches this server), an unpin, or the server closing; it is never
-- stored. `options.by` / `options.remote` come only from pin messages (Api.luau passes `experiment` alone).
-- 0.3: on prod servers (public; private on a prod branch) only signed remote pins (`options.signed`, set by
-- onPinMessage after it verified them) work; dev menu and /tt pins there are refused ("use the CLI: typetorch pin").
local PROD_PIN_ERROR = "prod servers take only signed pins: use the CLI (typetorch pin)"

local function pinArtifact(player: Player?, assetId: number, options)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	-- 0.3: say so before any lookup (the check below admits only signed pins on prod servers).
	if player and requiresSignatures(myBranch) then
		return { ok = false, error = PROD_PIN_ERROR }
	end
	if typeof(assetId) ~= "number" then
		return { ok = false, error = "bad asset id" }
	end
	local experiment = typeof(options) == "table" and options.experiment == true
	local by = if player then player.UserId elseif typeof(options) == "table" and typeof(options.by) == "number" then options.by else nil
	local kind = serverType()
	if experiment and player and not Access.isAdmin(player) then
		return { ok = false, error = "only the owner or admins can start an experiment" }
	end
	if kind == "public" and player and not Access.isAdmin(player) then
		return { ok = false, error = "only the owner or admins can pin a public server" }
	end
	Registry.refreshStoredHead(myBranch, 3)
	local entry = findArtifact(assetId, myBranch)
	if not entry then
		return { ok = false, error = `asset {assetId} is not a known deployment` }
	end
	local channel = entry.channel or Registry.channelOf(entry.branch)
	if kind == "public" and channel ~= "prod" and not experiment then
		return { ok = false, error = "dev-channel artifacts run on public servers only as an experiment" }
	end
	local head = pinHead(entry)
	if kind == "public" and not experiment then
		head.requireChannel = "prod"
	end
	-- 0.3 (user decision): on prod servers only a signed remote pin (onPinMessage checked it) is a way in.
	if requiresSignatures(myBranch) then
		if typeof(options) == "table" and options.signed == true then
			admit(head, "pin")
		else
			if not player then
				refuse("pin", "an unsigned pin on a prod server", { assetId = assetId, by = by })
			end
			return { ok = false, error = PROD_PIN_ERROR }
		end
	end
	local seq = pinSeq(myBranch, entry)
	if experiment then
		head.experiment = { artifactId = entry.artifactId or `asset-{assetId}`, assetId = assetId, by = by, since = os.time() }
	elseif kind == "private" or kind == "reserved" then
		-- The pin survives a restart of this private server (until the branch gets a newer deploy).
		local pin = table.clone(head)
		pin.pinned = nil
		pin.deployedAt = nil
		pin.headSeq = seq
		local saved, err = Registry.setPrivateBranch(game.PrivateServerId, myBranch, if player then player.UserId else 0, pin)
		if not saved then
			return { ok = false, error = `could not save the pin: {err}` }
		end
		storedPin = true
	end
	-- Deploy messages and the poll only move this server past `seq` (a newer deploy of its branch).
	appliedSeq = math.max(appliedSeq, seq)
	Registry.logEvent({
		action = "pin",
		experiment = experiment or nil,
		remote = (typeof(options) == "table" and options.remote == true) or nil,
		from = current and current.artifact.id,
		to = entry.artifactId or `asset-{assetId}`,
		assetId = assetId,
		branch = myBranch,
		channel = channel,
		serverType = kind,
		by = by,
		job = game.JobId,
	})
	if experiment then
		print(`[TypeTorch] experiment pin: {entry.artifactId or assetId} ({channel}) on this {kind} server, by {by or "?"}`)
	end
	if current and sameDeploy(current.artifact, entry) then
		-- Already running it: just hold it here.
		setHold(true, head.experiment)
		return { ok = true, generation = current.name, assetId = assetId, artifactId = current.artifact.id, pinned = true, experiment = experiment or nil }
	end
	local report = swapTo(head, "pin", by)
	report.pinned = report.ok or nil
	report.experiment = (report.ok and experiment) or nil
	return report
end

-- 0.2.3: ends this server's A/B experiment: back to its branch head (the server may then run a newer artifact than
-- before the experiment, e.g. one it skipped as outside a partial rollout). Remote unpins pass `assetId` to end only
-- that experiment. Owner/admin on public servers, any dev elsewhere; `player` nil = a pin message (checked there).
local function unpin(player: Player?, by: number?, assetId: number?)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	if player and serverType() == "public" and not Access.isAdmin(player) then
		return { ok = false, error = "only the owner or admins can unpin a public server" }
	end
	local experiment = current and current.head.experiment
	if not experiment then
		return { ok = false, error = "no experiment on this server" }
	end
	if assetId ~= nil and experiment.assetId ~= assetId then
		return { ok = false, error = "another experiment runs here" }
	end
	by = if player then player.UserId else by
	Registry.logEvent({ action = "unpin", experiment = true, from = current.artifact.id, branch = myBranch, serverType = serverType(), by = by, job = game.JobId })
	print(`[TypeTorch] experiment {current.artifact.id} ended by {by or "?"}`)
	Registry.refreshStoredHead(myBranch, 3)
	local head = if localMode then localHead() else headFor(myBranch) -- 0.3.1: back to the local payload in Studio
	if not head or (not localHeads[head] and (typeof(head.assetId) ~= "number" or sameDeploy(current.artifact, head))) then
		setHold(false, nil) -- nothing else to run: just stop holding
		return { ok = true, generation = current.name, artifactId = current.artifact.id }
	end
	local report = swapTo(head, "reload", by)
	if report.ok then
		appliedSeq = math.max(appliedSeq, head.seq or 0)
	end
	return report
end

local function switchBranch(player: Player?, branch: string)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	local kind = serverType()
	if kind == "public" then
		return { ok = false, error = "public servers always run the default branch; use /tt new <branch>" }
	end
	Registry.refreshStoredHead(branch, 3)
	-- 0.3: a prod branch gives only a signed head (this server then requires signatures).
	local head = headFor(branch)
	if not head then
		return { ok = false, error = `no {if requiresSignatures(branch) then "signed " else ""}artifact on branch {branch}` }
	end
	if kind ~= "studio" then
		local saved, err = Registry.setPrivateBranch(game.PrivateServerId, branch, if player then player.UserId else 0)
		if not saved then
			return { ok = false, error = `could not save the branch: {err}` }
		end
		storedPin = false
	end
	myBranch = branch
	appliedSeq = head.seq or 0
	return swapTo(head, "branch", if player then player.UserId else nil)
end

-- 0.2.2: a reload that game code can offer (an admin panel). Only the owner or admins, decided here. The swap runs on
-- a kernel thread (spawnOnKernel): the caller is a thread of the generation the reload stops, and the hard stop would
-- kill it, and the swap with it, halfway through. Returns at once.
local function requestReload(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return { ok = false, error = "bad player" }
	end
	if not Access.isAdmin(player) then
		return { ok = false, error = "only the owner or admins can reload" }
	end
	if not localMode and not Registry.branchHead(myBranch) then
		return { ok = false, error = `branch {myBranch} has no artifact` }
	end
	spawnOnKernel(reload, player)
	return { ok = true, queued = true, reason = "reload" }
end

-- 0.3.2 (P-K7): client generation reports ------------------------------------------------------------------------------
-- Each client tells the kernel (channel __tt/client, tagged "*") how its generation start went, after its one retry:
-- { g = generation name, ok, e = error?, ms, retried? }. Untrusted input: checked field by field, kept per player, shown
-- in status().clients and the dev menu. It never triggers a rollback (a player could fake it).
local clientStatus: { [Player]: any } = {}
local clientFailures = 0
local clientWarnAt = -math.huge
local lastClientFailure = nil

local function onClientStatus(player: Player, info)
	if typeof(info) ~= "table" or typeof(info.g) ~= "string" or #info.g == 0 or #info.g > 120 then
		return
	end
	local ok = info.ok == true
	local entry = {
		generation = info.g,
		ok = ok,
		error = if not ok and info.e ~= nil then clip(tostring(info.e), 200) else nil,
		ms = if typeof(info.ms) == "number" and info.ms == info.ms then math.clamp(math.floor(info.ms), 0, 10 ^ 7) else nil,
		retried = info.retried == true or nil,
		at = os.time(),
	}
	clientStatus[player] = entry
	if not ok then
		clientFailures += 1
		lastClientFailure = { userId = player.UserId, generation = entry.generation, error = entry.error, at = entry.at }
		if os.clock() - clientWarnAt >= 10 then
			clientWarnAt = os.clock()
			warn(`[TypeTorch] {player.Name}'s client failed to start {entry.generation}{if entry.retried then " (after a retry)" else ""}: {entry.error or "?"}`)
		end
	end
end
Transport.onKernel(Constants.CHANNEL_CLIENT, onClientStatus)

-- { players, reported, ok, failed, behind (reported another generation than the running one), failures (since boot),
-- lastFailure? }.
local function clientSummary()
	local summary = { players = #Players:GetPlayers(), reported = 0, ok = 0, failed = 0, behind = 0, failures = clientFailures, lastFailure = lastClientFailure }
	for _, entry in clientStatus do
		summary.reported += 1
		if entry.ok then
			summary.ok += 1
		else
			summary.failed += 1
		end
		if current and entry.generation ~= current.name then
			summary.behind += 1
		end
	end
	return summary
end

-- Reserves a server on `branch` and teleports the player there. With `assetId` (a known deployment), the new server
-- boots pinned to that artifact.
local function newServer(player: Player, branch: string, assetId: number?)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	if typeof(branch) ~= "string" or branch == "" then
		return { ok = false, error = "bad branch" }
	end
	if assetId ~= nil and typeof(assetId) ~= "number" then
		return { ok = false, error = "bad asset id" }
	end
	Registry.refreshStoredHead(branch, 3)
	local pin = nil
	if assetId ~= nil then
		local entry = findArtifact(assetId, branch)
		if not entry then
			return { ok = false, error = `asset {assetId} is not a known deployment` }
		end
		pin = pinHead(entry)
		pin.pinned = nil
		pin.deployedAt = nil
		pin.headSeq = pinSeq(branch, entry)
	elseif not Registry.branchHead(branch) then
		return { ok = false, error = `no artifact on branch {branch}` }
	end
	if RunService:IsStudio() then
		return { ok = false, error = "teleports don't work in Studio" }
	end
	local ok, code, privateServerId = pcall(TeleportService.ReserveServer, TeleportService, game.PlaceId)
	if not ok then
		return { ok = false, error = tostring(code) }
	end
	-- 0.3.2: the access code goes in the record too (server-only), so the new server can publish it in its heartbeat
	-- (`k`) and Admin > Servers can join it.
	local saved, err = Registry.setPrivateBranch(privateServerId, branch, player.UserId, pin, code)
	if not saved then
		return { ok = false, error = `could not save the branch: {err}` }
	end
	if pin then
		Registry.logEvent({ action = "pin_server", to = pin.artifactId or `asset-{assetId}`, assetId = assetId, branch = branch, by = player.UserId, job = game.JobId })
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	local teleported, teleportError = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, { player }, options)
	return { ok = teleported, error = if teleported then nil else tostring(teleportError), branch = branch, assetId = assetId }
end

local function branchList()
	local list = {}
	for _, name in knownBranches() do
		local head = Registry.branchHead(name)
		if not head then
			continue
		end
		table.insert(list, {
			name = name,
			channel = Registry.channelOf(name),
			artifactId = head.artifactId,
			assetId = head.assetId,
			commit = head.commit,
			seq = head.seq,
			deployedAt = head.deployedAt,
			by = head.by,
		})
	end
	return list
end

-- 0.3.2: the health of the running generation, for status().health.
local function healthInfo()
	local info = { state = healthState(), errors = 0, lastRollback = if lastHealthRollback then table.clone(lastHealthRollback) else nil }
	if current then
		local health = current.health
		info.errors = health.errors
		info.lastError = health.lastError
		info.lastErrorAt = health.lastErrorAt
		info.startFailed = health.startFailed
		info.failed = health.failed
		if health.readyAt and not health.failed then
			local left = health.readyAt + Constants.HEALTH_WINDOW - os.clock()
			info.windowLeft = if left > 0 then math.ceil(left) else nil
		end
	end
	return info
end

-- 0.3.2: failedHere as a list, newest first.
local function failedList()
	local list = {}
	for _, entry in failedHere do
		table.insert(list, table.clone(entry))
	end
	table.sort(list, function(a, b)
		return a.at > b.at
	end)
	return list
end

-- The running artifact for status(): a copy with `verified` (0.3, { main, fallback } or nil for unsigned).
local function runningArtifact()
	if not current then
		return nil
	end
	local artifact = table.clone(current.artifact)
	artifact.verified = if current.unverified then nil else Signing.headSignatures(artifact.branch or myBranch, current.head)
	return artifact
end

local function status()
	local copy = {}
	for index, entry in history do
		copy[index] = { name = entry.name, artifactId = entry.artifactId, at = entry.at, reason = entry.reason, loadSeconds = entry.loadSeconds, swapSeconds = entry.swapSeconds }
	end
	return {
		jobId = game.JobId,
		placeId = game.PlaceId,
		placeVersion = game.PlaceVersion,
		serverType = serverType(),
		branch = myBranch,
		channel = current and current.channel,
		pinned = current ~= nil and current.pinned == true,
		startedAt = startedAt,
		uptime = os.time() - startedAt,
		generation = current and {
			name = current.name,
			number = current.number,
			startedAt = current.startedAt,
			uptime = os.time() - current.startedAt,
			artifact = runningArtifact(),
		},
		history = copy,
		lastMessage = lastMessage,
		players = #Players:GetPlayers(),
		maxPlayers = Players.MaxPlayers,
		kernelVersion = Constants.KERNEL_VERSION,
		kernelApi = Constants.KERNEL_API,
		registryError = registryError,
		memoryMb = Stats:GetTotalMemoryUsageMb(),
		luaHeapKb = collectgarbage("count"),
		appliedSeq = appliedSeq,
		-- 0.2.3: { artifactId, assetId, by, since } while this server runs an A/B experiment pin.
		experiment = if current and current.head.experiment then table.clone(current.head.experiment) else nil,
		-- 0.2.3: this server's bucket (0-99) for rollouts and random A/B pins: it takes `ro`/`pct` above it.
		rolloutBucket = if game.JobId ~= "" then jobBucket(game.JobId) else nil,
		lastPin = lastPin,
		-- 0.3 (P-V1): the kernel build stamped by `typetorch kernel deploy` (KernelCommit / KernelHash attributes).
		kernelBuild = KERNEL_BUILD,
		kernelHash = KERNEL_HASH,
		-- 0.3: signatures. `signedOnly`: this server takes only signed prod artifacts. Full trust state: api:keys().
		signedOnly = requiresSignatures(myBranch),
		-- 0.3: a signed-only server with no trusted head for its branch (no verified head, no bootstrap head): it runs
		-- nothing new until a signed deploy arrives (it keeps polling and re-reading the keys on the normal schedule).
		noTrustedHead = if requiresSignatures(myBranch) and myBranch and not headFor(myBranch) then true else nil,
		-- 0.3 boot fail-safe: the running generation came from an UNVERIFIED stored head (no verified head loaded at boot).
		unverified = if current and current.unverified then true else nil,
		signing = Signing.summary(),
		rejected = rejectedInfo(),
		-- 0.3.1: the running generation is the Studio local payload (ServerStorage.TypeTorchDev.Payload).
		localPayload = if current and current.localPayload then true else nil,
		-- 0.3.2 (P-F1): { state = "ok" | "failed" | "unverified" | "degraded", errors, lastError?, lastErrorAt?,
		-- startFailed?, windowLeft? (seconds of the health window left), lastRollback? = { from, to?, why, at } }.
		health = healthInfo(),
		-- 0.3.2 (P-K3): artifacts that failed on this server (never run again automatically), newest first.
		failed = failedList(),
		-- 0.3.2 (P-O1): the kernel's heartbeat and report writes ({ enabled, heartbeat, reports } counters).
		heartbeat = Reports.info(),
		-- 0.3.2 (P-K7): client generation reports.
		clients = clientSummary(),
	}
end

-- 0.3: the trust state for devs (api:keys(); the dev menu's Artifact > Signing): Signing.keys() plus this server's
-- rejections and whether it requires signatures.
local function keysInfo()
	local info = Signing.keys()
	info.signedOnly = requiresSignatures(myBranch)
	info.noTrustedHead = if info.signedOnly and myBranch and not headFor(myBranch) then true else nil
	info.unverified = if current and current.unverified then true else nil
	info.rejected = rejectedInfo()
	info.refusals = table.clone(refusals)
	return info
end

-- 0.2.3: the running A/B experiment ({ artifactId, assetId, by, since }) or nil. Also the framework's feature test.
local function experimentInfo()
	return if current and current.head.experiment then table.clone(current.head.experiment) else nil
end

-- Remote pins (A/B), 0.2.3 --------------------------------------------------------------------------------------------
-- Topic TypeTorch/pin: { j = { jobId... }?, pct = 1-100?, a = assetId (absent only for unpin), b = branch, by = userId,
-- t = sent ms, unpin = true? }. A server acts when it is on branch `b` (any server type but Studio) and its JobId is in
-- `j`, or `pct` is set and its jobBucket is below it. Pins are experiment pins (pinArtifact with experiment = true;
-- the artifact must be a known deployment); `unpin` ends an experiment (only one on asset `a`, if given).
-- TRUST (0.3): prod servers act only on pins signed like deploy messages (`sig` / `sigF` over the pin canonical
-- string, plans/03; the CLI signs them). Dev servers still take unsigned pins. Also: strict fields, a 120 s freshness
-- window (the signed `t`), and `by` must be the owner or an admin by the registry. The framework's Admin > Servers
-- publishes unsigned pins (admin.ab, owner/admin only, rate-limited), so those reach dev servers only.

local JOB_ID_PATTERN = "^[%w%-]+$"

local function wholeNumber(value, low: number, high: number): boolean
	return typeof(value) == "number" and value == value and value % 1 == 0 and value >= low and value <= high
end

-- Returns (ok, why).
local function checkPinMessage(data): (boolean, string?)
	if typeof(data.b) ~= "string" or #data.b == 0 or #data.b > 64 or string.find(data.b, "%c") then
		return false, "bad branch"
	end
	if not wholeNumber(data.by, 1, 2 ^ 53) then
		return false, "bad by"
	end
	if typeof(data.t) ~= "number" or math.abs(DateTime.now().UnixTimestampMillis - data.t) > Constants.PIN_MAX_AGE * 1000 then
		return false, "stale or bad t"
	end
	if data.unpin ~= nil and typeof(data.unpin) ~= "boolean" then
		return false, "bad unpin"
	end
	if data.a ~= nil or data.unpin ~= true then
		if not wholeNumber(data.a, 1, 2 ^ 53) then
			return false, "bad asset id"
		end
	end
	if data.pct ~= nil and not wholeNumber(data.pct, 1, 100) then
		return false, "bad pct"
	end
	if data.j ~= nil then
		if typeof(data.j) ~= "table" then
			return false, "bad j"
		end
		local count = 0
		for key, jobId in data.j do
			count += 1
			if typeof(key) ~= "number" or typeof(jobId) ~= "string" or #jobId == 0 or #jobId > 64 or not string.match(jobId, JOB_ID_PATTERN) then
				return false, "bad job id"
			end
		end
		if count == 0 or count ~= #data.j or count > 100 then
			return false, "bad j"
		end
	end
	if data.j == nil and data.pct == nil then
		return false, "no target"
	end
	return true, nil
end

local function onPinMessage(message)
	local ok, data = pcall(HttpService.JSONDecode, HttpService, message.Data)
	if not ok or typeof(data) ~= "table" then
		return
	end
	local valid, why = checkPinMessage(data)
	if not valid then
		warn(`[TypeTorch] pin message ignored: {why}`)
		return
	end
	local kind = serverType()
	if data.b ~= myBranch or kind == "studio" or game.JobId == "" then
		return
	end
	local listed = false
	for _, jobId in data.j or {} do
		if jobId == game.JobId then
			listed = true
			break
		end
	end
	if not listed and not (data.pct ~= nil and jobBucket(game.JobId) < data.pct) then
		return
	end
	-- 0.3: prod servers act only on signed pins (and unpins), over the pin canonical string (plans/03).
	local signedOnly = requiresSignatures(myBranch)
	if signedOnly then
		local verified, whyNot = verifyPin(data)
		if not verified then
			refuse("pin", whyNot or "bad signature", { assetId = data.a, by = data.by, unpin = data.unpin or nil })
			return
		end
	end
	if not Access.isAdminUserId(data.by) then
		warn(`[TypeTorch] pin message ignored: {data.by} is not the owner or an admin`)
		return
	end
	lastPin = {
		assetId = data.a,
		unpin = data.unpin or nil,
		by = data.by,
		pct = data.pct,
		listed = listed,
		receivedMs = DateTime.now().UnixTimestampMillis,
		sentMs = data.t,
	}
	local report
	if data.unpin then
		report = unpin(nil, data.by, data.a)
	else
		-- Random picks across many public servers: spread the loads like deploys do.
		if not listed and kind == "public" then
			task.wait(math.random() * Constants.PUBLIC_JITTER_SECONDS)
		end
		report = pinArtifact(nil, data.a, { experiment = true, by = data.by, remote = true, signed = signedOnly })
	end
	lastPin.ok = report.ok
	lastPin.error = report.error
	print("[TypeTorch] pin message " .. HttpService:JSONEncode(report))
end

-- 0.3.2: game code (the framework's dev menu, admin panels) calls these from its own threads; each runs on a kernel
-- thread (busy-flag hazard) and the caller waits for the report, unless its generation is swapped out meanwhile.
local function onKernel(fn)
	return function(...)
		return callOnKernel(fn, ...)
	end
end

Api.init({
	KERNEL_API = Constants.KERNEL_API,
	KERNEL_VERSION = Constants.KERNEL_VERSION,
	Access = Access,
	Transport = Transport,
	Logs = Logs,
	serverType = serverType,
	status = status,
	branchList = branchList,
	artifacts = artifacts,
	reload = onKernel(reload),
	rollback = onKernel(rollback),
	switchBranch = onKernel(switchBranch),
	pinArtifact = onKernel(pinArtifact),
	newServer = newServer,
	requestReload = requestReload,
	unpin = onKernel(unpin),
	experiment = experimentInfo,
	-- 0.3
	KERNEL_BUILD = KERNEL_BUILD,
	keys = keysInfo,
	-- 0.3.2
	reportError = reportError,
	heartbeat = Reports.info,
	accessCode = function()
		return if serverType() == "reserved" then ownAccessCode else nil
	end,
})

-- /tt chat commands (TextChatCommand), the fallback when a generation is broken --------------------------------------

local HELP = "/tt status | branch <name> | new <branch> [assetId] | pin <assetId> | unpin | reload | rollback | dev"

local function describe(report): string
	if report.ok then
		return `now running {report.generation}`
	end
	return `failed: {report.error or "queued"}`
end

local function runCommand(player: Player, text: string)
	local words = string.split(string.gsub(text, "^%s*/tt%s*", ""), " ")
	local command = string.lower(words[1] or "")
	local argument = words[2]
	if not Access.isDev(player) then
		return
	end
	if command == "" or command == "help" then
		notice(player, HELP)
	elseif command == "status" then
		local s = status()
		local pinned = if s.experiment then ", A/B experiment" elseif s.pinned then ", pinned" else ""
		if s.unverified then
			pinned ..= ", UNVERIFIED boot (fail-safe)"
		end
		if s.localPayload then
			pinned ..= ", local payload"
		end
		local signing = if s.signedOnly then `, signed only ({s.signing.mode}{if s.rejected.total > 0 then `, {s.rejected.total} rejected` else ""})` else ""
		notice(player, `{s.serverType} server, branch {s.branch} ({s.channel or "?"}), {if s.generation then s.generation.name else "no generation"}{pinned}, up {s.uptime}s, kernel {s.kernelVersion}{if s.kernelBuild then `@{s.kernelBuild}` else ""}{signing}`)
	elseif command == "branch" and argument then
		notice(player, describe(switchBranch(player, argument)))
	elseif command == "new" and argument then
		local assetId = tonumber(words[3])
		local report = newServer(player, argument, assetId)
		if not report.ok then
			notice(player, `failed: {report.error}`)
		end
	elseif command == "pin" and tonumber(argument) then
		notice(player, describe(pinArtifact(player, tonumber(argument) :: number)))
	elseif command == "unpin" then
		notice(player, describe(unpin(player)))
	elseif command == "reload" then
		notice(player, describe(reload(player)))
	elseif command == "rollback" then
		notice(player, describe(rollback(player)))
	elseif command == "dev" then
		Transport.kernelSend(player, Constants.CHANNEL_EVENT, "dev-open")
	else
		notice(player, HELP)
	end
end

local command = Instance.new("TextChatCommand")
command.Name = "TypeTorchCommand"
command.PrimaryAlias = "/tt"
command.Triggered:Connect(function(source: TextSource, text: string)
	local player = Players:GetPlayerByUserId(source.UserId)
	if player then
		task.spawn(runCommand, player, text)
	end
end)
command.Parent = TextChatService

-- Boot ---------------------------------------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
	task.defer(sendDevStatus, player)
end)
Players.PlayerRemoving:Connect(function(player)
	lastDev[player] = nil
	clientStatus[player] = nil
end)

-- 0.3: the first key asset read runs while the registry loads; a prod server waits for it (bounded) before it checks
-- any signature, because it decides between `sig` (loaded) and `sigF` (not loaded).
local keysRead = false
task.spawn(function()
	Signing.refresh("boot")
	keysRead = true
end)

local state, err = Registry.start(Constants.CONFIG_BOOT_WAIT)
registryError = err
Access.setConfig(state, Registry.known())
localMode = localPayloadSource() ~= nil -- 0.3.1: Studio only (localPayloadSource checks IsStudio)
myBranch = chooseBranch()

-- 0.3.2 (P-K8): a subscription that fails is retried (SUBSCRIBE_RETRY_DELAYS, then the last delay) until it works;
-- until then the 60 s poll is the only way deploys arrive.
local function subscribe(topic: string, handler, label: string)
	task.spawn(function()
		local attempt = 0
		while not closing do
			local ok, subscribeError = pcall(function()
				MessagingService:SubscribeAsync(topic, handler)
			end)
			if ok then
				if attempt > 0 then
					print(`[TypeTorch] {label}: subscribed after {attempt} failed attempts`)
				end
				return
			end
			attempt += 1
			local delays = Constants.SUBSCRIBE_RETRY_DELAYS
			local delay = delays[math.min(attempt, #delays)]
			warn(`[TypeTorch] {label} unavailable (attempt {attempt}): {subscribeError}; retrying in {delay} s`)
			task.wait(delay)
		end
	end)
end
subscribe(Constants.DEPLOY_TOPIC, onDeployMessage, "deploy messages")
subscribe(Constants.PIN_TOPIC, onPinMessage, "pin messages")

-- 0.3: rekey hints (unsigned, content ignored): re-read the key asset now, rate-limited; a hint inside the window is
-- read when it opens. A key change makes the server look at its branch head again (it may be verifiable now).
local hintRetryScheduled = false
local function onRekey()
	Signing.noteHint()
	local read, changed = Signing.refresh("hint")
	if not read then
		local due = Signing.hintDue()
		if due and not hintRetryScheduled then
			hintRetryScheduled = true
			task.delay(due + 0.1, function()
				hintRetryScheduled = false
				local _, laterChanged = Signing.refresh("hint")
				if laterChanged then
					followHead("poll", true)
				end
			end)
		end
	elseif changed then
		followHead("poll", true)
	end
end
subscribe(Constants.REKEY_TOPIC, function()
	task.spawn(onRekey)
end, "rekey hints")

Registry.refreshStoredHead(myBranch, 0)
Registry.migrateLegacyHead(myBranch)

if serverType() ~= "studio" then
	local deadline = os.clock() + Constants.KEYS_BOOT_WAIT
	while not keysRead and os.clock() < deadline do
		task.wait(0.05)
	end
end
local signedBoot = requiresSignatures(myBranch)
local keys = Signing.summary()
print(`[TypeTorch] kernel {Constants.KERNEL_VERSION}{if KERNEL_BUILD then `@{KERNEL_BUILD}` else ""} (API {Constants.KERNEL_API}) on a {serverType()} server, branch {myBranch}, {if localMode then "local payload (ServerStorage.TypeTorchDev.Payload)" elseif signedBoot then `signed deploys only (keys: {keys.mode})` else "unsigned deploys allowed"}`)
if signedBoot and not Signing.configured() then
	warn(`[TypeTorch] this kernel has no KeyAssetId or FallbackPublicKey, so as a prod server it refuses every deploy. Run typetorch keys init (and keys init --fallback), then typetorch kernel deploy.`)
end

-- A stored pin (newServer with an artifact, or a pin on this private server) wins until the branch moves past it.
-- 0.3: private/<id> is game-written, so on a prod server the pin must be a signed prod deploy.
if bootPin and signedBoot and not signedProd(if typeof(bootPin.branch) == "string" then bootPin.branch else myBranch, bootPin) then
	refuse("pin", "the stored pin is not a signed prod deploy; booting the branch head", { assetId = bootPin.assetId, artifactId = bootPin.artifactId })
	bootPin = nil
end
-- 0.3 boot on a prod server (user decisions): the verified heads, newest first (signed, or the exact bootstrap match),
-- then the bootstrap head itself, then the BOOT FAIL-SAFE: the other stored heads, blind, newest first ("never boot
-- an empty game"). Each must still be Channel "prod" and only Folders and ModuleScripts at mount; a head that fails is
-- skipped for the next one. Blind trust is for this first generation only: everything after boot stays strictly
-- verified, and a blind boot doesn't move appliedSeq (a forged seq can't block the next signed deploy).
local function bootSigned()
	local tried = {}
	local function try(head, how: string): boolean
		local key = `{tostring(head.assetId)}#{tostring(head.seq)}`
		if tried[key] then
			return false
		end
		tried[key] = true
		local report = swapTo(head, "boot")
		if report.ok then
			if how ~= "blind" and typeof(head.seq) == "number" then
				appliedSeq = math.max(appliedSeq, head.seq)
			end
			return true
		end
		if how ~= "blind" then
			noteFailure(head, "boot", report) -- a verified head that failed to LOAD is retried and replaces the fallback
		end
		return false
	end
	local verified = headFor(myBranch)
	if verified and try(verified, admitted[verified] or "signed") then
		return
	end
	-- The other verified heads, newest first: stored heads, and (0.3.2, P-K3) this branch's deployment history, each
	-- trusted only when it verifies (signed prod, or the exact bootstrap match). Artifacts that failed here are skipped.
	local candidates = Registry.bootCandidates(myBranch)
	local trusted = {}
	for _, candidate in candidates do
		if trustedProd(myBranch, candidate) then
			table.insert(trusted, cloneHead(candidate))
		end
	end
	local entriesOk, entries = pcall(deploymentEntries)
	if entriesOk then
		for _, entry in entries do
			if entry.branch == myBranch and typeof(entry.assetId) == "number" then
				local head = pinHead(entry)
				head.pinned = nil
				if trustedProd(myBranch, head) then
					table.insert(trusted, head)
				end
			end
		end
	end
	table.sort(trusted, function(a, b)
		local seqA, seqB = if typeof(a.seq) == "number" then a.seq else -1, if typeof(b.seq) == "number" then b.seq else -1
		return seqA > seqB
	end)
	for _, head in trusted do
		if not failedHere[head.assetId] and try(admit(head, if signedProd(myBranch, head) then "signed" else "bootstrap"), admitted[head]) then
			return
		end
	end
	local bootstrap = bootstrapFor(myBranch)
	if bootstrap and not failedHere[bootstrap.assetId] and try(bootstrap, "bootstrap") then
		return
	end
	for _, candidate in candidates do
		if not trustedProd(myBranch, candidate) and not failedHere[candidate.assetId] then
			local head = admit(table.clone(candidate), "blind")
			if try(head, "blind") then
				warn(
					`[TypeTorch] BOOT FAIL-SAFE: no verified head for {myBranch} loaded, so this server booted the UNVERIFIED stored head {head.artifactId or `asset-{head.assetId}`} (seq {tostring(head.seq)}). Updates still need signatures; the next signed deploy replaces it.`
				)
				Registry.logEvent({ action = "booted_unverified", branch = myBranch, assetId = head.assetId, artifactId = head.artifactId, seq = head.seq, job = game.JobId })
				return
			end
		end
	end
	warn(`[TypeTorch] branch {myBranch}: nothing loaded (no verified, bootstrap or usable stored head){if err then ` (registry: {err})` else ""}; waiting for a signed deploy`)
end

local bootHead = headFor(myBranch)
if localMode then
	-- 0.3.1: Studio with ServerStorage.TypeTorchDev.Payload: mount a clone of it; deploys and the poll don't move this
	-- session, Reload remounts the local copy.
	local head = localHead()
	if head then
		swapTo(head, "boot")
	end
	if not current then
		warn(`[TypeTorch] the local payload didn't start (see above); fix it, then Stop + Play`)
	end
elseif bootPin and (not bootHead or (bootHead.seq or 0) <= (bootPin.headSeq or 0)) then
	appliedSeq = math.max(bootPin.headSeq or 0, if bootPin.branch == myBranch then bootPin.seq or 0 else 0)
	local head = table.clone(bootPin)
	head.headSeq = nil
	head.pinned = true
	if signedBoot then
		admit(head, "signed")
	end
	print(`[TypeTorch] booting pinned artifact {bootPin.artifactId or bootPin.assetId}`)
	swapTo(head, "pin")
	if not current then
		appliedSeq = -1
		-- The pinned artifact failed to start: fall back to the branch head.
		if signedBoot then
			bootSigned()
		elseif bootHead then
			followHead("boot", false)
		end
	end
elseif signedBoot then
	bootSigned()
elseif bootHead then
	followHead("boot", false)
else
	warn(`[TypeTorch] branch {myBranch} has no artifact yet{if err then ` (registry: {err})` else ""}; waiting for a deploy`)
end

-- 0.3.2 (P-K8): a stored branch that was unreadable at boot is read again by the sync loop and applied late (its pin
-- isn't: the server already runs).
local function retryPrivateRead()
	local override, readError = Registry.privateOverride(game.PrivateServerId)
	if readError then
		return
	end
	privateReadPending = false
	if not override then
		return
	end
	local branch = branchFromOverride(override)
	bootPin = nil
	if branch ~= myBranch and not localMode then
		print(`[TypeTorch] this server's stored branch is readable now: moving to {branch}`)
		myBranch = branch
		appliedSeq = -1
		followHead("branch", false)
	end
end

-- The one sync loop (0.3.2, Registry.startSync): every POLL_SECONDS the registry refreshes ConfigService (or retries
-- it), then this re-reads the stored head (the backup for missed messages) and follows it.
Registry.startSync(Constants.POLL_SECONDS, function()
	if privateReadPending then
		retryPrivateRead()
	end
	Registry.refreshStoredHead(myBranch, 0)
	followHead("poll", true)
end)

-- 0.3.2 (P-O1): the kernel's heartbeat (the first entry right after boot, then every HEARTBEAT_SECONDS +- jitter).
Reports.startHeartbeat(1 + math.random() * 2)

-- 0.3.2: one BindToClose for the server's lifetime: no more swaps, the heartbeat entry is removed, and the running
-- generation's onClose handler (api:onClose; the framework runs its modules' onStop) gets CLOSE_DEADLINE seconds.
local function onClose()
	closing = true
	local removed = false
	task.spawn(function()
		Reports.close()
		removed = true
	end)
	local generation = current
	local handler = generation and generation.closeHandler
	if handler then
		local done = false
		local thread = task.spawn(function()
			local ok, closeError = pcall(handler)
			if not ok then
				warn(`[TypeTorch] {generation.name} onClose threw: {closeError}`)
			end
			done = true
		end)
		local deadline = os.clock() + Constants.CLOSE_DEADLINE
		while not done and os.clock() < deadline do
			task.wait()
		end
		if not done then
			pcall(task.cancel, thread)
			warn(`[TypeTorch] {generation.name} onClose took more than {Constants.CLOSE_DEADLINE} s`)
		end
	end
	local deadline = os.clock() + 3
	while not removed and os.clock() < deadline do
		task.wait()
	end
end
local bound, bindError = pcall(function()
	game:BindToClose(onClose)
end)
if not bound then
	warn(`[TypeTorch] BindToClose failed: {bindError}`)
end

-- 0.3: the key asset, re-read about every 10 minutes (a rotation without a hint still lands, and shows as a change).
task.spawn(function()
	while true do
		task.wait(Constants.KEYS_REFRESH_SECONDS)
		local _, changed = Signing.refresh("periodic")
		if changed then
			followHead("poll", true)
		end
	end
end)
for _, player in Players:GetPlayers() do
	sendDevStatus(player)
end
