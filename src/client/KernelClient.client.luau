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
				devStatus = value
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
local current = nil
local generationCount = 0
local switching = false

local function stopCurrent()
	if not current then
		return
	end
	handler = nil
	if current.stop then
		local ok, err = pcall(current.stop)
		if not ok then
			warn(`[TypeTorch] {current.name} stop threw: {err}`)
		end
	end
	current.entry.Enabled = false
	ClientApi.unregister(current.entry)
	current.entry:Destroy()
	current = nil
end

local function start(name: string)
	local started = os.clock()
	local tree = generations:WaitForChild(name, 30)
	if not tree then
		warn(`[TypeTorch] generation {name} never replicated`)
		return
	end
	generationCount += 1
	local generation = {
		name = name,
		artifactId = tree:GetAttribute("ArtifactId") or name,
		branch = root:GetAttribute("Branch"),
		channel = root:GetAttribute("Channel"),
		number = generationCount,
		readyEvent = Instance.new("BindableEvent"),
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
		warn(`[TypeTorch] client generation {name} failed: {if result then result[2] else "timed out"}`)
		entry.Enabled = false
		ClientApi.unregister(entry)
		entry:Destroy()
		return
	end
	current = generation
	print(`[TypeTorch] client running {name} ({math.floor((os.clock() - started) * 1000)} ms)`)
end

-- Coalesces bursts: if the attribute changes mid-switch, the loop runs again for the latest value.
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
		stopCurrent()
		if wanted == nil then
			break
		end
		start(wanted)
		if current == nil or current.name == root:GetAttribute("ActiveGeneration") then
			break
		end
	end
	switching = false
end

root:GetAttributeChangedSignal("ActiveGeneration"):Connect(follow)
task.spawn(follow)
