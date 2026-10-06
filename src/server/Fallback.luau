--!nonstrict
-- TypeTorch kernel 0.3.6: NEVER AN EMPTY SERVER. User requirement (2026-10-06): "IN NO POSSIBLE WAY players should load
-- into an empty baseplate". Design: plans/01 "Never an empty server". The kernel (Kernel.server.luau) owns swaps and
-- trust; this module decides WHEN the fallbacks run and holds, moves and re-sends to players.
--
-- HOLD. From the kernel's first line until a generation is ready, characters don't spawn (Players.CharacterAutoLoads
-- off; on release it is turned back on and waiting players get LoadCharacter) and the kernel client shows its holding
-- screen (the `Hold` attribute on ReplicatedFirst.TypeTorchKernelClient, which replicates before anything else, and on
-- ReplicatedStorage.TypeTorch). The Players attribute TypeTorchHoldCharacters = false leaves characters alone (games
-- that spawn them themselves); a place whose CharacterAutoLoads is already off is left alone too. A swap of a running
-- generation never holds anybody.
--
-- When the head and the last-known-good chain ran nothing at boot, the user's order is 4 -> 3 -> 5 -> 2:
--   4. PEERS: a kernel roll call (an ask { rc = 1 } on TypeTorch/deploy, replies on TypeTorch/peers/<JobId>) asks the
--      branch's live servers which build they run healthy for a while; the most common one runs. Prod servers take it
--      only when this kernel trusts it (the kernel's trustPeer: a valid signature, a deployment entry that verifies,
--      or the BootstrapHeads match): peers can't make a prod server trust an unsigned build.
--   3. BACKUP: ServerStorage.TypeTorchBackup, the prod head's payload `typetorch kernel deploy` baked into the place,
--      trusted like the place itself and mounted as a fresh clone through the same mount checks (modules only).
--      status().backup, fleet `backup = true` and h = "backup", alert backup_build (critical).
--   5. RECOVERY: whatever runs (the backup) or not, the head, the last known good and peers are retried in the
--      background (RECOVER_DELAYS: 15 s, 30 s, then every 60 s); the first one that works is a normal swap (players
--      stay); it stops once the head runs.
--   2. TELEPORT: nothing runs after the boot budget (or, later in the server's life, for TELEPORT_GRACE s): waiting
--      players and new joiners go to a healthy server of the branch found by the roll call (TeleportAsync with
--      ServerInstanceId, or a reserved peer's access code), else a fresh server (public: matchmaking; private and
--      reserved: a new reserved server on the same branch). The teleport data carries a bounce count; a player who
--      arrives with BOUNCE_MAX bounces is kicked with "Servers are restarting. Please rejoin in a minute.". Alert
--      boot_failed_teleport (critical).
-- CLIENTS: a client whose generation failed after its own retry gets the client tree re-sent once (a fresh copy in its
-- PlayerGui, CHANNEL_RESEND); if that fails too, the player moves to a server where the build runs (or rejoins).

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local Constants = require(ReplicatedStorage:WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Fallback = {}

-- Set by the kernel (Fallback.configure); see the kernel's "Never an empty server" block for each one.
local deps = {
	startedAt = os.clock(),
	jobId = "",
	placeId = 0,
	replicatedRoot = nil,
	serverType = function()
		return "public"
	end,
	branch = function()
		return nil
	end,
	current = function()
		return nil
	end,
	everRan = function()
		return false
	end,
	idle = function()
		return true
	end,
	closing = function()
		return false
	end,
	localMode = function()
		return false -- Studio local payload: the dev's own code; never replaced by a peer build or the backup
	end,
	swapTo = nil, -- (head, reason) -> report
	admitBackup = function(head)
		return head
	end,
	trustPeer = nil, -- (row) -> (head?, why?)
	noteApplied = function() end,
	retryHead = function()
		return nil
	end,
	retryLastKnownGood = function()
		return nil
	end,
	headRunning = function()
		return false
	end,
	hasHead = function()
		return false
	end,
	peerRow = function()
		return nil
	end,
	reserveServer = function()
		return nil, "unavailable"
	end,
	ownAccessCode = function()
		return nil
	end,
	kernelSend = function() end,
	alert = function() end,
	logEvent = function() end,
	refuse = function() end,
	warn = warn,
	print = print,
}

local setClientHold -- (mode?) below

function Fallback.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
	-- The hold started before ReplicatedStorage.TypeTorch existed: mark it there too now.
	if overrides.replicatedRoot and setClientHold then
		setClientHold(nil, true)
	end
end

local function encode(value): string
	return HttpService:JSONEncode(value)
end

local function decode(text: any): any
	if typeof(text) ~= "string" or #text > 1024 then
		return nil
	end
	local ok, value = pcall(HttpService.JSONDecode, HttpService, text)
	return if ok then value else nil
end

local function validJob(id: any): boolean
	return typeof(id) == "string" and #id > 0 and #id <= 64 and string.match(id, "^[%w%-]+$") ~= nil
end

local function nowMs(): number
	return DateTime.now().UnixTimestampMillis
end

local function isStudio(): boolean
	return RunService:IsStudio()
end

-- HOLD --------------------------------------------------------------------------------------------------------------

local hold = {
	active = false,
	mode = nil, -- "start" (nothing ran yet) | "move" (nothing runs; players are being moved)
	optOut = false, -- Players.TypeTorchHoldCharacters == false
	controls = false, -- the kernel turned CharacterAutoLoads off and turns it back on
	startedAt = nil, -- os.clock(): the hold began (the kernel start for the first one)
	heldMs = nil, -- ms from the kernel start until CharacterAutoLoads was off (time-to-held, server side)
	releasedAt = nil,
	spawned = 0, -- LoadCharacter calls on release
	holds = 0,
}

local clientScript = nil -- ReplicatedFirst.TypeTorchKernelClient

-- The `Hold` attribute ("start" | "move" | nil) on the kernel client script (it replicates before the rest of the game,
-- so a joining client knows at once) and on ReplicatedStorage.TypeTorch. `current`: re-apply the hold's own mode.
setClientHold = function(mode: string?, current: boolean?)
	if current then
		mode = if hold.active then hold.mode else nil
	end
	if clientScript == nil or clientScript.Parent == nil then
		local ok, first = pcall(game.GetService, game, "ReplicatedFirst")
		clientScript = if ok and first then first:FindFirstChild("TypeTorchKernelClient") else nil
	end
	if clientScript then
		pcall(clientScript.SetAttribute, clientScript, "Hold", mode)
	end
	local root = deps.replicatedRoot
	if root then
		pcall(root.SetAttribute, root, "Hold", mode)
	end
end

local function engage(mode: string)
	if not hold.active then
		hold.active = true
		hold.startedAt = os.clock()
		hold.holds += 1
	end
	hold.mode = mode
	if not hold.optOut and Players.CharacterAutoLoads == true then
		Players.CharacterAutoLoads = false
		hold.controls = true
	end
	setClientHold(mode)
end

local deadman -- () -> (), below: the kernel errored before its boot finished

-- The kernel's FIRST call (before anything that yields): no character spawns until a generation is ready.
function Fallback.hold(startedAt: number?)
	local ok, value = pcall(Players.GetAttribute, Players, Constants.HOLD_ATTRIBUTE)
	hold.optOut = ok and value == false
	engage("start")
	hold.startedAt = startedAt or hold.startedAt
	hold.heldMs = math.floor((os.clock() - (startedAt or os.clock())) * 1000 + 0.5)
	-- If the kernel never reaches Fallback.start (it errored during its boot: a kernel bug), nothing would ever release or
	-- move the held players. Past the budget they are moved anyway (Studio: released).
	task.delay(Constants.BOOT_BUDGET + 5, function()
		deadman()
	end)
end

local moving: { [Player]: any } = {} -- players being moved (teleport mode or a failed client)

local function release(why: string)
	if not hold.active then
		return
	end
	hold.active = false
	hold.mode = nil
	hold.releasedAt = os.clock()
	setClientHold(nil)
	if not hold.controls then
		return
	end
	hold.controls = false
	Players.CharacterAutoLoads = true
	-- CharacterAutoLoads only acts on joins and deaths: the players who waited get their character now.
	for _, player in Players:GetPlayers() do
		if player.Character == nil and player.Parent ~= nil then
			hold.spawned += 1
			task.spawn(function()
				local ok, err = pcall(player.LoadCharacter, player)
				if not ok then
					deps.warn(`[TypeTorch] LoadCharacter({player.Name}) after the hold ({why}) failed: {err}`)
				end
			end)
		end
	end
end

-- STATE -------------------------------------------------------------------------------------------------------------

local started = false
local bootReturned = false
local booting = 0 -- the kernel's boot (bootSigned) is between attempts
local lastRunningAt = nil -- os.clock() something last ran
local loadFailedAt: { [number]: number } = {} -- assetId -> os.clock() of a LOAD failure (an asset outage looks like this)

local chain = { running = false, done = false, at = nil, why = nil, result = nil }
local peers = { asks = 0, answered = 0, ignored = 0, limited = 0, refused = 0, lastAt = nil, replies = 0, error = nil, chosen = nil }
local backup = { failed = nil, runs = 0, since = nil }
local recovery = { running = false, attempts = 0, nextAt = nil, last = nil, stoppedAt = nil }
local move = { active = false, since = nil, why = nil, teleported = 0, kicked = 0, failures = 0, lastError = nil, target = nil }
local clients = { resent = 0, moved = 0 }

-- BACKUP ------------------------------------------------------------------------------------------------------------

local backupHeads: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function backupSource(): Instance?
	local source = ServerStorage:FindFirstChild(Constants.BACKUP_NAME)
	if source and source:IsA("Model") then
		return source
	end
	return nil
end

local function attr(instance: Instance, name: string, kind: string): any
	local value = instance:GetAttribute(name)
	return if typeof(value) == kind then value else nil
end

-- { artifactId?, seq?, branch?, channel?, at? } of the baked backup, or nil.
local function backupInfo(): any?
	local source = backupSource()
	if not source then
		return nil
	end
	return {
		artifactId = attr(source, "BackupArtifactId", "string") or attr(source, "ArtifactId", "string"),
		seq = attr(source, "BackupSeq", "number"),
		branch = attr(source, "BackupBranch", "string"),
		channel = attr(source, "BackupChannel", "string") or attr(source, "Channel", "string"),
		at = attr(source, "BackupAt", "string"),
		commit = attr(source, "Commit", "string"),
	}
end

-- A head for the backup (a new table per call, marked as a backup and admitted "backup"), or nil (none, or it failed
-- here: a mount or start failure is the same every time).
function Fallback.backupHead()
	local info = backupInfo()
	if not info or backup.failed then
		return nil
	end
	local head = {
		artifactId = info.artifactId or "backup",
		channel = info.channel,
		branch = info.branch,
		commit = info.commit,
		-- No `seq`/`assetId`: a backup isn't a deploy (no deploy report, appliedSeq stays), and nothing is loaded.
		backupSeq = info.seq,
		backupAt = info.at,
	}
	backupHeads[head] = true
	return deps.admitBackup(head)
end

function Fallback.isBackup(head): boolean
	return typeof(head) == "table" and backupHeads[head] == true
end

-- Copies keep the mark (the kernel clones heads).
function Fallback.markCopy(copy, head)
	if typeof(head) == "table" and backupHeads[head] then
		backupHeads[copy] = true
	end
end

-- A fresh clone of the backup, stamped with the head's artifact id (the source stays for the next time).
function Fallback.loadBackup(head): Instance
	local source = backupSource()
	if not source then
		error(`no ServerStorage.{Constants.BACKUP_NAME}`)
	end
	if not (source:FindFirstChild("Server") and source:FindFirstChild("Client")) then
		error(`ServerStorage.{Constants.BACKUP_NAME} has no Server/Client`)
	end
	local payload = source:Clone()
	if not payload then
		error(`ServerStorage.{Constants.BACKUP_NAME} could not be cloned (Archivable is off)`)
	end
	payload:SetAttribute("ArtifactId", head.artifactId)
	return payload
end

-- PEERS: the kernel roll call ----------------------------------------------------------------------------------------

local cache = nil -- { at, rows, error? }
local asking = false
local nextQ = math.random(1, 10 ^ 6)

-- The branch's servers that answered (other kernels), cached PEER_CACHE s; one roll call at a time. Yields at most
-- about PEER_COLLECT + 1 s. `fresh`: ignore the cache.
local function rollCall(fresh: boolean?): any
	if cache and not fresh and os.clock() - cache.at < Constants.PEER_CACHE then
		return cache
	end
	if asking then
		local deadline = os.clock() + Constants.PEER_COLLECT + 2
		while asking and os.clock() < deadline do
			task.wait(0.05)
		end
		return cache or { at = os.clock(), rows = {}, error = "busy" }
	end
	local jobId, branch = deps.jobId, deps.branch()
	if not validJob(jobId) or typeof(branch) ~= "string" or isStudio() then
		cache = { at = os.clock(), rows = {}, error = "no roll call here (Studio or no JobId)" }
		return cache
	end
	asking = true
	nextQ = (nextQ % 10 ^ 9) + 1
	local q = nextQ
	local rows, count = {}, 0
	local state = { subscribed = false, failure = nil, abandoned = false, connection = nil }
	task.spawn(function()
		local ok, connection = pcall(MessagingService.SubscribeAsync, MessagingService, `{Constants.PEER_TOPIC}/{jobId}`, function(message)
			local reply = decode(message and message.Data)
			if typeof(reply) ~= "table" or reply.q ~= q or not validJob(reply.j) or reply.j == jobId then
				return
			end
			if rows[reply.j] == nil then
				count += 1
			end
			rows[reply.j] = reply
		end)
		if not ok then
			state.failure = `subscribe: {connection}`
			return
		end
		if state.abandoned then
			pcall(function()
				connection:Disconnect()
			end)
			return
		end
		state.connection = connection
		local published, err = pcall(MessagingService.PublishAsync, MessagingService, Constants.DEPLOY_TOPIC, encode({ rc = 1, q = q, j = jobId, b = branch, t = nowMs() }))
		if published then
			peers.asks += 1
			state.subscribed = true
		else
			state.failure = `publish: {err}`
		end
	end)
	local deadline = os.clock() + Constants.PEER_COLLECT + 1 -- (about 1 s to subscribe and publish)
	local collectUntil = nil
	while os.clock() < deadline and not state.failure do
		if state.subscribed and collectUntil == nil then
			collectUntil = os.clock() + Constants.PEER_COLLECT
		end
		if collectUntil and (os.clock() >= collectUntil or count >= Constants.PEER_ENOUGH) then
			break
		end
		task.wait(0.05)
	end
	state.abandoned = true
	if state.connection then
		pcall(function()
			state.connection:Disconnect()
		end)
	end
	local list = {}
	for _, row in rows do
		table.insert(list, row)
	end
	asking = false
	peers.lastAt = os.time()
	peers.replies = #list
	peers.error = state.failure
	cache = { at = os.clock(), rows = list, error = state.failure }
	return cache
end

-- Groups of healthy peer rows of this branch by build (asset + seq), most common first (then the newest seq).
local function peerChoices(rows: { any }): { any }
	local branch = deps.branch()
	local groups, list = {}, {}
	for _, row in rows do
		if typeof(row) == "table" and row.b == branch and row.h == "ok" and typeof(row.a) == "number" and typeof(row.u) == "number" and row.u >= Constants.PEER_MIN_UPTIME then
			local key = `{row.a}#{tostring(row.s)}`
			local group = groups[key]
			if not group then
				group = { count = 0, row = row }
				groups[key] = group
				table.insert(list, group)
			end
			group.count += 1
			if group.row.sig == nil and row.sig ~= nil then
				group.row = row -- one that carries the signatures
			end
		end
	end
	table.sort(list, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		local seqA = if typeof(a.row.s) == "number" then a.row.s else -1
		local seqB = if typeof(b.row.s) == "number" then b.row.s else -1
		return seqA > seqB
	end)
	return list
end

local function recentLoadFailure(assetId: any): boolean
	local at = typeof(assetId) == "number" and loadFailedAt[assetId]
	return at ~= nil and at ~= false and os.clock() - at < 60
end

-- Runs the most common healthy peer build this kernel trusts. Returns whether it runs.
local function tryPeers(reason: string, fresh: boolean?): boolean
	local result = rollCall(fresh)
	local current = deps.current()
	for _, group in peerChoices(result.rows) do
		if deps.closing() then
			return false
		end
		local row = group.row
		if current and not current.backup and current.artifact.assetId == row.a then
			return true -- already running it
		end
		local head, why = deps.trustPeer(row)
		if not head then
			peers.refused += 1
			deps.refuse("peer", why or "not trusted", { assetId = row.a, artifactId = row.i, seq = row.s, servers = group.count })
		elseif recentLoadFailure(head.assetId) then
			deps.print(`[TypeTorch] peers run {head.artifactId or head.assetId} ({group.count} servers), but it failed to load here less than 60 s ago; skipped for now`)
		else
			peers.chosen = { artifactId = head.artifactId, assetId = head.assetId, seq = head.seq, servers = group.count, at = os.time() }
			deps.print(`[TypeTorch] peers: {group.count} healthy server(s) of {deps.branch()} run {head.artifactId or head.assetId}; loading it`)
			local report = deps.swapTo(head, reason)
			if report.ok then
				deps.noteApplied(head)
				return true
			end
			if report.queued then
				return false -- another swap took over
			end
		end
	end
	return false
end

-- Runs the backup baked into the place. Returns whether it runs.
local function tryBackup(reason: string): boolean
	local head = Fallback.backupHead()
	if not head then
		return false
	end
	deps.print(`[TypeTorch] running the backup build {head.artifactId} (ServerStorage.{Constants.BACKUP_NAME}{if head.backupAt then `, baked {head.backupAt}` else ""})`)
	local report = deps.swapTo(head, reason)
	return report.ok == true
end

-- RECOVERY (5) ------------------------------------------------------------------------------------------------------

local function reasonNow(): string
	if deps.current() then
		return "deploy"
	end
	return if deps.everRan() then "auto-rollback" else "boot"
end

local function startRecovery()
	if recovery.running then
		return
	end
	recovery.running = true
	recovery.stoppedAt = nil
	task.spawn(function()
		local index = 0
		while not deps.closing() do
			if deps.headRunning() then
				break
			end
			index += 1
			local delays = Constants.RECOVER_DELAYS
			local delay = delays[math.min(index, #delays)]
			recovery.nextAt = os.clock() + delay
			task.wait(delay)
			recovery.nextAt = nil
			if deps.closing() or deps.headRunning() then
				break
			end
			if chain.running or not deps.idle() then
				continue -- a swap is running (a deploy, a dev): look again next time
			end
			recovery.attempts += 1
			local current = deps.current()
			-- The head first (a normal swap: players stay).
			local report = deps.retryHead()
			recovery.last = if report then { ok = report.ok, artifactId = report.artifactId, error = report.error, at = os.time() } else recovery.last
			current = deps.current()
			if (current == nil or current.backup) and not deps.closing() then
				-- Then the last known good, then a build other servers run fine.
				deps.retryLastKnownGood()
				current = deps.current()
				if current == nil or current.backup then
					tryPeers(reasonNow(), true)
				end
			end
			if deps.current() == nil and not deps.closing() then
				tryBackup(reasonNow()) -- the backup stays the last resort
			end
			current = deps.current()
			-- Without a usable branch head (a prod server with no trusted head), a real build is as good as it gets: the
			-- 60 s poll and deploy messages move it from there.
			if current and not current.backup and not deps.hasHead() then
				break
			end
		end
		recovery.running = false
		recovery.stoppedAt = os.time()
	end)
end

-- TELEPORT (2) ------------------------------------------------------------------------------------------------------

local function bounceOf(player: Player): number
	local ok, data = pcall(player.GetJoinData, player)
	local teleportData = if ok and typeof(data) == "table" then data.TeleportData else nil
	local mine = if typeof(teleportData) == "table" then teleportData.TypeTorch else nil
	local bounce = if typeof(mine) == "table" then mine.bounce else nil
	if typeof(bounce) ~= "number" or bounce ~= bounce or bounce < 0 then
		return 0
	end
	return math.min(math.floor(bounce), 100)
end

-- Kicks instead of another teleport (the bounce limit, or the teleport tries ran out). Logged and alerted (critical:
-- players are leaving the game).
local function kick(player: Player, why: string, bounce: number?)
	move.kicked += 1
	moving[player] = nil
	local text = if why == "client" then Constants.CLIENT_KICK_MESSAGE else Constants.KICK_MESSAGE
	local cause = if bounce and bounce >= Constants.BOUNCE_MAX then `bounced {bounce} times` else "teleports kept failing"
	deps.warn(`[TypeTorch] kicking {player.Name} ({why}, {cause}): {text}`)
	deps.logEvent({ action = "bounce_kick", userId = player.UserId, why = why, bounce = bounce, cause = cause, branch = deps.branch() })
	deps.alert("critical", "bounce_kick", `kicked {player.UserId} ({why}, {cause}): nothing runs here and moving them didn't help`)
	pcall(player.Kick, player, text)
end

-- A healthy server of this branch with room for `count` players (other than this one), from roll call rows: public
-- ones (ServerInstanceId), or reserved ones with an access code when this server isn't public. The most room first.
local function pickTarget(rows: { any }, count: number): any?
	local branch, jobId, kind = deps.branch(), deps.jobId, deps.serverType()
	local best, bestRoom = nil, -1
	for _, row in rows do
		if typeof(row) == "table" and row.b == branch and row.h == "ok" and validJob(row.j) and row.j ~= jobId and not (move.bad and move.bad[row.j]) then
			local room = (if typeof(row.m) == "number" then row.m else 0) - (if typeof(row.n) == "number" then row.n else 0)
			local usable = row.st == "public" or (row.st == "reserved" and kind ~= "public" and typeof(row.k) == "string" and row.k ~= "")
			if usable and room >= count and room > bestRoom then
				best, bestRoom = row, room
			end
		end
	end
	return best
end

-- One TeleportAsync for `group` (players with the same bounce count). `target` = a roll call row, or { rejoin = true }
-- (this server again), or nil (a fresh server). Returns (ok, error, where).
local function teleportGroup(group: { Player }, bounce: number, target: any?, why: string): (boolean, string?, string?)
	local ok, options = pcall(Instance.new, "TeleportOptions")
	if not ok then
		return false, `TeleportOptions: {options}`, nil
	end
	local where = "a fresh server"
	if target and target.rejoin then
		local kind = deps.serverType()
		if kind == "public" then
			options.ServerInstanceId = deps.jobId
			where = "this server again"
		elseif kind == "reserved" and deps.ownAccessCode() then
			options.ReservedServerAccessCode = deps.ownAccessCode()
			where = "this reserved server again"
		else
			return false, "a private server can't be rejoined by teleport", nil
		end
	elseif target then
		if target.st == "public" then
			options.ServerInstanceId = target.j
		else
			options.ReservedServerAccessCode = target.k
		end
		where = `server {string.sub(target.j, 1, 8)} ({target.st})`
	elseif deps.serverType() ~= "public" then
		-- Private and reserved servers: a new reserved server on the same branch (the kernel stores its branch).
		local code, err = deps.reserveServer()
		if not code then
			return false, `ReserveServer: {err}`, nil
		end
		options.ReservedServerAccessCode = code
		where = "a new reserved server"
	end
	pcall(function()
		options:SetTeleportData({ TypeTorch = { bounce = bounce + 1, from = deps.jobId, why = why } })
	end)
	local sent, err = pcall(TeleportService.TeleportAsync, TeleportService, deps.placeId, group, options)
	if not sent and target and not target.rejoin and validJob(target.j) then
		move.bad = move.bad or {}
		move.bad[target.j] = true -- full or gone: not again
	end
	return sent, if sent then nil else tostring(err), where
end

-- Moves `list` out (each player at most TELEPORT_TRIES times, TELEPORT_RETRY s apart); a player who arrived with
-- BOUNCE_MAX bounces, or whose tries ran out, is kicked. Yields (roll call, TeleportAsync).
local function movePlayers(list: { Player }, why: string)
	if isStudio() then
		return -- teleports don't work in Studio
	end
	local now = os.clock()
	local groups = {}
	for _, player in list do
		if player.Parent ~= nil then
			local entry = moving[player]
			if not entry then
				entry = { attempts = 0, at = -math.huge, why = why, bounce = bounceOf(player) }
				moving[player] = entry
			end
			if entry.bounce >= Constants.BOUNCE_MAX or entry.attempts >= Constants.TELEPORT_TRIES then
				if now - entry.at >= Constants.TELEPORT_RETRY or entry.attempts == 0 then
					kick(player, entry.why, entry.bounce)
				end
			elseif now - entry.at >= Constants.TELEPORT_RETRY then
				entry.attempts += 1
				entry.at = now
				groups[entry.bounce] = groups[entry.bounce] or {}
				table.insert(groups[entry.bounce], player)
			end
		end
	end
	if next(groups) == nil then
		return
	end
	local rows = rollCall().rows
	for bounce, group in groups do
		for first = 1, #group, 50 do -- TeleportAsync takes at most 50 players
			local batch = table.move(group, first, math.min(first + 49, #group), 1, {})
			local target = pickTarget(rows, #batch)
			local ok, err, where = teleportGroup(batch, bounce, target, why)
			if ok then
				move.teleported += #batch
				move.target = where
				deps.print(`[TypeTorch] moving {#batch} player(s) to {where} (bounce {bounce + 1})`)
			else
				move.failures += 1
				move.lastError = err
				deps.warn(`[TypeTorch] teleport to {where or "?"} failed: {err}`)
			end
		end
	end
end

local function enterMove(why: string)
	if move.active then
		return
	end
	move.active = true
	move.since = os.clock()
	move.why = why
	engage("move") -- new joiners are held too; everyone sees "Reconnecting..."
	local text = `nothing runs on this server (head, last known good, peers and backup failed): moving players to another server of {deps.branch() or "?"}`
	deps.warn(`[TypeTorch] {text}`)
	deps.alert("critical", "boot_failed_teleport", text)
	deps.logEvent({ action = "boot_failed_teleport", branch = deps.branch(), players = #Players:GetPlayers() })
	startRecovery()
	task.spawn(movePlayers, Players:GetPlayers(), why)
end

local function leaveMove()
	if not move.active then
		return
	end
	move.active = false
	table.clear(moving)
	deps.print("[TypeTorch] a generation runs again: no more moves")
end

-- CLIENTS -----------------------------------------------------------------------------------------------------------

local resent: { [Player]: string } = {} -- the generation whose client tree was re-sent to the player
local resentCopies: { [string]: { Instance } } = {} -- generation name -> copies in PlayerGuis

local function moveClient(player: Player, generationName: string)
	if moving[player] then
		return
	end
	clients.moved += 1
	deps.kernelSend(player, Constants.CHANNEL_HOLD, "move")
	deps.alert("warning", "client_failed", `{player.UserId}'s client failed to start {generationName} after its retry and a re-send: moving the player`)
	deps.logEvent({ action = "client_moved", userId = player.UserId, generation = generationName })
	if isStudio() then
		deps.warn(`[TypeTorch] {player.Name}'s client can't start {generationName}; teleports don't work in Studio`)
		return
	end
	task.spawn(function()
		local entry = { attempts = 1, at = os.clock(), why = "client", bounce = bounceOf(player) }
		moving[player] = entry
		if entry.bounce >= Constants.BOUNCE_MAX then
			kick(player, "client", entry.bounce)
			return
		end
		local target = pickTarget(rollCall().rows, 1) or { rejoin = true }
		local ok, err, where = teleportGroup({ player }, entry.bounce, target, "client")
		if not ok and not target.rejoin then
			ok, err, where = teleportGroup({ player }, entry.bounce, { rejoin = true }, "client")
		end
		if ok then
			move.teleported += 1
			deps.print(`[TypeTorch] {player.Name}'s client failed: moving them to {where}`)
		else
			move.lastError = err
			kick(player, "client")
		end
	end)
end

local function resendTo(player: Player, generation)
	local gui = player:FindFirstChild("PlayerGui")
	local ok, copy = pcall(function()
		return generation.clientTree:Clone()
	end)
	if not gui or not ok or not copy then
		moveClient(player, generation.name)
		return
	end
	local folder = gui:FindFirstChild("TypeTorchResend")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TypeTorchResend"
		folder.Parent = gui
	end
	local old = folder:FindFirstChild(generation.name)
	if old then
		old:Destroy()
	end
	copy.Name = generation.name
	copy.Parent = folder
	resent[player] = generation.name
	resentCopies[generation.name] = resentCopies[generation.name] or {}
	table.insert(resentCopies[generation.name], copy)
	clients.resent += 1
	deps.print(`[TypeTorch] {player.Name}'s client failed to start {generation.name} after its retry: re-sending the client code`)
	deps.kernelSend(player, Constants.CHANNEL_RESEND, { g = generation.name })
end

-- The kernel's client report handler: `info` = { g, ok, retried?, resent? } (checked by the kernel).
function Fallback.onClientReport(player: Player, info)
	local current = deps.current()
	if typeof(info) ~= "table" or info.ok == true or not current or info.g ~= current.name or player.Parent == nil then
		return
	end
	if info.resent == true or resent[player] == info.g then
		moveClient(player, info.g) -- the re-sent copy failed too
	elseif info.retried == true then
		resendTo(player, current)
	end
end

-- A generation stopped: its re-sent client copies go after the same grace as its client tree.
function Fallback.stopped(generation)
	local copies = resentCopies[generation.name]
	resentCopies[generation.name] = nil
	if copies then
		task.delay(Constants.CLIENT_TREE_GRACE, function()
			for _, copy in copies do
				copy:Destroy()
			end
		end)
	end
	for player, name in resent do
		if name == generation.name then
			resent[player] = nil
		end
	end
end

-- THE KERNEL'S HOOKS ------------------------------------------------------------------------------------------------

-- A generation is ready (swapTo succeeded): the hold ends, and a backup is reported.
function Fallback.ready(generation)
	lastRunningAt = os.clock()
	if move.active then
		leaveMove()
	end
	release(if generation.backup then "backup" else "ready")
	if generation.backup then
		backup.runs += 1
		backup.since = os.time()
		local info = generation.backupInfo or {}
		local text = `nothing else ran: the backup build {generation.artifact.id} (ServerStorage.{Constants.BACKUP_NAME}{if info.at then `, baked {info.at}` else ""}) runs; retrying the real build in the background`
		deps.warn(`[TypeTorch] {text}`)
		deps.alert("critical", "backup_build", text)
		deps.logEvent({ action = "backup_build", artifactId = generation.artifact.id, seq = info.seq, at = info.at, branch = deps.branch() })
		startRecovery()
	else
		backup.since = nil
	end
end

-- The kernel stopped the running generation and its replacement failed to start (a mid-swap failure; plans/17
-- "Should fix" 1): nothing runs now. The kernel cleared ActiveGeneration (clients stop the dead generation's client code
-- and joiners don't start it); here the hold arms again: no character spawns for new joiners, and everyone sees the
-- holding screen while the last known good, peers and the backup are tried (then, after TELEPORT_GRACE, the moves).
-- Players keep the characters they have.
function Fallback.lost(why: string)
	deps.warn(`[TypeTorch] nothing runs after a failed swap ({why}): holding players while the last known good, peers and the backup are tried`)
	engage("start")
end

-- A swap failed (not queued). Boot LOAD failures are remembered (peers skip a build that just failed to load here); the
-- first failure before anything ran starts the roll call in the background, so peers are known when the chain needs
-- them. A failed backup isn't tried again.
function Fallback.attemptFailed(head, report)
	if Fallback.isBackup(head) then
		backup.failed = { error = report.error, stage = report.stage, at = os.time() }
		deps.warn(`[TypeTorch] the backup build failed ({report.stage or "swap"}): {report.error or "?"}`)
		return
	end
	if typeof(head) == "table" and typeof(head.assetId) == "number" and (report.stage == "load" or report.transient) then
		loadFailedAt[head.assetId] = os.clock()
	end
	if not deps.everRan() and not asking and not cache then
		task.spawn(rollCall)
	end
end

-- Whether the boot should start no new candidate: past FALLBACK_AT with a fallback ready (the backup, or peers known
-- to run a build). The candidates left are retried in the background (recovery).
function Fallback.cutOff(): boolean
	if deps.current() or os.clock() - deps.startedAt < Constants.FALLBACK_AT then
		return false
	end
	if backupSource() ~= nil and not backup.failed then
		return true
	end
	return cache ~= nil and #peerChoices(cache.rows) > 0
end

-- The kernel's boot (bootSigned) runs: the chain waits for it.
function Fallback.bootBegin()
	booting += 1
end
function Fallback.bootEnd()
	booting = math.max(0, booting - 1)
end

-- The chain or the recovery is working (the kernel's late-heads boot waits for it).
function Fallback.busy(): boolean
	return chain.running
end

-- The fallbacks after the boot ran nothing: 4 (peers), then 3 (backup), then 5 (recovery); 2 (teleport) is the
-- watchdog's, at the budget.
local function runChain(why: string)
	if chain.running or chain.done or deps.closing() then
		return
	end
	chain.running = true
	chain.at = os.clock()
	chain.why = why
	chain.runs = (chain.runs or 0) + 1
	local ok, err = pcall(function()
		deps.print(`[TypeTorch] nothing runs ({why}): asking the branch's other servers, then the backup`)
		local reason = reasonNow()
		if not deps.current() and tryPeers(reason) then
			chain.result = "peers"
		elseif not deps.current() and tryBackup(reason) then
			chain.result = "backup"
		elseif deps.current() then
			chain.result = "other"
		else
			chain.result = "nothing"
			deps.warn(`[TypeTorch] no peer build and {if backupSource() then "the backup failed" else "no backup in the place"}: retrying in the background; players are moved at the boot budget`)
		end
	end)
	if not ok then
		deps.warn(`[TypeTorch] the fallback chain failed: {err}`)
	end
	chain.running = false
	chain.done = true
	if not deps.headRunning() then
		startRecovery()
	end
end

-- The watchdog. `Fallback.start()` is called once the kernel's boot section returned.
function Fallback.start()
	bootReturned = true
	if started then
		return
	end
	started = true
	Players.PlayerAdded:Connect(function(player)
		if move.active then
			task.spawn(movePlayers, { player }, move.why or "boot")
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		moving[player] = nil
		resent[player] = nil
	end)
	task.spawn(function()
		local studioWarned = false
		local idleSince = nil
		while not deps.closing() do
			local now = os.clock()
			if deps.current() then
				lastRunningAt = now
				idleSince = nil
				chain.done = false -- the next time nothing runs is a new episode (mid-swap failure): the chain runs again
				if move.active then
					leaveMove()
					release("recovered")
				end
			else
				local sinceStart = now - deps.startedAt
				local idle = deps.idle() and booting == 0 and not chain.running
				-- Debounced: a failed swap defers its last-known-good restore, so "idle with nothing running" must last a moment.
				idleSince = if idle then (idleSince or now) else nil
				local settled = idleSince ~= nil and now - idleSince >= 0.25
				-- 4 -> 3: once per episode, after the boot (or at FALLBACK_AT when the boot is still on a candidate: it stops
				-- there), or after a mid-swap failure whose last-known-good chain ran nothing.
				if settled and not chain.done and not deps.localMode() and (bootReturned or sinceStart >= Constants.FALLBACK_AT) then
					runChain(if lastRunningAt ~= nil then "a failed swap and the last known good ran nothing" elseif bootReturned then "the head and the last known good ran nothing" else "boot out of time")
				end
				-- 2: past the boot budget (or TELEPORT_GRACE after the last generation stopped), nothing runs.
				local quiet = lastRunningAt == nil or now - lastRunningAt >= Constants.TELEPORT_GRACE
				if settled and (chain.done or deps.localMode()) and sinceStart >= Constants.BOOT_BUDGET and quiet and not move.active then
					if isStudio() then
						if not studioWarned then
							studioWarned = true
							deps.warn("[TypeTorch] Studio: nothing runs after the boot budget; releasing the hold so you can look around (live servers move players to another server)")
							release("studio")
						end
					else
						enterMove(if lastRunningAt == nil then "boot" else "crash")
					end
				end
				if move.active then
					movePlayers(Players:GetPlayers(), move.why or "boot") -- retries players still here; kicks after TELEPORT_TRIES
				end
			end
			task.wait(if move.active then 1 else 0.1)
		end
	end)
end

-- The kernel errored before Fallback.start (no swaps, no configured deps): the held players (and new joiners) are moved
-- with what `game` itself says (a fresh server; private and reserved servers can't reserve one without the kernel, so
-- their players are kicked with the restart message after the teleport tries). Studio releases them instead.
deadman = function()
	if started then
		return
	end
	deps.jobId = game.JobId
	deps.placeId = game.PlaceId
	if game.PrivateServerId ~= "" then
		local kind = if game.PrivateServerOwnerId ~= 0 then "private" else "reserved"
		deps.serverType = function()
			return kind
		end
	end
	deps.warn(`[TypeTorch] the kernel didn't finish its boot (see the error above): {if isStudio() then "releasing the held players (Studio)" else "moving players to another server"}`)
	if isStudio() then
		release("kernel error")
		return
	end
	move.active = true
	move.since = os.clock()
	move.why = "kernel"
	engage("move")
	Players.PlayerAdded:Connect(function(player)
		task.spawn(movePlayers, { player }, "kernel")
	end)
	Players.PlayerRemoving:Connect(function(player)
		moving[player] = nil
	end)
	task.spawn(function()
		while true do
			movePlayers(Players:GetPlayers(), "kernel")
			task.wait(1)
		end
	end)
end

-- The kernel's deploy-topic handler hands roll call asks here ({ rc = 1, q, j, b, t }). Untrusted input.
do
	local replied: { number } = {}
	local lastReplyTo: { [string]: number } = {}
	function Fallback.onAsk(data)
		if typeof(data) ~= "table" or typeof(data.q) ~= "number" or not validJob(data.j) or typeof(data.t) ~= "number" or typeof(data.b) ~= "string" then
			peers.ignored += 1
			return
		end
		if data.j == deps.jobId or not validJob(deps.jobId) or math.abs(nowMs() - data.t) > Constants.PEER_ASK_MAX_AGE * 1000 then
			peers.ignored += 1
			return
		end
		if data.b ~= deps.branch() or deps.peerRow() == nil then
			return -- another branch, or nothing worth offering here
		end
		local now = os.clock()
		while #replied > 0 and now - replied[1] >= 60 do
			table.remove(replied, 1)
		end
		local last = lastReplyTo[data.j]
		if (last and now - last < Constants.PEER_REPLY_GAP) or #replied >= Constants.PEER_REPLIES_PER_MINUTE then
			peers.limited += 1
			return
		end
		lastReplyTo[data.j] = now
		table.insert(replied, now)
		task.spawn(function()
			task.wait(math.random() * Constants.PEER_REPLY_JITTER)
			local row = deps.peerRow()
			if not row then
				return
			end
			row.q = data.q
			row.j = deps.jobId
			local body = encode(row)
			for _, field in { "k", "sigF", "c" } do
				if #body <= 950 then
					break
				end
				row[field] = nil
				body = encode(row)
			end
			if #body > 950 then
				return
			end
			local ok, err = pcall(MessagingService.PublishAsync, MessagingService, `{Constants.PEER_TOPIC}/{data.j}`, body)
			if ok then
				peers.answered += 1
			else
				deps.warn(`[TypeTorch] roll call reply failed: {err}`)
			end
		end)
	end
end

-- For status().fallback (and the dev menu). Never an access code.
function Fallback.status()
	local now = os.clock()
	local info = backupInfo()
	return {
		hold = {
			active = hold.active,
			mode = hold.mode,
			optOut = hold.optOut or nil,
			characters = hold.controls or nil,
			heldMs = hold.heldMs,
			seconds = if hold.active and hold.startedAt then math.floor((now - hold.startedAt) * 10 + 0.5) / 10 else nil,
			released = if hold.releasedAt then math.floor((hold.releasedAt - deps.startedAt) * 10 + 0.5) / 10 else nil,
			spawned = hold.spawned,
		},
		backup = {
			available = info ~= nil,
			artifactId = info and info.artifactId,
			seq = info and info.seq,
			branch = info and info.branch,
			at = info and info.at,
			failed = if backup.failed then table.clone(backup.failed) else nil,
			runs = backup.runs,
			since = backup.since,
		},
		peers = {
			asks = peers.asks,
			answered = peers.answered,
			replies = peers.replies,
			lastAt = peers.lastAt,
			refused = peers.refused,
			chosen = if peers.chosen then table.clone(peers.chosen) else nil,
			error = peers.error,
		},
		chain = { runs = chain.runs or 0, result = chain.result, why = chain.why, at = if chain.at then math.floor((chain.at - deps.startedAt) * 10 + 0.5) / 10 else nil },
		recovery = {
			running = recovery.running,
			attempts = recovery.attempts,
			nextIn = if recovery.nextAt then math.max(0, math.ceil(recovery.nextAt - now)) else nil,
			last = if recovery.last then table.clone(recovery.last) else nil,
		},
		moving = {
			active = move.active,
			since = if move.since then math.floor((move.since - deps.startedAt) * 10 + 0.5) / 10 else nil,
			teleported = move.teleported,
			kicked = move.kicked,
			failures = move.failures,
			lastError = move.lastError,
			target = move.target,
		},
		clients = { resent = clients.resent, moved = clients.moved },
	}
end

-- { resent, moved } for status().clients and the fleet status.
function Fallback.clientCounts()
	return clients.resent, clients.moved
end

return Fallback
