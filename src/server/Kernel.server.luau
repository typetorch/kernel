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

local function notice(player: Player, text: string)
	Transport.kernelSend(player, Constants.CHANNEL_NOTICE, text)
end

local function sendDevStatus(player: Player)
	local dev, reason, role = Access.check(player)
	Transport.kernelSend(player, Constants.CHANNEL_DEV, {
		dev = dev,
		reason = reason,
		role = role,
		channel = if current then current.channel else nil,
	})
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

	local artifactChannel = payload:GetAttribute("Channel")
	local branch = myBranch
	local generation = {
		name = name,
		number = generationCount,
		branch = branch,
		channel = effectiveChannel(branch, artifactChannel),
		head = head,
		startedAt = os.time(),
		serverTree = serverTree,
		clientTree = clientTree,
		artifact = {
			id = artifactId,
			assetId = head.assetId,
			channel = artifactChannel or Registry.channelOf(branch),
			branch = branch,
			commit = payload:GetAttribute("Commit") or head.commit,
			commitHash = head.commitHash,
			builtAt = payload:GetAttribute("BuiltAt"),
			seq = head.seq,
		},
	}
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

-- Soft stop, then hard stop. Returns seconds taken.
local function stopGeneration(generation): number
	local started = os.clock()
	Transport.detach()
	if generation.stop then
		local ok, err = pcall(generation.stop)
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
	replicatedRoot:SetAttribute("ArtifactId", generation.artifact.id)
	replicatedRoot:SetAttribute("Branch", generation.branch)
	replicatedRoot:SetAttribute("Channel", generation.channel)
	replicatedRoot:SetAttribute("ActiveGeneration", generation.name)
end

-- Swap to a registry head { assetId, artifactId?, seq?, ... }. Returns a report table.
local swapTo
swapTo = function(head, reason: string)
	if busy then
		pendingHead = { head = head, reason = reason }
		return { ok = false, queued = true }
	end
	busy = true
	local report = { reason = reason, assetId = head.assetId, artifactId = head.artifactId, ok = false }
	local old = current
	local ok, err = pcall(function()
		local loadStarted = os.clock()
		local payload = loadPayload(head.assetId)
		report.loadSeconds = os.clock() - loadStarted
		local generation = mount(payload, head)

		local swapStarted = os.clock()
		if old then
			report.stopSeconds = stopGeneration(old)
			current = nil
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
		current = generation
		table.insert(history, {
			name = generation.name,
			artifactId = generation.artifact.id,
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
	print("[TypeTorch] swap " .. HttpService:JSONEncode(report))
	for _, player in Players:GetPlayers() do
		sendDevStatus(player)
	end
	if pendingHead then
		local next = pendingHead
		pendingHead = nil
		task.defer(swapTo, next.head, next.reason)
	end
	return report
end

-- Branch selection and updates --------------------------------------------------------------------------------------

local function chooseBranch(): string
	local state = Registry.state()
	local kind = serverType()
	if kind == "private" or kind == "reserved" then
		local branch = Registry.privateBranch(game.PrivateServerId)
		if branch then
			return branch
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
		appliedSeq = seq
		return
	end
	appliedSeq = seq
	if jitter and serverType() == "public" then
		task.wait(math.random() * Constants.PUBLIC_JITTER_SECONDS)
	end
	swapTo(head, reason)
end

Registry.onChange(function(state)
	Access.setConfig(state)
	for _, player in Players:GetPlayers() do
		sendDevStatus(player)
	end
	task.spawn(followHead, "registry", true)
end)

-- Deploy messages: {b = branch, a = assetId, i = artifactId, s = seq, t = sent ms, r = rollback?}.
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
	if data.b ~= myBranch or typeof(data.a) ~= "number" then
		return
	end
	if current and data.i == current.artifact.id then
		appliedSeq = math.max(appliedSeq, tonumber(data.s) or appliedSeq)
		return
	end
	print(`[TypeTorch] {if data.r then "rollback" else "deploy"} message for {data.b}: {data.i}`)
	appliedSeq = math.max(appliedSeq, tonumber(data.s) or appliedSeq)
	if serverType() == "public" then
		task.wait(math.random() * Constants.PUBLIC_JITTER_SECONDS)
	end
	swapTo({ assetId = data.a, artifactId = data.i, seq = data.s, commit = data.c }, if data.r then "rollback" else "deploy")
end

-- Control (dev menu, /tt) ------------------------------------------------------------------------------------------

local function requireDev(player: Player?): (boolean, string?)
	if player and not Access.isDev(player) then
		return false, "not a dev"
	end
	return true, nil
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
	appliedSeq = head.seq or appliedSeq
	return swapTo(head, "reload")
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
			return swapTo(entry.head, "server-rollback")
		end
	end
	return { ok = false, error = "no earlier artifact on this server" }
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
	local head = Registry.branchHead(branch)
	if not head then
		return { ok = false, error = `no artifact on branch {branch}` }
	end
	if kind ~= "studio" then
		local saved, err = Registry.setPrivateBranch(game.PrivateServerId, branch, if player then player.UserId else 0)
		if not saved then
			return { ok = false, error = `could not save the branch: {err}` }
		end
	end
	myBranch = branch
	appliedSeq = head.seq or 0
	return swapTo(head, "branch")
end

local function newServer(player: Player, branch: string)
	local allowed, why = requireDev(player)
	if not allowed then
		return { ok = false, error = why }
	end
	if not Registry.branchHead(branch) then
		return { ok = false, error = `no artifact on branch {branch}` }
	end
	if RunService:IsStudio() then
		return { ok = false, error = "teleports don't work in Studio" }
	end
	local ok, code, privateServerId = pcall(TeleportService.ReserveServer, TeleportService, game.PlaceId)
	if not ok then
		return { ok = false, error = tostring(code) }
	end
	local saved, err = Registry.setPrivateBranch(privateServerId, branch, player.UserId)
	if not saved then
		return { ok = false, error = `could not save the branch: {err}` }
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	local teleported, teleportError = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, { player }, options)
	return { ok = teleported, error = if teleported then nil else tostring(teleportError), branch = branch }
end

local function branchList()
	local list = {}
	for name, head in Registry.state().branches do
		table.insert(list, {
			name = name,
			channel = Registry.channelOf(name),
			artifactId = head.artifactId,
			commit = head.commit,
			seq = head.seq,
			deployedAt = head.deployedAt,
			by = head.by,
		})
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
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
	}
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
	reload = reload,
	rollback = rollback,
	switchBranch = switchBranch,
	newServer = newServer,
})

-- /tt chat commands (TextChatCommand), the fallback when a generation is broken --------------------------------------

local HELP = "/tt status | branch <name> | new <branch> | reload | rollback | dev"

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
		notice(player, `{s.serverType} server, branch {s.branch} ({s.channel or "?"}), {if s.generation then s.generation.name else "no generation"}, up {s.uptime}s`)
	elseif command == "branch" and argument then
		notice(player, describe(switchBranch(player, argument)))
	elseif command == "new" and argument then
		local report = newServer(player, argument)
		if not report.ok then
			notice(player, `failed: {report.error}`)
		end
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

if Registry.branchHead(myBranch) then
	followHead("boot", false)
else
	warn(`[TypeTorch] branch {myBranch} has no artifact yet{if err then ` (registry: {err})` else ""}; waiting for a deploy`)
end
for _, player in Players:GetPlayers() do
	sendDevStatus(player)
end
