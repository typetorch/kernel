--!nonstrict
-- TypeTorch kernel (client). Follows ReplicatedStorage.TypeTorch's `ActiveGeneration` attribute: stops the running
-- client generation (soft stop, then disable its ClientEntry clone), waits for the new client tree, and starts it
-- through a fresh ClientEntry clone in PlayerScripts. Also routes the kernel's stable remotes, keeps a log ring buffer,
-- and shows kernel notices (/tt replies) as system chat messages.

--
-- 0.3.6 (never an empty server): the HOLDING SCREEN. While the server holds players (nothing runs yet, or players are
-- being moved), and while this client's own generation can't start, the kernel client covers the bare place with its own
-- minimal screen: an opaque backdrop, a few words ("Starting...", "Loading...", "Reconnecting..."), a progress bar, a
-- UIScale pop in and out, no emojis (the user's UI rules). It is built before anything else waits, from the `Hold`
-- attribute on this script (the server sets it; ReplicatedFirst replicates first), so a joining player is covered at
-- once. It never blocks the kernel: every UI call is guarded.

local scriptStartedAt = os.clock()
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer

local holdScreen
do
	local TEXT = { start = "Starting...", load = "Loading...", move = "Reconnecting..." }
	local state = {
		server = script:GetAttribute("Hold"), -- "start" | "move" | nil, from the server
		mine = nil, -- "load" (this client's generation failed) | "move" (the server is moving this player) | nil
		running = false, -- this client's generation runs
		releasedAt = nil, -- os.clock() the server's hold ended
		ui = nil, -- { gui, backdrop, scale, label, fill, mode }
		failed = false, -- building the UI failed once: don't try again
		ticking = false,
	}
	holdScreen = state

	local function tween(instance, seconds, goal, style, direction)
		local TweenService = game:GetService("TweenService")
		local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
		local playing = TweenService:Create(instance, info, goal)
		playing:Play()
		return playing
	end

	local function build(mode: string)
		local gui = Instance.new("ScreenGui")
		gui.Name = "TypeTorchHold"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 2147483000
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local backdrop = Instance.new("Frame") -- opaque: the bare place never shows through
		backdrop.Name = "Backdrop"
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.BackgroundColor3 = Color3.fromRGB(16, 18, 23)
		backdrop.BorderSizePixel = 0
		backdrop.Parent = gui
		local card = Instance.new("Frame")
		card.Name = "Card"
		card.AnchorPoint = Vector2.new(0.5, 0.5)
		card.Position = UDim2.fromScale(0.5, 0.5)
		card.Size = UDim2.fromScale(0.6, 0.2)
		card.BackgroundTransparency = 1
		card.Parent = backdrop
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = 4
		aspect.Parent = card
		local scale = Instance.new("UIScale") -- pop in and out (never a Size tween)
		scale.Scale = 0.8
		scale.Parent = card
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 0.5)
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = Color3.fromRGB(236, 239, 245)
		label.TextScaled = true
		label.Text = TEXT[mode] or TEXT.start
		label.Parent = card
		local textSize = Instance.new("UITextSizeConstraint")
		textSize.MaxTextSize = 40
		textSize.Parent = label
		local track = Instance.new("Frame") -- the progress hint
		track.Name = "Track"
		track.AnchorPoint = Vector2.new(0.5, 0)
		track.Position = UDim2.fromScale(0.5, 0.72)
		track.Size = UDim2.fromScale(0.7, 0.1)
		track.BackgroundColor3 = Color3.fromRGB(44, 49, 60)
		track.BorderSizePixel = 0
		track.Parent = card
		Instance.new("UICorner").Parent = track
		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = Color3.fromRGB(96, 168, 255)
		fill.BorderSizePixel = 0
		fill.Parent = track
		Instance.new("UICorner").Parent = fill
		gui:SetAttribute("ShownMs", math.floor((os.clock() - scriptStartedAt) * 1000 + 0.5)) -- time-to-held (client)
		gui.Parent = player:WaitForChild("PlayerGui")
		tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		return { gui = gui, backdrop = backdrop, scale = scale, label = label, fill = fill, mode = mode, shownAt = os.clock() }
	end

	-- The mode to show, or nil. After the server's hold ends the screen stays until this client's generation runs (at
	-- most 10 s), so the half-loaded game never flashes.
	local function wanted(): string?
		if state.mine == "move" or state.server == "move" then
			return "move"
		end
		if state.mine then
			return state.mine
		end
		if state.server then
			return state.server
		end
		if state.ui and not state.running and state.releasedAt and os.clock() - state.releasedAt < 10 then
			return state.ui.mode
		end
		return nil
	end

	local refresh
	local function tick()
		if state.ticking then
			return
		end
		state.ticking = true
		task.spawn(function()
			while state.ui do
				local ui = state.ui
				-- A progress hint that never claims to be done: it eases toward 92% (a fill tween, as the UI rules allow).
				local progress = math.min(0.92, 1 - math.exp(-(os.clock() - ui.shownAt) / 6))
				pcall(tween, ui.fill, 0.45, { Size = UDim2.fromScale(progress, 1) })
				task.wait(0.5)
				refresh()
			end
			state.ticking = false
		end)
	end

	refresh = function()
		if state.failed then
			return
		end
		local mode = wanted()
		local ok, err = pcall(function()
			if mode then
				if not state.ui then
					state.ui = build(mode)
				elseif state.ui.mode ~= mode then
					state.ui.mode = mode
					state.ui.label.Text = TEXT[mode] or TEXT.start
				end
			elseif state.ui then
				local ui = state.ui
				state.ui = nil
				tween(ui.fill, 0.15, { Size = UDim2.fromScale(1, 1) })
				tween(ui.backdrop, 0.3, { BackgroundTransparency = 1 })
				local out = tween(ui.scale, 0.25, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
				out.Completed:Connect(function()
					ui.gui:Destroy()
				end)
			end
		end)
		if not ok then
			state.failed = true
			warn(`[TypeTorch] the holding screen failed: {err}`)
			return
		end
		if state.ui then
			tick()
		end
	end
	state.refresh = refresh

	local function onServerHold(value)
		local mode = if value == "start" or value == "move" then value else nil
		if state.server and not mode then
			state.releasedAt = os.clock()
		end
		state.server = mode
		refresh()
	end
	-- The server marks the hold on this script (first) and on ReplicatedStorage.TypeTorch (`state.root`, once known).
	local function serverHold()
		local value = script:GetAttribute("Hold")
		if value == nil and state.root then
			value = state.root:GetAttribute("Hold")
		end
		onServerHold(value)
	end
	state.serverHold = serverHold
	script:GetAttributeChangedSignal("Hold"):Connect(serverHold)
	onServerHold(state.server)
end

local kernelShared = ReplicatedStorage:WaitForChild("TypeTorchKernelShared")
local Constants = require(kernelShared:WaitForChild("Constants"))
local ClientApi = require(kernelShared:WaitForChild("ClientApi"))
local template = kernelShared:WaitForChild("ClientEntry")
local root = ReplicatedStorage:WaitForChild("TypeTorch")
-- 0.3.6: the hold is marked here too (a place whose kernel client isn't ReplicatedFirst.TypeTorchKernelClient).
holdScreen.root = root
root:GetAttributeChangedSignal("Hold"):Connect(holdScreen.serverHold)
holdScreen.serverHold()
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
local switchReplies = {} -- 0.3.4: answers to this player's switch requests, by id
local nextSwitchId = 0
local onResend -- 0.3.6: (info) the server re-sent a client tree to this player's PlayerGui (Generations below)

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
		elseif channel == Constants.CHANNEL_SWITCH then
			-- 0.3.4: the answer to this player's own switch request (requestSwitch below).
			local reply = ...
			if typeof(reply) == "table" and typeof(reply.id) == "number" then
				switchReplies[reply.id] = reply
			end
		elseif channel == Constants.CHANNEL_EVENT then
			local name = ...
			for _, listener in eventListeners do
				task.spawn(listener, name)
			end
		elseif channel == (Constants.CHANNEL_RESEND or "__tt/resend") then
			-- 0.3.6: this client's generation failed after its retry; the server re-sent its client code once.
			local info = ...
			if typeof(info) == "table" and typeof(info.g) == "string" and onResend then
				task.spawn(onResend, info)
			end
		elseif channel == (Constants.CHANNEL_HOLD or "__tt/hold") then
			-- 0.3.6: the server is moving this player to another server ("move").
			local mode = ...
			if mode == "move" or mode == "load" then
				holdScreen.mine = mode
				holdScreen.refresh()
			end
		end
		return
	end
	if channel == Constants.CHANNEL_RESYNC then
		-- The server already runs a newer generation and dropped a message of ours; ActiveGeneration will move us.
		-- 0.3.2 (P-N1): the generation whose message was dropped hears it (the framework fails its pending calls fast).
		local dropped = ...
		if current and current.resyncHandler and (dropped == nil or dropped == current.artifactId) then
			task.spawn(current.resyncHandler)
		end
		return
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

-- 0.3.4 (owner switch): asks the server to switch this server to a branch or load a build here ({ branch } |
-- { assetId }). The server decides for THIS player; nothing else can ask in their name. Yields until it answers (at most
-- 30 s): { ok, error?, generation?, queued? }.
local function requestSwitch(request)
	if typeof(request) ~= "table" then
		return { ok = false, error = "bad request" }
	end
	nextSwitchId += 1
	local id = nextSwitchId
	net:FireServer("*", Constants.CHANNEL_SWITCH, {
		id = id,
		branch = if typeof(request.branch) == "string" then request.branch else nil,
		assetId = if typeof(request.assetId) == "number" then request.assetId else nil,
	})
	local deadline = os.clock() + 30
	while switchReplies[id] == nil and os.clock() < deadline do
		task.wait()
	end
	local reply = switchReplies[id]
	switchReplies[id] = nil
	return reply or { ok = false, error = "no answer from the server" }
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
	requestSwitch = requestSwitch,
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
local function reportStart(name: string, ok: boolean, err: string?, seconds: number, retried: boolean, resent: boolean?)
	pcall(function()
		net:FireServer("*", Constants.CHANNEL_CLIENT, {
			g = name,
			ok = ok,
			e = if ok then nil else string.sub(tostring(err or "?"), 1, 200),
			ms = math.floor(seconds * 1000),
			retried = retried or nil,
			resent = resent or nil, -- 0.3.6: the start of the copy the server re-sent
		})
	end)
end

-- Starts the client generation `name`. Returns (ok, error). `fresh` (0.3.2, the retry): run a client-side copy of the
-- tree, since a module that failed to load stays failed in the require cache of the replicated one. `source` (0.3.6):
-- the tree the server re-sent to this player's PlayerGui (a fresh replication of the whole tree).
local function start(name: string, fresh: boolean?, source: Instance?): (boolean, string?)
	local started = os.clock()
	local tree = source or generations:WaitForChild(name, 30)
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
		-- 0.3.6: running: the holding screen can go. Failed after the retry: the holding screen covers the broken UI while
		-- the server re-sends the client code (then moves this player if that fails too).
		holdScreen.running = ok
		holdScreen.mine = if ok then nil elseif retried then "load" else holdScreen.mine
		holdScreen.refresh()
		if current == nil or current.name == root:GetAttribute("ActiveGeneration") then
			break
		end
	end
	if root:GetAttribute("ActiveGeneration") == nil then
		-- 0.3.6: nothing runs on the server (a failed swap stopped the old generation): the dead client generation was
		-- stopped above; the server's hold covers the screen.
		holdScreen.running = false
		holdScreen.refresh()
	end
	switching = false
end

-- 0.3.6: the server re-sent the client tree of generation `info.g` to PlayerGui.TypeTorchResend (once, after this
-- client's own retry failed): start that copy and report it (`resent`). It failing too makes the server move the player.
onResend = function(info)
	local name = info.g
	if current and current.name == name then
		return
	end
	local gui = player:FindFirstChildOfClass("PlayerGui") or player:FindFirstChild("PlayerGui")
	local wait = Constants.CLIENT_RESEND_WAIT or 15
	local folder = gui and gui:WaitForChild("TypeTorchResend", wait)
	local tree = folder and folder:WaitForChild(name, wait)
	while switching do
		task.wait()
	end
	if current or root:GetAttribute("ActiveGeneration") ~= name then
		return -- started meanwhile, or the server moved on (follow() takes the new one)
	end
	switching = true
	local began = os.clock()
	local ok, err = false, "the re-sent client code never arrived"
	if tree then
		ok, err = start(name, false, tree)
	end
	reportStart(name, ok, err, os.clock() - began, false, true)
	holdScreen.running = ok
	holdScreen.mine = if ok then nil else "move"
	holdScreen.refresh()
	switching = false
	if root:GetAttribute("ActiveGeneration") ~= name then
		follow()
	end
end

root:GetAttributeChangedSignal("ActiveGeneration"):Connect(follow)
task.spawn(follow)
