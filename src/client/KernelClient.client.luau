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
--
-- 0.3.8 (plans/19 item 13): LOADING SCREENS. Place scripts (a game's own loading screen in ReplicatedFirst) read
-- attributes this script sets on itself: `ClientReady` = true once this player's first client generation runs,
-- `ClientGeneration` = the running client generation's name (nil while none runs), `Holding` = the mode the holding
-- screen is in ("start" | "load" | "move"; nil when nothing holds), whether or not the kernel draws it. The server copies
-- the game's settings onto this script before anyone joins: `BootScreen` (a ScreenGui in ReplicatedFirst: cloned into
-- PlayerGui at once, removed when the first client generation runs or after 60 s) and `KernelScreen` = false (the game
-- shows its own loading screen). Either way the kernel's "Starting..." / "Loading..." screen stays off until the first
-- client generation ran (one screen at a time; "Reconnecting..." for a move always shows).
--
-- 0.3.9 ("Starting..." stayed up while the game ran): ReplicatedFirst is replicated ONCE, when the player joins, so the
-- `Hold` attribute on this script is the hold AT JOIN and never changes here afterwards; this script read it first and
-- kept "Starting..." for good when the player joined during the boot hold. Now it is used only until
-- ReplicatedStorage.TypeTorch arrives; from then on that folder's `Hold` / `HoldReason` (live) decide. Every screen
-- change prints one line with its reason ("[TypeTorch] screen up (Starting...): server hold start: ...", "screen down:
-- generation X running"), in this client's log ring (the dev menu's Logs, Logs > Upload), and `HoldReason` sits next to
-- `Holding` on this script. FAIL-SAFE: when this client's own generation runs, the server has an ActiveGeneration and
-- the hold still says "start" after CLIENT_HOLD_FAILSAFE (5) s, the screen comes down anyway with a loud warning of the
-- state it saw (a server-side bookkeeping bug must never keep players behind it). A "move" hold is real: never dropped.

local scriptStartedAt = os.clock()
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local player = Players.LocalPlayer

-- Logs (0.3.9: first, so the holding screen's own lines are in the ring) ------------------------------------------
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

-- 0.4.0 (problem 19): ERROR REPORTS. This client's errors (ScriptContext.Error, LogService error lines) are counted
-- here from the first line on and forwarded to the server (kernel channel CHANNEL_ERRORS, tagged "*") at most every
-- ERRORS_CLIENT_GAP s, ERRORS_CLIENT_BATCH distinct messages a time; the server templates them (names never leave the
-- server), fingerprints, counts and posts them with its own (Errors.luau). At most 20 distinct messages wait; the rest
-- are counted as dropped and the count rides along.
local clientErrors = { pending = {}, order = {}, dropped = 0, logQueue = {}, scriptSeen = {}, generationOf = nil }
do
	local ScriptContext = game:GetService("ScriptContext")
	local MAX_PENDING = 20
	function clientErrors.add(message: string, stack: string?, generation: string?)
		local key = message .. "\0" .. (stack or "")
		local entry = clientErrors.pending[key]
		if entry then
			entry.n += 1
			return
		end
		if #clientErrors.order >= MAX_PENDING then
			clientErrors.dropped += 1
			return
		end
		clientErrors.pending[key] = { m = string.sub(message, 1, 1000), s = if stack then string.sub(stack, 1, 2000) else nil, n = 1, g = generation }
		table.insert(clientErrors.order, key)
	end
	ScriptContext.Error:Connect(function(message, stack, scriptInstance)
		pcall(function()
			local text = tostring(message)
			clientErrors.scriptSeen[text] = os.clock()
			local generation = if clientErrors.generationOf then clientErrors.generationOf(scriptInstance) else nil
			clientErrors.add(text, if typeof(stack) == "string" and stack ~= "" then stack else nil, generation)
		end)
	end)
	LogService.MessageOut:Connect(function(message, messageType)
		if messageType == Enum.MessageType.MessageError and #clientErrors.logQueue < 50 then
			table.insert(clientErrors.logQueue, { text = message, at = os.clock() })
		end
	end)
end

local holdScreen
do
	local TEXT = { start = "Starting...", load = "Loading...", move = "Reconnecting..." }
	local state = {
		-- "start" | "move" | nil, from the server. 0.3.9: the script's attribute is the hold at JOIN (ReplicatedFirst is
		-- replicated once); ReplicatedStorage.TypeTorch's, once known (`root`), is the live one.
		server = script:GetAttribute("Hold"),
		serverReason = script:GetAttribute("HoldReason"), -- 0.3.9: why the server holds
		-- 0.3.9: the server's reason in the join snapshot, read once: from here on this script's `HoldReason` is THIS
		-- client's (why its screen is up, next to `Holding`); the server's live reason is on ReplicatedStorage.TypeTorch.
		joinReason = script:GetAttribute("HoldReason"),
		mine = nil, -- "load" (this client's generation failed) | "move" (the server is moving this player) | nil
		running = false, -- this client's generation runs
		generation = nil, -- 0.3.9: the running client generation's name
		logged = nil, -- 0.3.9: the last screen state printed ("<mode>|<reason>")
		wasUp = false, -- 0.3.9: a screen state other than "down" was printed
		stuckSince = nil, -- 0.3.9 fail-safe: os.clock() a "start" hold was first seen while this client's generation runs
		overridden = false, -- 0.3.9 fail-safe: the server's current "start" hold is ignored (until the server's hold changes)
		releasedAt = nil, -- os.clock() the server's hold ended
		ui = nil, -- { gui, backdrop, scale, label, fill, mode }
		failed = false, -- building the UI failed once: don't try again
		ticking = false,
		-- 0.3.8 loading screens: the game's settings (from the server, on this script), the boot screen's clone, and
		-- whether this player's first client generation ran.
		bootName = script:GetAttribute("BootScreen"),
		kernelScreen = script:GetAttribute("KernelScreen") ~= false,
		bootPending = false, -- waiting for the boot screen to replicate
		boot = nil, -- the boot screen's clone in PlayerGui
		everReady = false, -- this player's first client generation ran (ClientReady)
		handedOver = false, -- ... and the server's first hold ended: from now on the kernel's screen works as in 0.3.6
	}
	holdScreen = state
	-- Constants.BOOT_SCREEN_WAIT / BOOT_SCREEN_TIMEOUT (this runs before Constants can be required).
	local BOOT_WAIT, BOOT_TIMEOUT = 5, 60
	-- Constants.CLIENT_HOLD_FAILSAFE and HOLD_DISPLAY_ORDER (the framework's dev menu sits at HOLD_DISPLAY_ORDER + 100).
	local FAILSAFE, DISPLAY_ORDER = 5, 2147483000

	local function mark(name: string, value: any)
		pcall(script.SetAttribute, script, name, value)
	end

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
		gui.DisplayOrder = DISPLAY_ORDER -- above every game UI; the dev menu (DISPLAY_ORDER + 100) stays above it
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

	-- The mode to show, or nil, and (0.3.9) why. After the server's hold ends the screen stays until this client's
	-- generation runs (at most 10 s), so the half-loaded game never flashes.
	local function wanted(): (string?, string)
		if state.mine == "move" then
			return "move", "this client is being moved to another server (its generation failed)"
		end
		if state.server == "move" then
			return "move", `server hold move: {state.serverReason or "no reason given"}`
		end
		if state.mine then
			return state.mine, "this client's generation failed after its retry (the server re-sends it)"
		end
		if state.server and not state.overridden then
			return state.server, `server hold {state.server}: {state.serverReason or "no reason given"}`
		end
		if state.ui and not state.running and state.releasedAt and os.clock() - state.releasedAt < 10 then
			return state.ui.mode, "server hold released; waiting for this client's generation (10 s at most)"
		end
		if state.running and state.generation then
			return nil, `generation {state.generation} running`
		end
		return nil, if state.overridden then "the fail-safe dropped the server's stuck hold" else "no hold"
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

	-- 0.3.8: until this player's first client generation ran and the server's first hold ended, the game's own loading
	-- screen (the boot screen, or one its scripts draw: KernelScreen = false) stands in for the kernel's "Starting..." /
	-- "Loading..."; a move always shows.
	local function suppressed(mode: string?): boolean
		if mode == nil or mode == "move" or state.handedOver then
			return false
		end
		return state.boot ~= nil or state.bootPending or not state.kernelScreen
	end

	-- 0.3.9 FAIL-SAFE: this client's generation runs, the server has an ActiveGeneration, and the hold has said "start"
	-- for FAILSAFE s: a server-side bookkeeping bug; the screen comes down (until the server's hold changes), loudly.
	local function checkStuck()
		local root = state.root
		local active = if root then root:GetAttribute("ActiveGeneration") else nil
		if not (state.server == "start" and not state.overridden and state.mine == nil and state.running and state.generation and active ~= nil) then
			state.stuckSince = nil
			return
		end
		local now = os.clock()
		if not state.stuckSince then
			state.stuckSince = now
			task.delay(FAILSAFE + 0.1, function()
				refresh()
			end)
			return
		end
		if now - state.stuckSince < FAILSAFE then
			return
		end
		state.overridden = true
		warn(
			`[TypeTorch] FAIL-SAFE: the holding screen came down by itself. This client runs {state.generation} and the server's ActiveGeneration is {active}, but the server's hold has said "start" for {FAILSAFE}+ s (HoldReason: {tostring(state.serverReason)}; ReplicatedStorage.TypeTorch Hold = {tostring(root:GetAttribute("Hold"))}; this script's Hold (join snapshot) = {tostring(script:GetAttribute("Hold"))}; released {if state.releasedAt then `{math.floor(os.clock() - state.releasedAt)} s ago` else "never"}). The server didn't end its hold: a TypeTorch kernel bug, please report this line with the server's logs.`
		)
		task.defer(function()
			if state.handOver then
				state.handOver() -- the game's loading screen goes too (ClientReady already ran)
			end
		end)
	end

	refresh = function()
		checkStuck()
		local raw, reason = wanted()
		mark("Holding", raw)
		mark("HoldReason", if raw then reason else nil) -- 0.3.9
		-- 0.3.9: one line per change of the screen's state, with its reason.
		local key = `{raw or "down"}|{reason}`
		if key ~= state.logged then
			state.logged = key
			local shown = if raw and suppressed(raw) then " (the game's own loading screen shows instead)" else ""
			if raw then
				state.wasUp = true
				print(`[TypeTorch] screen up ({TEXT[raw] or raw}): {reason}{shown}`)
			elseif state.wasUp then
				state.wasUp = false
				print(`[TypeTorch] screen down: {reason}`)
			end
		end
		if state.failed then
			return
		end
		local mode = if suppressed(raw) then nil else raw
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

	local function onServerHold(value, reason)
		local mode = if value == "start" or value == "move" then value else nil
		reason = if typeof(reason) == "string" then reason else nil
		if state.server and not mode then
			state.releasedAt = os.clock()
		end
		if mode ~= state.server or reason ~= state.serverReason then
			-- 0.3.9: a new hold (or none): the fail-safe starts over.
			state.overridden = false
			state.stuckSince = nil
		end
		state.server = mode
		state.serverReason = reason
		if state.handOver then
			state.handOver()
		end
		refresh()
	end
	-- 0.3.9: the server marks the hold on this script (ReplicatedFirst: the JOIN snapshot, never updated on this client)
	-- and on ReplicatedStorage.TypeTorch (`state.root`: live). Once the root is known it alone decides.
	local function serverHold()
		local root = state.root
		if root then
			onServerHold(root:GetAttribute("Hold"), root:GetAttribute("HoldReason"))
		else
			onServerHold(script:GetAttribute("Hold"), state.joinReason)
		end
	end
	state.serverHold = serverHold
	script:GetAttributeChangedSignal("Hold"):Connect(serverHold)

	-- 0.3.8: the boot screen goes (handed over, or BOOT_TIMEOUT passed).
	local function removeBoot()
		local gui = state.boot
		state.boot = nil
		state.bootPending = false
		if gui then
			pcall(gui.Destroy, gui)
		end
		refresh()
	end
	-- 0.3.8: the first client generation runs and the server's first hold is over (characters spawn): the game's loading
	-- screen goes, and the kernel's holding screen works as in 0.3.6 for later holds.
	function state.handOver()
		if state.handedOver or not state.everReady or (state.server ~= nil and not state.overridden) then
			return
		end
		state.handedOver = true
		removeBoot()
	end
	-- 0.3.8: this player's client generation `name` runs (nil: none runs now). The first one sets ClientReady.
	function state.ran(name: string?)
		state.generation = name -- 0.3.9
		mark("ClientGeneration", name)
		if name and not state.everReady then
			state.everReady = true
			mark("ClientReady", true)
			state.handOver()
		end
	end
	-- 0.3.8: the boot screen: a clone of ReplicatedFirst.<BootScreen> (a ScreenGui), shown at once.
	if typeof(state.bootName) == "string" and state.bootName ~= "" then
		state.bootPending = true
		task.spawn(function()
			local ok, gui = pcall(function()
				local first = game:GetService("ReplicatedFirst")
				local source = first:FindFirstChild(state.bootName) or first:WaitForChild(state.bootName, BOOT_WAIT)
				if state.handedOver then
					return false -- (the game already runs: never shown)
				end
				if not (source and source:IsA("ScreenGui")) then
					return nil
				end
				local copy = source:Clone()
				copy.ResetOnSpawn = false
				copy.Parent = player:WaitForChild("PlayerGui")
				return copy
			end)
			state.bootPending = false
			if ok and gui then
				if state.handedOver then
					pcall(gui.Destroy, gui)
				else
					state.boot = gui
					task.delay(BOOT_TIMEOUT, function()
						if state.boot == gui then
							removeBoot()
						end
					end)
				end
			elseif not ok then
				warn(`[TypeTorch] the boot screen {state.bootName} failed: {gui}`)
			elseif gui == nil then
				warn(`[TypeTorch] the boot screen ReplicatedFirst.{state.bootName} isn't a ScreenGui (or never arrived)`)
			end
			refresh()
		end)
	end
	onServerHold(state.server, state.joinReason)
end

local kernelShared = ReplicatedStorage:WaitForChild("TypeTorchKernelShared")
local Constants = require(kernelShared:WaitForChild("Constants"))
local ClientApi = require(kernelShared:WaitForChild("ClientApi"))
local template = kernelShared:WaitForChild("ClientEntry")
local root = ReplicatedStorage:WaitForChild("TypeTorch")
-- 0.3.9: the LIVE hold (this script's own attribute is only the join snapshot: ReplicatedFirst replicates once).
holdScreen.root = root
root:GetAttributeChangedSignal("Hold"):Connect(holdScreen.serverHold)
root:GetAttributeChangedSignal("HoldReason"):Connect(holdScreen.serverHold)
holdScreen.serverHold()
local generations = root:WaitForChild("Generations")
local net: RemoteEvent = root:WaitForChild("Net")
local netU: UnreliableRemoteEvent = root:WaitForChild("NetU")

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
		elseif channel == (Constants.CHANNEL_RDLOGS or "__tt/rdlogs") then
			-- 0.5.0 (plans/25, remote debug): the server asks for this client's log ring (an owner reads it from the
			-- explorer). Like the dev menu's Logs > Others: the newest entries after `since`, texts cut at 600 bytes, at
			-- most RD_CLIENT_LOGS_MAX entries and RD_CLIENT_LOGS_BYTES bytes. Never shown here.
			local request = ...
			if typeof(request) == "table" and typeof(request.id) == "number" then
				local since = if typeof(request.since) == "number" then request.since else nil
				local entries = logs.since(since, Constants.RD_CLIENT_LOGS_MAX or 200)
				local picked, bytes = {}, 0
				for index = #entries, 1, -1 do
					local entry = entries[index]
					local text = string.sub(entry.text, 1, 600)
					bytes += #text + 32
					if bytes > (Constants.RD_CLIENT_LOGS_BYTES or 64000) then
						break
					end
					table.insert(picked, 1, { i = entry.i, t = entry.t, kind = entry.kind, text = text })
				end
				net:FireServer("*", Constants.CHANNEL_RDLOGS or "__tt/rdlogs", { id = request.id, logs = picked })
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
	holdScreen.ran(nil) -- 0.3.8: ClientGeneration
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
		-- 0.3.9: `Channel` holds the server's RULES (older frameworks gate on it); `BranchChannel` what the branch is.
		channel = root:GetAttribute("Channel"),
		branchChannel = root:GetAttribute("BranchChannel"),
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
	holdScreen.ran(name) -- 0.3.8: ClientGeneration, and ClientReady for the first one (place loading screens wait for it)
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

-- 0.4.0 (problem 19): the error reports' sender (the collector is at the top). A script error names its generation
-- from where the script lives (Generations.<name>, or the retry / re-sent copies); anything else is the running one's.
clientErrors.generationOf = function(scriptInstance)
	local node = scriptInstance
	for _ = 1, 40 do
		if typeof(node) ~= "Instance" then
			break
		end
		local parent = node.Parent
		if parent and (parent.Name == "Generations" or parent.Name == "TypeTorchRetry" or parent.Name == "TypeTorchResend") and string.match(node.Name, "#%d+$") then
			return node.Name
		end
		node = parent
	end
	return current and current.name
end
task.spawn(function()
	local gap = Constants.ERRORS_CLIENT_GAP or 10
	local batch = Constants.ERRORS_CLIENT_BATCH or 10
	while true do
		task.wait(gap * (0.8 + math.random() * 0.4))
		-- LogService error lines a script error already reported (either order) are dropped.
		local now = os.clock()
		while #clientErrors.logQueue > 0 and now - clientErrors.logQueue[1].at >= 0.5 do
			local entry = table.remove(clientErrors.logQueue, 1)
			local seen = clientErrors.scriptSeen[entry.text]
			if not (seen and math.abs(seen - entry.at) <= 2) then
				clientErrors.add(entry.text, nil, current and current.name)
			end
		end
		for text, at in clientErrors.scriptSeen do
			if now - at > 5 then
				clientErrors.scriptSeen[text] = nil
			end
		end
		if #clientErrors.order > 0 or clientErrors.dropped > 0 then
			local list = {}
			while #list < batch and #clientErrors.order > 0 do
				local key = table.remove(clientErrors.order, 1)
				table.insert(list, clientErrors.pending[key])
				clientErrors.pending[key] = nil
			end
			local dropped = clientErrors.dropped
			clientErrors.dropped = 0
			pcall(function()
				net:FireServer("*", Constants.CHANNEL_ERRORS or "__tt/errors", { e = list, d = if dropped > 0 then dropped else nil })
			end)
		end
	end
end)
