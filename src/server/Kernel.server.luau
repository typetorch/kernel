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

local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
Signing.init(kernelFolder)
local KERNEL_BUILD = kernelFolder:GetAttribute("KernelCommit") -- P-V1: short commit ("abc1234", "*" = dirty)
local KERNEL_HASH = kernelFolder:GetAttribute("KernelHash")
KERNEL_BUILD = if typeof(KERNEL_BUILD) == "string" and KERNEL_BUILD ~= "" then KERNEL_BUILD else nil
KERNEL_HASH = if typeof(KERNEL_HASH) == "string" and KERNEL_HASH ~= "" then KERNEL_HASH else nil

local Access = require(script.Parent.Access)
local Api = require(script.Parent.Api)
local Logs = require(script.Parent.Logs)
local Registry = require(script.Parent.Registry)
local Transport = require(script.Parent.Transport)

Logs.start()

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

local function serverType(): string
	if RunService:IsStudio() then
		return "studio"
	end
	if game.PrivateServerId ~= "" then
		return if game.PrivateServerOwnerId ~= 0 then "private" else "reserved"
	end
	return "public"
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

-- A branch's channel from sources game code can't write: ConfigService's `channels`, the default branch (prod), or a
-- signed prod head of that branch. Unsigned stored heads don't count (game code can write them).
local function trustedChannelOf(branch: string?): string
	if typeof(branch) ~= "string" then
		return "dev"
	end
	local state = Registry.state()
	local configured = state.channels[branch]
	if configured == "prod" or configured == "dev" then
		return configured
	end
	if branch == state.defaultBranch then
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
-- head), "pin" (a signed remote pin), "admin" (a dev menu or /tt pin by the owner/an admin in this server).
local admitted: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

local function admit(head, how: string)
	admitted[head] = how
	return head
end

-- A copy of a head that keeps its admission.
local function cloneHead(head)
	local copy = table.clone(head)
	admitted[copy] = admitted[head]
	return copy
end

-- The newest signed prod head of `branch` (ConfigService or stored), admitted, or nil.
local function signedHead(branch: string)
	local head = Registry.branchHead(branch, function(candidate)
		return signedProd(branch, candidate)
	end)
	return if head then admit(head, "signed") else nil
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
	if signedProd(branch, head) then
		return "trusted"
	end
	local state = Registry.state()
	local configured = state.channels[branch]
	if configured == "prod" or (configured == nil and branch == state.defaultBranch) then
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
-- branch (never from head fields, which may come from game-written stores).
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
		artifact = {
			id = artifactId,
			assetId = head.assetId,
			channel = artifactChannel or Registry.channelOf(head.branch or branch),
			branch = head.branch or branch,
			commit = payload:GetAttribute("Commit") or head.commit,
			commitHash = head.commitHash,
			builtAt = payload:GetAttribute("BuiltAt"),
			seq = head.seq,
		},
	}
	-- 0.2.2: the artifact's identity on both trees, so the client API can report it too.
	local artifact = generation.artifact
	for _, tree in { serverTree, clientTree } do
		for name, value in { AssetId = artifact.assetId, Commit = artifact.commit, CommitHash = artifact.commitHash, Branch = artifact.branch, Channel = artifact.channel, BuiltAt = artifact.builtAt, Seq = artifact.seq } do
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
	return result[1], result[2]
end

-- Soft stop, then hard stop. Returns seconds taken. `info` (0.2.2: {reason, branch, next}) goes to the generation's
-- stop function, so it can tell game code what replaces it; older frameworks ignore it.
local function stopGeneration(generation, info): number
	local started = os.clock()
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

-- Swap to a registry head { assetId, artifactId?, seq?, ... }. Returns a report table. `by` is the user id that asked
-- (dev menu, /tt, game code); `announced` means notifyPending already ran for this swap.
local swapTo
swapTo = function(head, reason: string, by: number?, announced: boolean?)
	if busy then
		pendingHead = { head = head, reason = reason, by = by }
		return { ok = false, queued = true }
	end
	-- 0.3: the last gate on prod servers. Every way in (deploy messages, heads, pins, reloads, rollbacks) admits the
	-- head table it checked; anything else is refused here.
	local signedOnly = requiresSignatures(myBranch)
	if signedOnly and not admitted[head] then
		refuse("swap", "not a signed or admin-approved head", { reason = reason, assetId = head.assetId, artifactId = head.artifactId })
		return { ok = false, reason = reason, assetId = head.assetId, artifactId = head.artifactId, error = "refused: not signed", stage = "gate" }
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
		local payload = loadPayload(head.assetId)
		report.loadSeconds = os.clock() - loadStarted
		report.stage = "mount"
		-- Signed deploys and heads on prod servers: Channel exactly "prod"; admin pins keep their own rule
		-- (head.requireChannel); experiments (signed remote pins, owner/admin pins) may be any channel.
		local how = admitted[head]
		local generation = mount(payload, head, {
			requireChannel = if signedOnly and how == "signed" then "prod" else nil,
			modulesOnly = signedOnly,
		})
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
		local started, startError = startGeneration(generation)
		report.swapSeconds = os.clock() - swapStarted
		if not started then
			report.error = startError
			warn(`[TypeTorch] {generation.name} failed to start: {startError}`)
			stopGeneration(generation)
			if old then
				-- Automatic rollback: load the previous head again (fresh instances, fresh require cache).
				report.rollbackTo = old.artifact.id
				Registry.logEvent({ action = "auto_rollback", from = generation.artifact.id, to = old.artifact.id, error = startError, job = game.JobId })
				task.defer(function()
					swapTo(old.head, "auto-rollback")
				end)
			end
			return
		end
		report.stage = nil
		-- Same table the generation got as api.start, so it can read the whole swap time once it is running.
		generation.start.swapSeconds = report.swapSeconds
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
	if not ok then
		report.error = tostring(err)
		warn(`[TypeTorch] swap failed: {err}`)
	end
	if not report.ok and old and not oldStopped then
		notifyPending(head, reason, 0, true) -- load or mount failed: the old generation keeps running
	end
	print("[TypeTorch] swap " .. HttpService:JSONEncode(report))
	for _, player in Players:GetPlayers() do
		sendDevStatus(player)
	end
	if pendingHead then
		local next = pendingHead
		pendingHead = nil
		task.defer(swapTo, next.head, next.reason, next.by)
	end
	return report
end

-- Branch selection and updates --------------------------------------------------------------------------------------

local function chooseBranch(): string
	local state = Registry.state()
	local kind = serverType()
	if kind == "private" or kind == "reserved" then
		local override = Registry.privateOverride(game.PrivateServerId)
		if override then
			-- 0.3: private/<id> is written by game servers, so in-universe code could rewrite it. A player-owned private
			-- server follows a stored branch other than the default only when its owner is a dev; otherwise game code
			-- could move a server full of players to a dev branch (which takes unsigned deploys).
			if kind == "private" and override.branch ~= state.defaultBranch and not Access.isDevUserId(game.PrivateServerOwnerId) then
				refuse("private-branch", `the owner ({game.PrivateServerOwnerId}) is not a dev; this server stays on {state.defaultBranch}`, { branch = override.branch })
				return state.defaultBranch
			end
			bootPin = override.pin
			storedPin = override.pin ~= nil
			return override.branch
		end
	elseif kind == "studio" then
		local dev = ServerStorage:FindFirstChild("TypeTorchDev")
		local branch = dev and dev:GetAttribute("Branch")
		if typeof(branch) == "string" then
			return branch
		end
	end
	return state.defaultBranch
end

-- 0.3: every deploy (message or head) goes through one worker, newest seq first. appliedSeq moves only when the swap
-- succeeded (audit P-K2). A payload that fails to LOAD is retried after LOAD_RETRY_DELAYS; one that fails to mount or
-- start is not retried, and the poll leaves it alone until a newer deploy (`failing`).
local wanted = nil -- { head, reason, jitter }: the newest deploy this server should move to
local workerRunning = false
local failing = nil -- { seq, assetId, attempts, nextAt }

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
		warn(`[TypeTorch] deploy #{head.seq} ({head.artifactId or head.assetId}) {what}; this server keeps {if current then current.artifact.id else "nothing"} until a newer deploy`)
		Registry.logEvent({ action = "deploy_failed", seq = head.seq, assetId = head.assetId, artifactId = head.artifactId, stage = report.stage, attempts = failing.attempts, error = report.error, job = game.JobId })
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
	while wanted do
		local job = wanted
		local head = job.head
		local announced = false
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
		if current and head.artifactId and head.artifactId == current.artifact.id then
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
		elseif not report.queued then
			noteFailure(head, job.reason, report)
		end
	end
	workerRunning = false
end

-- Heads this server already reported as refused (branch#seq@asset), so the 60 s poll doesn't repeat them.
local refusedHeads: { [string]: boolean } = {}

-- Moves to the branch head when the registry has a newer seq than this server last applied. 0.3: prod servers only
-- consider signed prod heads; a newer head that isn't one is reported (once) and triggers one rate-limited key re-read.
local function followHead(reason: string, jitter: boolean?)
	if not myBranch then
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
	if current and head.artifactId and head.artifactId == current.artifact.id then
		if current.pinned and inRollout(rollout) then
			setHold(false, nil) -- the pinned artifact is the head now (seq > appliedSeq here)
		end
		appliedSeq = seq
		return
	end
	-- 0.2.3: a deploy rolled out to some servers only (`ro`). The others keep what they run (appliedSeq stays, so a
	-- wider rollout of the same deploy, or the next deploy, still reaches them); new servers boot it (no `current`).
	if current and not inRollout(rollout) then
		return
	end
	want(head, reason, jitter == true)
end

Registry.onChange(function(state)
	Access.setConfig(state)
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
			rollback = data.r and true or nil,
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
			t = previous.t,
			sig = previous.sig,
			sigF = previous.sigF,
		})
	end
	Registry.recordDeployments(entries)
	Registry.saveHead(data.b, {
		assetId = data.a,
		artifactId = data.i,
		seq = seq or 0,
		commit = data.c,
		channel = channel,
		deployedAt = DateTime.now():ToIsoDate(),
		rollback = data.r and true or nil,
		rollout = rollout,
		t = t,
		sig = sig,
		sigF = sigF,
	})
	if data.b ~= myBranch then
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
			return
		end
		if data.ch ~= "prod" then
			refuse("deploy", `channel {tostring(data.ch)}, not prod`, detail)
			return
		end
		if typeof(seq) ~= "number" or seq <= appliedSeq then
			refuse("deploy", `seq {tostring(seq)} is not newer than the applied {appliedSeq} (replay?)`, detail)
			return
		end
	end
	if current and data.i == current.artifact.id then
		-- Already running it. A newer deploy of the pinned (or experiment) artifact ends the hold: it is the head now.
		if current.pinned and seq and seq > appliedSeq and inRollout(rollout) then
			setHold(false, nil)
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
		return
	end
	print(`[TypeTorch] {if data.r then "rollback" else "deploy"} message for {data.b}: {data.i}{if rollout then ` ({rollout}% rollout)` else ""}{if signedOnly then " (signed)" else ""}`)
	local head = {
		assetId = data.a,
		artifactId = data.i,
		seq = seq,
		commit = data.c,
		channel = channel,
		branch = data.b,
		deployedAt = sentAt:ToIsoDate(),
		rollout = rollout,
		rollback = data.r and true or nil,
		t = t,
		sig = sig,
		sigF = sigF,
	}
	if signedOnly then
		admit(head, "signed")
	end
	failing = nil -- a new deploy message: its own retries
	want(head, if data.r then "rollback" else "deploy", true)
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

local function reload(player: Player?)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	local head = headFor(myBranch)
	if not head then
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
local function pinArtifact(player: Player?, assetId: number, options)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
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
	-- 0.3: on prod servers a pin is a way in too: a signed remote pin (onPinMessage checked it), or a dev/admin in this
	-- server (checked above, Roblox-authenticated). Nothing else.
	if requiresSignatures(myBranch) then
		if typeof(options) == "table" and options.signed == true then
			admit(head, "pin")
		elseif player then
			admit(head, "admin")
		else
			refuse("pin", "an unsigned pin on a prod server", { assetId = assetId, by = by })
			return { ok = false, error = "refused: prod servers take only signed pins" }
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
	local head = headFor(myBranch)
	if not head or typeof(head.assetId) ~= "number" or sameDeploy(current.artifact, head) then
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
-- a kernel thread (this BindableEvent's handler): the caller is a thread of the generation the reload stops, and the
-- hard stop would kill it, and the swap with it, halfway through.
local reloadRequests = Instance.new("BindableEvent")
reloadRequests.Event:Connect(function(player: Player)
	reload(player)
end)
local function requestReload(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return { ok = false, error = "bad player" }
	end
	if not Access.isAdmin(player) then
		return { ok = false, error = "only the owner or admins can reload" }
	end
	if not Registry.branchHead(myBranch) then
		return { ok = false, error = `branch {myBranch} has no artifact` }
	end
	reloadRequests:Fire(player)
	return { ok = true, queued = true, reason = "reload" }
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
	local saved, err = Registry.setPrivateBranch(privateServerId, branch, player.UserId, pin)
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

-- The running artifact for status(): a copy with `verified` (0.3, { main, fallback } or nil for unsigned).
local function runningArtifact()
	if not current then
		return nil
	end
	local artifact = table.clone(current.artifact)
	artifact.verified = Signing.headSignatures(artifact.branch or myBranch, current.head)
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
		signing = Signing.summary(),
		rejected = rejectedInfo(),
	}
end

-- 0.3: the trust state for devs (api:keys(); the dev menu's Artifact > Signing): Signing.keys() plus this server's
-- rejections and whether it requires signatures.
local function keysInfo()
	local info = Signing.keys()
	info.signedOnly = requiresSignatures(myBranch)
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
	reload = reload,
	rollback = rollback,
	switchBranch = switchBranch,
	pinArtifact = pinArtifact,
	newServer = newServer,
	requestReload = requestReload,
	unpin = unpin,
	experiment = experimentInfo,
	-- 0.3
	KERNEL_BUILD = KERNEL_BUILD,
	keys = keysInfo,
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
Access.setConfig(state)
myBranch = chooseBranch()

task.spawn(function()
	local ok, subscribeError = pcall(function()
		MessagingService:SubscribeAsync(Constants.DEPLOY_TOPIC, onDeployMessage)
	end)
	if not ok then
		warn(`[TypeTorch] deploy messages unavailable: {subscribeError}`)
	end
end)
task.spawn(function()
	local ok, subscribeError = pcall(function()
		MessagingService:SubscribeAsync(Constants.PIN_TOPIC, onPinMessage)
	end)
	if not ok then
		warn(`[TypeTorch] pin messages unavailable: {subscribeError}`)
	end
end)

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
task.spawn(function()
	local ok, subscribeError = pcall(function()
		MessagingService:SubscribeAsync(Constants.REKEY_TOPIC, function()
			task.spawn(onRekey)
		end)
	end)
	if not ok then
		warn(`[TypeTorch] rekey hints unavailable: {subscribeError}`)
	end
end)

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
print(`[TypeTorch] kernel {Constants.KERNEL_VERSION}{if KERNEL_BUILD then `@{KERNEL_BUILD}` else ""} (API {Constants.KERNEL_API}) on a {serverType()} server, branch {myBranch}, {if signedBoot then `signed deploys only (keys: {keys.mode})` else "unsigned deploys allowed"}`)
if signedBoot and not Signing.configured() then
	warn(`[TypeTorch] this kernel has no KeyAssetId or FallbackPublicKey, so as a prod server it refuses every deploy. Run typetorch keys init (and keys init --fallback), then typetorch kernel deploy.`)
end

-- A stored pin (newServer with an artifact, or a pin on this private server) wins until the branch moves past it.
-- 0.3: private/<id> is game-written, so on a prod server the pin must be a signed prod deploy.
if bootPin and signedBoot and not signedProd(if typeof(bootPin.branch) == "string" then bootPin.branch else myBranch, bootPin) then
	refuse("pin", "the stored pin is not a signed prod deploy; booting the branch head", { assetId = bootPin.assetId, artifactId = bootPin.artifactId })
	bootPin = nil
end
local bootHead = headFor(myBranch)
if bootPin and (not bootHead or (bootHead.seq or 0) <= (bootPin.headSeq or 0)) then
	appliedSeq = math.max(bootPin.headSeq or 0, if bootPin.branch == myBranch then bootPin.seq or 0 else 0)
	local head = table.clone(bootPin)
	head.headSeq = nil
	head.pinned = true
	if signedBoot then
		admit(head, "signed")
	end
	print(`[TypeTorch] booting pinned artifact {bootPin.artifactId or bootPin.assetId}`)
	swapTo(head, "pin")
	if not current and bootHead then
		appliedSeq = -1
		followHead("boot", false) -- the pinned artifact failed to start: fall back to the branch head
	end
elseif bootHead then
	followHead("boot", false)
else
	local why = if signedBoot then "no signed prod artifact" else "no artifact"
	warn(`[TypeTorch] branch {myBranch} has {why} yet{if err then ` (registry: {err})` else ""}; waiting for a deploy`)
	if signedBoot then
		followHead("boot", false) -- reports a newer unsigned head, if there is one
	end
end

-- Backup for missed messages: re-read the stored head (ConfigService has its own refresh in Registry.start).
task.spawn(function()
	while true do
		task.wait(Constants.POLL_SECONDS)
		Registry.refreshStoredHead(myBranch, 0)
		followHead("poll", true)
	end
end)

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
