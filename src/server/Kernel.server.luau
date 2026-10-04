--!nonstrict
-- TypeTorch kernel (server). The only TypeTorch code baked into the place; changing it needs a server restart.
-- Design: ../../../plans/01-kernel.md. Prototype and measurements: ../../../spikes/RESULTS.md.
--
-- Boot: pick this server's branch (public -> registry default, private/reserved -> its own choice), LoadAsset the
-- branch's payload, mount it side by side (server tree in ServerStorage, client tree in ReplicatedStorage), start it
-- through a cloned Entry script. Swap: soft stop (the generation's stop function), hard stop (disable its Entry),
-- start the next one; a generation that fails to start is rolled back automatically.

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

-- Strictest of the branch channel, the artifact channel and "prod" for public servers (plans/10).
local function effectiveChannel(branch: string, artifactChannel: string?): string
	if serverType() == "public" then
		return "prod"
	end
	if Registry.channelOf(branch) == "prod" or artifactChannel == "prod" then
		return "prod"
	end
	return "dev"
end

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

local function mount(payload: Instance, head)
	local artifactId = payload:GetAttribute("ArtifactId")
	if head.artifactId and artifactId ~= head.artifactId then
		error(`asset {head.assetId} is artifact {artifactId}, expected {head.artifactId}`)
	end
	artifactId = artifactId or `asset-{head.assetId}`
	-- Pins on public servers carry requireChannel = "prod": the payload's own Channel attribute must agree.
	local payloadChannel = payload:GetAttribute("Channel")
	if head.requireChannel and payloadChannel ~= nil and payloadChannel ~= head.requireChannel then
		error(`artifact {artifactId} is {payloadChannel}-channel; this server only takes {head.requireChannel}`)
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
		local ok, err = pcall(generation.stop, info)
		if not ok then
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
	current.head = table.clone(current.head)
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
	busy = true
	local report = { reason = reason, assetId = head.assetId, artifactId = head.artifactId, ok = false }
	local old = current
	local oldStopped = false
	if old and not announced then
		notifyPending(head, reason, 0)
	end
	local ok, err = pcall(function()
		local loadStarted = os.clock()
		local payload = loadPayload(head.assetId)
		report.loadSeconds = os.clock() - loadStarted
		local generation = mount(payload, head)
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

-- Moves to the branch head when the registry has a newer seq than this server last applied.
local function followHead(reason: string, jitter: boolean?)
	local head = Registry.branchHead(myBranch)
	if not head or typeof(head.assetId) ~= "number" then
		return
	end
	local seq = head.seq or 0
	if seq <= appliedSeq and current then
		return
	end
	if current and head.artifactId and head.artifactId == current.artifact.id then
		if current.pinned and inRollout(head.rollout) then
			setHold(false, nil) -- the pinned artifact is the head now (seq > appliedSeq here)
		end
		appliedSeq = seq
		return
	end
	-- 0.2.3: a deploy rolled out to some servers only (`ro`). The others keep what they run (appliedSeq stays, so a
	-- wider rollout of the same deploy, or the next deploy, still reaches them); new servers boot it (no `current`).
	if current and not inRollout(head.rollout) then
		return
	end
	appliedSeq = seq
	local announced = false
	if jitter and serverType() == "public" then
		local delay = math.random() * Constants.PUBLIC_JITTER_SECONDS
		if current then
			notifyPending(head, reason, delay)
			announced = true
		end
		task.wait(delay)
	end
	swapTo(head, reason, nil, announced)
end

Registry.onChange(function(state)
	Access.setConfig(state)
	for _, player in Players:GetPlayers() do
		sendDevStatus(player)
	end
	task.spawn(followHead, "registry", true)
end)

-- Deploy messages: {b = branch, a = assetId, i = artifactId, s = seq, c = commit, ch = channel, t = sent ms,
-- r = rollback?, ro = rollout % (0.2.3, 1-99)?}. Every server records the head (any branch) so servers started later
-- boot it even without a ConfigService registry. With `ro`, only servers whose jobBucket is below it swap; the others
-- keep their current artifact (plans/12 P-R1).
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
		t = if typeof(data.t) == "number" then data.t else nil,
	})
	if data.b ~= myBranch then
		return
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
	print(`[TypeTorch] {if data.r then "rollback" else "deploy"} message for {data.b}: {data.i}{if rollout then ` ({rollout}% rollout)` else ""}`)
	appliedSeq = math.max(appliedSeq, seq or appliedSeq)
	local head = { assetId = data.a, artifactId = data.i, seq = seq, commit = data.c, channel = channel, branch = data.b, deployedAt = sentAt:ToIsoDate(), rollout = rollout }
	local reason = if data.r then "rollback" else "deploy"
	local announced = false
	if serverType() == "public" then
		local delay = math.random() * Constants.PUBLIC_JITTER_SECONDS
		if current then
			notifyPending(head, reason, delay)
			announced = true
		end
		task.wait(delay)
	end
	swapTo(head, reason, nil, announced)
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
-- (this server's current generation).
local function artifacts()
	local list = deploymentEntries()
	for _, entry in list do
		entry.channel = entry.channel or Registry.channelOf(entry.branch)
		entry.live = sameDeploy(Registry.branchHead(entry.branch), entry)
		entry.running = current ~= nil and sameDeploy(current.artifact, entry)
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
	local head = Registry.branchHead(myBranch)
	if not head then
		return { ok = false, error = `branch {myBranch} has no artifact` }
	end
	local kind = serverType()
	if storedPin and (kind == "private" or kind == "reserved") then
		-- Back to the branch head for good: drop the stored pin (keeps the branch).
		if Registry.setPrivateBranch(game.PrivateServerId, myBranch, if player then player.UserId else 0) then
			storedPin = false
		end
	end
	appliedSeq = head.seq or appliedSeq
	return swapTo(head, "reload", if player then player.UserId else nil)
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
	local head = Registry.branchHead(myBranch)
	if not head or typeof(head.assetId) ~= "number" or sameDeploy(current.artifact, head) then
		setHold(false, nil) -- nothing else to run: just stop holding
		return { ok = true, generation = current.name, artifactId = current.artifact.id }
	end
	appliedSeq = math.max(appliedSeq, head.seq or 0)
	return swapTo(head, "reload", by)
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
	local head = Registry.branchHead(branch)
	if not head then
		return { ok = false, error = `no artifact on branch {branch}` }
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
			artifact = current.artifact,
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
	}
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
-- TRUST: unsigned, like deploy messages (plans/12 S-C2 stays open): anything that can publish to this universe's
-- MessagingService (any server's code, an Open Cloud key) can send one. Defense in depth only: strict fields, a
-- 120 s freshness window, and `by` must be the owner or an admin by the registry. The framework's Admin > Servers
-- publishes them (admin.ab, owner/admin only, rate-limited).

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
		report = pinArtifact(nil, data.a, { experiment = true, by = data.by, remote = true })
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
		notice(player, `{s.serverType} server, branch {s.branch} ({s.channel or "?"}), {if s.generation then s.generation.name else "no generation"}{pinned}, up {s.uptime}s`)
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

local state, err = Registry.start()
registryError = err
Access.setConfig(state)
myBranch = chooseBranch()
print(`[TypeTorch] kernel {Constants.KERNEL_VERSION} (API {Constants.KERNEL_API}) on a {serverType()} server, branch {myBranch}`)

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

Registry.refreshStoredHead(myBranch, 0)
Registry.migrateLegacyHead(myBranch)
-- A stored pin (newServer with an artifact, or a pin on this private server) wins until the branch moves past it.
local bootHead = Registry.branchHead(myBranch)
if bootPin and (not bootHead or (bootHead.seq or 0) <= (bootPin.headSeq or 0)) then
	appliedSeq = math.max(bootPin.headSeq or 0, if bootPin.branch == myBranch then bootPin.seq or 0 else 0)
	local head = table.clone(bootPin)
	head.headSeq = nil
	head.pinned = true
	print(`[TypeTorch] booting pinned artifact {bootPin.artifactId or bootPin.assetId}`)
	swapTo(head, "pin")
	if not current and bootHead then
		followHead("boot", false) -- the pinned artifact failed to start: fall back to the branch head
	end
elseif bootHead then
	followHead("boot", false)
else
	warn(`[TypeTorch] branch {myBranch} has no artifact yet{if err then ` (registry: {err})` else ""}; waiting for a deploy`)
end

-- Backup for missed messages: re-read the stored head (ConfigService has its own refresh in Registry.start).
task.spawn(function()
	while true do
		task.wait(Constants.POLL_SECONDS)
		Registry.refreshStoredHead(myBranch, 0)
		followHead("poll", true)
	end
end)
for _, player in Players:GetPlayers() do
	sendDevStatus(player)
end
