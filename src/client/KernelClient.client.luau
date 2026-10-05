--!nonstrict
-- TypeTorch kernel (client). Follows ReplicatedStorage.TypeTorch's `ActiveGeneration` attribute: stops the running
-- client generation (soft stop, then disable its ClientEntry clone), waits for the new client tree, and starts it
-- through a fresh ClientEntry clone in PlayerScripts. Also routes the kernel's stable remotes, keeps a log ring buffer,
-- and shows kernel notices (/tt replies) as system chat messages.

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer
local kernelShared = ReplicatedStorage:WaitForChild("TypeTorchKernelShared")
local Constants = require(kernelShared:WaitForChild("Constants"))
local ClientApi = require(kernelShared:WaitForChild("ClientApi"))
local template = kernelShared:WaitForChild("ClientEntry")
local root = ReplicatedStorage:WaitForChild("TypeTorch")
local generations = root:WaitForChild("Generations")
local net: RemoteEvent = root:WaitForChild("Net")
local netU: UnreliableRemoteEvent = root:WaitForChild("NetU")

-- Logs ------------------------------------------------------------------------------------------------------------
local CAPACITY = 300
local logEntries = {}
local nextLog = 1
local KINDS = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}
LogService.MessageOut:Connect(function(message, messageType)
	logEntries[(nextLog - 1) % CAPACITY + 1] = { i = nextLog, t = os.time(), kind = KINDS[messageType] or "output", text = string.sub(message, 1, 2000) }
	nextLog += 1
end)
local logs = {}
function logs.since(since, limit)
	local from = math.max((since or 0) + 1, nextLog - CAPACITY)
	local to = nextLog - 1
	if limit then
		from = math.max(from, to - limit + 1)
	end
	local result = {}
	for index = from, to do
		local entry = logEntries[(index - 1) % CAPACITY + 1]
		if entry and entry.i == index then
			table.insert(result, entry)
		end
	end
	return result
end

-- Transport ---------------------------------------------------------------------------------------------------------
local acceptArtifact = nil
local handler = nil
local devStatus = { dev = false }
local eventListeners = {}
local current = nil -- the running client generation (see Generations below)

local function systemMessage(text: string)
	local channels = TextChatService:FindFirstChild("TextChannels")
	local general = channels and channels:FindFirstChild("RBXGeneral")
	if general then
		general:DisplaySystemMessage(`[TypeTorch] {text}`)
	else
		print(`[TypeTorch] {text}`)
	end
end

local function onClientEvent(artifactId, channel, ...)
	if artifactId == "*" then
		if channel == Constants.CHANNEL_NOTICE then
			systemMessage(tostring((...)))
		elseif channel == Constants.CHANNEL_DEV then
			local value = ...
			if typeof(value) == "table" then
				local before = devStatus
				devStatus = value
				if current and current.devHandler and (before.dev ~= value.dev or before.role ~= value.role) then
					task.spawn(current.devHandler, table.clone(value))
				end
			end
		elseif channel == Constants.CHANNEL_PENDING then
			local info = ...
			if typeof(info) == "table" and current and current.pendingHandler then
				task.spawn(current.pendingHandler, info)
			end
		elseif channel == Constants.CHANNEL_EVENT then
			local name = ...
			for _, listener in eventListeners do
				task.spawn(listener, name)
			end
		end
		return
	end
	if channel == Constants.CHANNEL_RESYNC then
		return -- the server already runs a newer generation; ActiveGeneration will move us
	end
	if handler and artifactId == acceptArtifact then
		handler(channel, ...)
	end
end
net.OnClientEvent:Connect(onClientEvent)
netU.OnClientEvent:Connect(onClientEvent)

local transport = {}
function transport.attach(artifactId, fn)
	acceptArtifact = artifactId
	handler = fn
end
function transport.send(channel, ...)
	net:FireServer(acceptArtifact, channel, ...)
end
function transport.sendUnreliable(channel, ...)
	netU:FireServer(acceptArtifact, channel, ...)
end

ClientApi.init({
	KERNEL_API = Constants.KERNEL_API,
	KERNEL_VERSION = Constants.KERNEL_VERSION,
	transport = transport,
	logs = logs,
	devStatus = function()
		return table.clone(devStatus)
	end,
	pinned = function()
		return root:GetAttribute("Pinned") == true
	end,
	onKernelEvent = function(fn)
		table.insert(eventListeners, fn)
		return function()
			local index = table.find(eventListeners, fn)
			if index then
				table.remove(eventListeners, index)
			end
		end
	end,
})

-- Generations -------------------------------------------------------------------------------------------------------
local playerScripts = player:WaitForChild("PlayerScripts")
local lastGeneration = nil -- the last client generation that started, for api.start.previous
local generationCount = 0
local switching = false
local retryFolder = nil -- 0.3.2: fresh copies of client trees for the one retry (client-only)

-- `info` (0.2.2: {reason, branch, next}) goes to the generation's stop function; older frameworks ignore it.
local function stopCurrent(info)
	if not current then
		return
	end
	handler = nil
	if current.stop then
		local ok, err = pcall(current.stop, info)
		if not ok then
			warn(`[TypeTorch] {current.name} stop threw: {err}`)
		end
	end
	current.entry.Enabled = false
	ClientApi.unregister(current.entry)
	current.entry:Destroy()
	if current.copy then
		current.copy:Destroy()
	end
	current = nil
end

-- 0.3.2 (P-K7): tells the server how this client's generation start went ({g, ok, e?, ms, retried?}, kernel channel
-- tagged "*"). The server records it per player (status().clients); it is never trusted for anything else.
local function reportStart(name: string, ok: boolean, err: string?, seconds: number, retried: boolean)
	pcall(function()
		net:FireServer("*", Constants.CHANNEL_CLIENT, {
			g = name,
			ok = ok,
			e = if ok then nil else string.sub(tostring(err or "?"), 1, 200),
			ms = math.floor(seconds * 1000),
			retried = retried or nil,
		})
	end)
end

-- Starts the client generation `name`. Returns (ok, error). `fresh` (0.3.2, the retry): run a client-side copy of the
-- tree, since a module that failed to load stays failed in the require cache of the replicated one.
local function start(name: string, fresh: boolean?): (boolean, string?)
	local started = os.clock()
	local tree = generations:WaitForChild(name, 30)
	if not tree then
		warn(`[TypeTorch] generation {name} never replicated`)
		return false, "never replicated"
	end
	local copy = nil
	if fresh then
		local cloned, result = pcall(function()
			return tree:Clone()
		end)
		if not cloned or not result then
			return false, `could not copy the tree: {result}`
		end
		if not retryFolder or retryFolder.Parent == nil then
			retryFolder = Instance.new("Folder")
			retryFolder.Name = "TypeTorchRetry"
			retryFolder.Parent = playerScripts
		end
		copy = result
		copy.Parent = retryFolder
		tree = copy
	end
	generationCount += 1
	local artifactId = tree:GetAttribute("ArtifactId") or name
	local branch = root:GetAttribute("Branch")
	local previous = lastGeneration
	local generation = {
		name = name,
		artifactId = artifactId,
		-- 0.2.2: the artifact identity the server put on the tree.
		artifact = {
			id = artifactId,
			assetId = tree:GetAttribute("AssetId"),
			commit = tree:GetAttribute("Commit"),
			commitHash = tree:GetAttribute("CommitHash"),
			branch = tree:GetAttribute("Branch"),
			channel = tree:GetAttribute("Channel"),
			builtAt = tree:GetAttribute("BuiltAt"),
			seq = tree:GetAttribute("Seq"),
		},
		branch = branch,
		channel = root:GetAttribute("Channel"),
		serverType = root:GetAttribute("ServerType"),
		number = generationCount,
		copy = copy,
		readyEvent = Instance.new("BindableEvent"),
		-- 0.2.2: how this client generation starts. A player's first one is a boot, whatever the server swapped for.
		start = {
			kind = if previous then "swap" else "boot",
			reason = if previous then root:GetAttribute("Reason") or "unknown" else "boot",
			previous = if previous
				then {
					artifact = table.clone(previous.artifact),
					branch = previous.branch,
					channel = previous.channel,
					generation = previous.number,
				}
				else nil,
			branchChanged = previous ~= nil and previous.branch ~= branch,
			startedAt = os.time(),
		},
	}
	local entry = template:Clone()
	entry.Name = name
	local rootValue = Instance.new("ObjectValue")
	rootValue.Name = "Root"
	rootValue.Value = tree
	rootValue.Parent = entry
	local kernelValue = Instance.new("ObjectValue")
	kernelValue.Name = "Kernel"
	kernelValue.Value = kernelShared.ClientApi
	kernelValue.Parent = entry
	generation.entry = entry
	ClientApi.register(entry, generation)

	local result = nil
	local connection = generation.readyEvent.Event:Connect(function(ok, err)
		result = { ok, err }
	end)
	entry.Parent = playerScripts
	entry.Enabled = true
	local deadline = os.clock() + Constants.READY_TIMEOUT
	while result == nil and os.clock() < deadline do
		task.wait()
	end
	connection:Disconnect()
	if result == nil or not result[1] then
		local err = if result then tostring(result[2]) else "timed out"
		warn(`[TypeTorch] client generation {name} failed{if fresh then " (retry)" else ""}: {err}`)
		entry.Enabled = false
		ClientApi.unregister(entry)
		entry:Destroy()
		if copy then
			copy:Destroy()
		end
		return false, err
	end
	current = generation
	lastGeneration = generation
	print(`[TypeTorch] client running {name}{if fresh then " (retry)" else ""} ({math.floor((os.clock() - started) * 1000)} ms)`)
	return true, nil
end

-- Coalesces bursts: if the attribute changes mid-switch, the loop runs again for the latest value. 0.3.2 (P-K7): a
-- generation that fails to start is tried once more (CLIENT_RETRY_SECONDS later, on a fresh copy of its tree), and the
-- outcome is reported to the server.
local function follow()
	if switching then
		return
	end
	switching = true
	while true do
		local wanted = root:GetAttribute("ActiveGeneration")
		if current and current.name == wanted then
			break
		end
		stopCurrent(if wanted
			then {
				reason = root:GetAttribute("Reason") or "unknown",
				branch = root:GetAttribute("Branch"),
				next = { id = root:GetAttribute("ArtifactId") },
			}
			else nil)
		if wanted == nil then
			break
		end
		local began = os.clock()
		local ok, err = start(wanted)
		local retried = false
		if not ok and root:GetAttribute("ActiveGeneration") == wanted then
			task.wait(Constants.CLIENT_RETRY_SECONDS or 2)
			if root:GetAttribute("ActiveGeneration") == wanted and current == nil then
				retried = true
				ok, err = start(wanted, true)
			end
		end
		reportStart(wanted, ok, err, os.clock() - began, retried)
		if current == nil or current.name == root:GetAttribute("ActiveGeneration") then
			break
		end
	end
	switching = false
end

root:GetAttributeChangedSignal("ActiveGeneration"):Connect(follow)
task.spawn(follow)
