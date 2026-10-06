--!nonstrict
-- Where the kernel learns which artifact a branch runs, and the project settings it follows.
--
--   * The signed settings record (0.3.8, Settings.luau, plans/20; it replaced the ConfigService registry key
--     "TypeTorch", which the CLI could never write with an API key): `defaultBranch`, `channels` and the dev lists
--     (`access`). Registry.state() is built from it:
--       { v, defaultBranch, channels = { [branch] = "prod"|"dev" }, members = { [userId] = role },
--         revoked = { [userId] = true }, devBadgeId?, branches = {}, deployments = {} }
--     (`branches` and `deployments` stay empty since 0.3.8: heads and history come from the stores below).
--   * In-game DataStore "TypeTorch" for what game servers write themselves (no Open Cloud scope needed):
--       heads                      { [branch] = { assetId, artifactId, seq, commit, channel, deployedAt, rollout?, t?,
--                                  rollback?, sig?, sigF? } } (from deploy messages, and since 0.3.5 the CLI's durable
--                                  copy; higher seq wins, but a signed prod head (0.3) is never replaced by an unsigned
--                                  one; mirrored in MemoryStore HashMap "TypeTorch" for polling; see "Branch heads"
--                                  below). Game code can write these stores, so prod servers (0.3) only follow heads
--                                  whose signatures check out (Signing.luau).
--       private/<PrivateServerId>  { branch, setBy, setAt, pin?, code? } (private and reserved servers' branch; `pin` =
--                                  { assetId, artifactId, seq, commit, channel, branch, headSeq } boots that artifact
--                                  until the branch gets a deploy newer than headSeq; `code` (0.3.2) = a reserved
--                                  server's access code, kept by every later write)
--       deployments                { list }                   (newest first, at most 100: { seq, branch, channel,
--                                  artifactId, assetId, commit, at, rollback?, rollout?, t?, sig?, sigF? } from deploy
--                                  messages and known heads; rollout = the deploy's `ro` %, 0.2.3; t/sig/sigF 0.3;
--                                  0.3.2: written by the server that won the head's MemoryStore update only)
--       settings                   the signed settings record (0.3.8; written by the CLI only; Settings.luau)
--       events/<date>/<job>/<n>    { action, at, ... }        (0.3.2: one key per event, SetAsync: automatic and
--                                  server-local rollbacks, health rollbacks, pins, refusals; the 0.3.1 `events` list
--                                  key is no longer written)
--
-- Studio: ServerStorage.TypeTorchDev's `Branch` attribute picks the branch (the kernel's chooseBranch), and a
-- "Payload" Model child is mounted instead of any head (the kernel's "Studio local payload"). 0.3.8: the `Registry`
-- JSON and `BootAssetId` attributes (stand-ins for a ConfigService registry Studio couldn't read) are gone.

local DataStoreService = game:GetService("DataStoreService")
local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

-- 0.3.8: the signed settings. A place project that lists the kernel's files one by one and doesn't map Settings.luau yet
-- still boots, with the defaults (defaultBranch "prod", no channels, only the creator as a dev, no fleet API), and says
-- so.
local Settings
do
	local module = script.Parent:FindFirstChild("Settings")
	if module then
		Settings = require(module)
	else
		warn("[TypeTorch] TypeTorchKernel.Settings is missing (map src/server/Settings.luau in the place project): no signed settings on this server (defaults)")
		Settings = {
			missing = true,
			start = function() end,
			refresh = function() end,
			ping = function() end,
			settled = function()
				return true
			end,
			known = function()
				return true
			end,
			readOk = function()
				return true
			end,
			readError = function()
				return nil
			end,
			current = function()
				return nil
			end,
			copy = function()
				return nil
			end,
			onChange = function()
				return function() end
			end,
			field = function()
				return true, nil
			end,
			status = function()
				return { state = "missing", fields = {}, reads = 0, error = "the place doesn't map the kernel's Settings module" }
			end,
		}
	end
end

local Registry = {}

-- The settings module (status, copies for the API, pings); Registry.state() is the part this module derives.
Registry.settings = Settings

local listeners = {}
local store: DataStore? = nil

-- Registry.state() from a settings body (nil: the defaults).
local function stateFrom(body)
	body = if typeof(body) == "table" then body else {}
	local access = if typeof(body.access) == "table" then body.access else {}
	local channels = {}
	if typeof(body.channels) == "table" then
		for branch, channel in body.channels do
			if typeof(branch) == "string" and (channel == "prod" or channel == "dev") then
				channels[branch] = channel
			end
		end
	end
	return {
		v = 1,
		defaultBranch = if typeof(body.defaultBranch) == "string" and body.defaultBranch ~= "" then body.defaultBranch else "prod",
		channels = channels,
		members = if typeof(access.members) == "table" then access.members else {},
		revoked = if typeof(access.revoked) == "table" then access.revoked else {},
		devBadgeId = tonumber(access.devBadgeId),
		branches = {},
		deployments = {},
	}
end

local state = stateFrom(nil)

-- Every new good copy of the settings (and the first successful read, even of a missing record) rebuilds the state and
-- tells the listeners (fn(newState, oldState)).
Settings.onChange(function(body)
	local before = state
	state = stateFrom(body)
	for _, listener in listeners do
		task.spawn(listener, state, before)
	end
end)

-- Starts the boot read of the settings (doesn't yield; boot waits for Registry.configSettled within its gate). Returns
-- the state (the defaults until the read lands).
function Registry.start(): any
	Settings.start()
	return state
end

-- 0.3.2 (boot budget): whether boot may stop waiting for the settings: the first read finished (found, missing or
-- failed; a failure is retried by the sync loop).
function Registry.configSettled(): boolean
	return Settings.settled()
end

-- The last settings read succeeded.
function Registry.connected(): boolean
	return Settings.readOk()
end

-- 0.3.2 (S-M2): a settings read has succeeded at least once (a missing record counts), so `revoked` (and `members`)
-- are known.
function Registry.known(): boolean
	return Settings.known()
end

-- The last settings problem (a failed read, a refused copy), or nil.
function Registry.readError(): string?
	return Settings.readError()
end

-- (ok, value) of one settings field (e.g. "fleet"): ok = false until the first read finished, value = nil when missing.
function Registry.settingsField(name: string): (boolean, any)
	return Settings.field(name)
end

-- 0.3.2 (audit: one sync loop owner): THE periodic loop of the kernel. Every `interval` seconds it re-reads the
-- settings (at most every SETTINGS_REFRESH_SECONDS), then calls `onTick` (the kernel re-reads the stored head and
-- follows it). Errors in a tick are logged and don't end the loop. Call once.
local syncStarted = false
function Registry.startSync(interval: number, onTick: () -> ())
	assert(not syncStarted, "Registry.startSync runs once")
	syncStarted = true
	task.spawn(function()
		while true do
			task.wait(interval)
			local settingsOk, settingsError = pcall(Settings.refresh, Constants.SETTINGS_REFRESH_SECONDS)
			if not settingsOk then
				warn(`[TypeTorch] settings refresh failed: {settingsError}`)
			end
			local ok, tickError = pcall(onTick)
			if not ok then
				warn(`[TypeTorch] sync tick failed: {tickError}`)
			end
		end
	end)
end

function Registry.state()
	return state
end

-- fn(newState, oldState) after every change.
function Registry.onChange(fn)
	table.insert(listeners, fn)
end

-- Branch heads persisted by game servers from deploy messages (and, 0.3.5, by the CLI): every server that receives a
-- deploy message records the head, so servers started later still boot the right artifact. The head with the higher
-- seq wins between the sources.
--
-- All heads live in ONE key, { [branch] = head }, so a read is one request and listing branches needs no ListKeysAsync
-- (its budget is a few calls per minute per server; the dev menu used to hit it on every Branch tab load):
--   * MemoryStore HashMap "TypeTorch", key "heads": the fast copy every server polls (universe-wide quota, cheap);
--   * DataStore "TypeTorch", key "heads": the durable copy (MemoryStore entries expire), read at boot, when MemoryStore
--     fails or holds an untrusted prod head, and (0.3.5) about every HEADS_DURABLE_SECONDS anyway. Kernel 0.2.0's
--     per-branch "head/<branch>" keys are read once at boot as a migration fallback.
-- Writes: the server whose MemoryStore update wins (seq newer than what's stored) also writes the DataStore copy, so a
-- deploy costs one durable write however many servers hear the message.
-- 0.3.5 (durable heads): the CLI writes the DataStore copy itself after every deploy message (it can't write
-- MemoryStore, and the registry needs a scope API keys can't get), so a deploy made while NO server of that branch ran
-- is no longer lost: new servers boot it (the boot reads both copies) and running ones find it on the periodic durable
-- read and follow it like a polled head (prod: the same signature checks). When the durable copy holds a head that
-- replaces MemoryStore's, the server writes MemoryStore back (one UpdateAsync with the same `replaces` rule, so only the
-- first server's write changes anything) and the fast copy catches up. Budget: one DataStore GetAsync per server per
-- HEADS_DURABLE_SECONDS (55 s, so one per 60 s sync tick) for the periodic read, out of a server's 60 + 10 x players
-- reads a minute; the MemoryStore write-back only while the fast copy is behind.
local storedHeads: { [string]: any } = {}
local headsReadAt = -math.huge
local durableReadAt = -math.huge -- 0.3.5: the last DataStore read of `heads` (the periodic one is rate-limited)
local HEADS_KEY = "heads"
local HEADS_TTL = 45 * 24 * 3600 -- MemoryStore maximum

local memoryHeads: MemoryStoreHashMap? = nil

local function getStore(): DataStore
	if not store then
		store = DataStoreService:GetDataStore(Constants.DATASTORE)
	end
	return store :: DataStore
end

local function getMemory(): MemoryStoreHashMap
	if not memoryHeads then
		memoryHeads = game:GetService("MemoryStoreService"):GetHashMap(Constants.DATASTORE)
	end
	return memoryHeads :: MemoryStoreHashMap
end

local function isHead(value): boolean
	return typeof(value) == "table" and typeof(value.assetId) == "number"
end

-- 0.3: trust(branch, head) -> "trusted" (a signed prod head), "untrusted" (an unsigned head on a prod branch) or nil
-- (no opinion: dev branches). Installed by the kernel (Signing). A trusted head is never replaced by one that isn't,
-- whatever its seq, so a forged high-seq head (game code can write these stores) can't push a signed one out.
local trust: ((string, any) -> string?)? = nil

function Registry.setTrust(fn: (string, any) -> string?)
	trust = fn
end

local function trustOf(branch: string?, head): string?
	if not trust or branch == nil or not isHead(head) then
		return nil
	end
	local ok, verdict = pcall(trust, branch, head)
	return if ok then verdict else nil
end

-- Whether `head` should replace `stored`: a newer seq, or (0.2.3) the same deploy re-sent later (its message's `t`,
-- sent ms) with another rollout %, so a wider or narrower rollout of one deploy reaches the stored copies too.
local function replaces(stored, head, branch: string?): boolean
	if not isHead(stored) then
		return true
	end
	local storedTrust, headTrust = trustOf(branch, stored), trustOf(branch, head)
	if storedTrust == "trusted" and headTrust ~= "trusted" then
		return false
	elseif headTrust == "trusted" and storedTrust ~= "trusted" then
		return true
	end
	local storedSeq, seq = stored.seq or 0, head.seq or 0
	if seq ~= storedSeq then
		return seq > storedSeq
	end
	if stored.assetId ~= head.assetId or stored.rollout == head.rollout then
		return false
	end
	local storedAt = if typeof(stored.t) == "number" then stored.t else 0
	local at = if typeof(head.t) == "number" then head.t else 0
	return at > storedAt
end

-- 0.3.6 (plans/18): the stored `heads` key holds at most HEADS_MAX_BRANCHES branches. A head for a NEW branch beyond
-- that isn't written (anything in the universe can publish deploy messages, so the key could grow without bound); the
-- branches already there keep updating. Reads are never capped (a server must find its own branch's head).
local warnedFull: { [string]: boolean } = {}
local function branchCount(heads: any): number
	local count = 0
	if typeof(heads) == "table" then
		for _ in heads do
			count += 1
		end
	end
	return count
end
local function admitsBranch(heads: any, branch: string): boolean
	if typeof(heads) ~= "table" or heads[branch] ~= nil or branchCount(heads) < (Constants.HEADS_MAX_BRANCHES or 32) then
		return true
	end
	if not warnedFull[branch] then
		warnedFull[branch] = true
		warn(`[TypeTorch] the stored heads hold {branchCount(heads)} branches (the most, HEADS_MAX_BRANCHES): branch {branch} isn't recorded from deploy messages (the CLI's durable copy still has it)`)
	end
	return false
end
Registry.admitsBranch = admitsBranch

-- Keeps the newer head per branch (by seq) from a { [branch] = head } table.
local function mergeHeads(into: { [string]: any }, from: any): boolean
	if typeof(from) ~= "table" then
		return false
	end
	local changed = false
	for branch, head in from do
		if typeof(branch) == "string" and isHead(head) then
			local current = into[branch]
			if not current or replaces(current, head, branch) then
				into[branch] = head
				changed = true
			end
		end
	end
	return changed
end

-- 0.3: a prod branch whose MemoryStore head isn't signed (when we hold no signed one either): read the durable copy too.
local function needsDurable(heads: any): boolean
	if not trust or typeof(heads) ~= "table" then
		return false
	end
	for branch, head in heads do
		if typeof(branch) == "string" and trustOf(branch, head) == "untrusted" and trustOf(branch, storedHeads[branch]) ~= "trusted" then
			return true
		end
	end
	return false
end

-- 0.3.5: the heads in `durable` that replace MemoryStore's (`memory` as read; nil = no key there), or nil.
local function newerThanMemory(durable: any, memory: any): { [string]: any }?
	if typeof(durable) ~= "table" then
		return nil
	end
	local found = nil
	for branch, head in durable do
		if typeof(branch) == "string" and isHead(head) then
			local fast = if typeof(memory) == "table" then memory[branch] else nil
			if replaces(fast, head, branch) then
				found = found or {}
				found[branch] = head
			end
		end
	end
	return found
end

-- 0.3.5: writes durable heads the MemoryStore copy lacks back into it (non-blocking). The transform re-checks `replaces`
-- against what MemoryStore holds then, so when several servers notice at once only the first write changes anything.
local function writeMemoryBack(newer: { [string]: any })
	task.spawn(function()
		pcall(function()
			getMemory():UpdateAsync(HEADS_KEY, function(existing)
				local heads = if typeof(existing) == "table" then existing else {}
				local changed = false
				for branch, head in newer do
					if replaces(heads[branch], head, branch) and admitsBranch(heads, branch) then
						heads[branch] = head
						changed = true
					end
				end
				return if changed then heads else nil
			end, HEADS_TTL)
		end)
	end)
end

-- Re-reads all heads (yields): MemoryStore, then the DataStore copy when MemoryStore failed or holds an untrusted prod
-- head, and (0.3.5) at most every HEADS_DURABLE_SECONDS anyway (the CLI writes only that copy). At most once per
-- `maxAge` seconds (default 15).
function Registry.refreshHeads(maxAge: number?)
	if os.clock() - headsReadAt < (maxAge or 15) then
		return
	end
	headsReadAt = os.clock()
	local ok, value = pcall(function()
		return getMemory():GetAsync(HEADS_KEY)
	end)
	local memory = if ok and typeof(value) == "table" then value else nil
	if memory then
		mergeHeads(storedHeads, memory)
	end
	local due = os.clock() - durableReadAt >= Constants.HEADS_DURABLE_SECONDS
	if ok and not due and not needsDurable(memory) then
		return
	end
	durableReadAt = os.clock()
	local durableOk, durable = pcall(function()
		return getStore():GetAsync(HEADS_KEY)
	end)
	if durableOk then
		mergeHeads(storedHeads, durable)
		-- The fast copy is behind (a deploy nobody heard, or MemoryStore expired): catch it up. Not when MemoryStore just
		-- failed (its state is unknown).
		local newer = if ok then newerThanMemory(durable, memory) else nil
		if newer then
			writeMemoryBack(newer)
		end
	end
end

-- 0.3.2 (boot budget): at boot both copies are read at once, in parallel, and kept as they came (the boot fail-safe
-- looks at each copy's own head of the branch). Boot waits until `headsSettled()` (MemoryStore answered with nothing
-- that needs the durable copy, or the DataStore copy answered), at most BOOT_READS_WAIT; slow reads keep going and merge
-- when they land. Later refreshes (the sync loop) skip while these are recent.
local bootMemory = { done = false, ok = false, answered = false, value = nil }
local bootDurable = { done = false, ok = false, value = nil }
-- 0.3.5: once both boot reads answered, durable heads MemoryStore lacks are written back (the deploys nobody heard).
local function catchUpAfterBoot()
	if not (bootMemory.done and bootDurable.done and bootMemory.answered and bootDurable.ok) then
		return
	end
	local newer = newerThanMemory(bootDurable.value, if bootMemory.ok then bootMemory.value else nil)
	if newer then
		writeMemoryBack(newer)
	end
end
function Registry.startBootReads()
	headsReadAt = os.clock()
	durableReadAt = os.clock()
	task.spawn(function()
		local ok, value = pcall(function()
			return getMemory():GetAsync(HEADS_KEY)
		end)
		bootMemory.ok, bootMemory.answered, bootMemory.value, bootMemory.done = ok and typeof(value) == "table", ok, value, true
		if bootMemory.ok then
			mergeHeads(storedHeads, value)
		end
		catchUpAfterBoot()
	end)
	task.spawn(function()
		local ok, value = pcall(function()
			return getStore():GetAsync(HEADS_KEY)
		end)
		bootDurable.ok, bootDurable.value, bootDurable.done = ok and typeof(value) == "table", value, true
		if bootDurable.ok then
			mergeHeads(storedHeads, value)
		end
		catchUpAfterBoot()
	end)
end

-- 0.3.5: the durable copy is waited for too (still within BOOT_READS_WAIT): the CLI writes only that copy, so it can
-- hold a newer head than MemoryStore (a deploy no running server heard), and a new server should boot that head rather
-- than the older one and swap a moment later. A DataStore read that fails or hangs doesn't hold the boot past the gate.
function Registry.headsSettled(): boolean
	return bootDurable.done
end

-- Both boot reads are over (whatever they found).
function Registry.headsDone(): boolean
	return bootMemory.done and bootDurable.done
end

-- Kernel 0.2.0 stored one key per branch; read this branch's old key once (boot only). 0.3.2: it goes through saveHead,
-- so the migrated head also lands in the shared `heads` copies (winner-only, and never over a newer or trusted head).
function Registry.migrateLegacyHead(branch: string)
	if storedHeads[branch] then
		return
	end
	local ok, value = pcall(function()
		return getStore():GetAsync("head/" .. branch)
	end)
	if ok and isHead(value) then
		Registry.saveHead(branch, value)
	end
end

-- The stored head of `branch`, refreshed when older than `maxAge` seconds (default 15). Yields when it refreshes.
function Registry.refreshStoredHead(branch: string, maxAge: number?)
	Registry.refreshHeads(maxAge)
	return storedHeads[branch]
end

-- A durable DataStore write, retried after 1, 3 and 9 s (only the winner writes, so it must not give up at once).
local function durably(write: () -> ())
	for _, delay in { 0, 1, 3, 9 } do
		if delay > 0 then
			task.wait(delay)
		end
		if pcall(write) then
			return true
		end
	end
	return false
end

-- Records a branch head from a deploy message. `deployments` (0.3.2, optional) are the deployment entries that came
-- with it. Winner-only durable writes: every server that hears the message updates the MemoryStore copy; only the one
-- whose update wins (the head was new there) writes the DataStore `heads` copy AND the `deployments` list, so a deploy
-- costs one durable write of each however many servers hear it. MemoryStore down: every server writes them itself.
function Registry.saveHead(branch: string, head, deployments: { any }?)
	if deployments then
		Registry.recordDeployments(deployments, false) -- this server's copy now; the durable list below, winner only
	end
	local current = storedHeads[branch]
	if current and not replaces(current, head, branch) then
		return
	end
	if not admitsBranch(storedHeads, branch) then
		return -- 0.3.6: a new branch beyond HEADS_MAX_BRANCHES
	end
	storedHeads[branch] = head
	task.spawn(function()
		local won = false
		local memoryOk = pcall(function()
			getMemory():UpdateAsync(HEADS_KEY, function(existing)
				local heads = if typeof(existing) == "table" then existing else {}
				local stored = heads[branch]
				if not replaces(stored, head, branch) or not admitsBranch(heads, branch) then
					won = false
					return nil -- another server already stored this deploy (or a newer one), or the key is full
				end
				heads[branch] = head
				won = true
				return heads
			end, HEADS_TTL)
		end)
		-- Lost the race: the winner writes the durable copies. MemoryStore down: write them ourselves.
		if memoryOk and not won then
			return
		end
		durably(function()
			getStore():UpdateAsync(HEADS_KEY, function(existing)
				local heads = if typeof(existing) == "table" then existing else {}
				local stored = heads[branch]
				if not replaces(stored, head, branch) or not admitsBranch(heads, branch) then
					return nil
				end
				heads[branch] = head
				return heads
			end)
		end)
		if deployments then
			Registry.writeDeploymentsDurably(deployments)
		end
	end)
end

-- Branch names with a stored head. Yields when the cached heads are older than 30 s; for the dev menu.
function Registry.storedBranches(): { string }
	Registry.refreshHeads(30)
	local names = {}
	for name in storedHeads do
		table.insert(names, name)
	end
	return names
end

-- The branch's stored head (0.3.8: the only source; the ConfigService head is gone). 0.3: with `accept`, only a head it
-- accepts counts (prod servers pass a check for signed prod heads).
function Registry.branchHead(name: string, accept: ((any) -> boolean)?)
	local fromStore = storedHeads[name]
	if fromStore and accept and not (isHead(fromStore) and accept(fromStore)) then
		return nil
	end
	return fromStore
end

-- 0.3 boot fail-safe: every head this server can find for `branch` (the cached copy, and what the boot
-- reads of the MemoryStore and DataStore copies brought), distinct by asset and seq, newest seq first. 0.3.2: no yield.
-- Untrusted: the kernel checks each one.
function Registry.bootCandidates(branch: string): { any }
	local list, seen = {}, {}
	local function add(head)
		if isHead(head) then
			local key = `{head.assetId}#{tostring(head.seq)}`
			if not seen[key] then
				seen[key] = true
				table.insert(list, head)
			end
		end
	end
	add(storedHeads[branch])
	-- 0.3.2 (boot budget): the copies the boot reads brought (no new read here, so a slow store can't hold the boot).
	if bootMemory.ok then
		add(bootMemory.value[branch])
	end
	if bootDurable.ok then
		add(bootDurable.value[branch])
	end
	table.sort(list, function(a, b)
		local seqA, seqB = if typeof(a.seq) == "number" then a.seq else -1, if typeof(b.seq) == "number" then b.seq else -1
		return seqA > seqB
	end)
	return list
end

-- 0.3.6 (plans/18): whether this server knows `branch` (the settings' `channels`, or a stored head). Prod servers record
-- deploy messages of unknown branches only when they are signed.
function Registry.knowsBranch(branch: string): boolean
	return Registry.state().channels[branch] ~= nil or storedHeads[branch] ~= nil
end

-- A deploy message of an unknown branch was ignored: one line per minute at most, with the count.
local ignored = { count = 0, printedAt = -math.huge, held = 0 }
function Registry.noteIgnoredBranch(branch: string)
	ignored.count += 1
	if os.clock() - ignored.printedAt < 60 then
		ignored.held += 1
		return
	end
	ignored.printedAt = os.clock()
	local more = if ignored.held > 0 then ` ({ignored.held} more since the last line)` else ""
	ignored.held = 0
	print(`[TypeTorch] deploy message for unknown branch {string.sub(branch, 1, 64)} not recorded on this prod server (unsigned){more}; the CLI's durable copy has it`)
end
function Registry.ignoredBranches(): number
	return ignored.count
end

-- 0.3: the candidate heads of a branch: (nil, stored). 0.3.8: the first (the ConfigService head) is always nil; the
-- shape stays for the callers.
function Registry.headCandidates(name: string): (any?, any?)
	local fromStore = storedHeads[name]
	return nil, if isHead(fromStore) then fromStore else nil
end

function Registry.channelOf(branch: string): string
	local head = Registry.branchHead(branch)
	local configured = Registry.state().channels[branch]
	return configured or (head and head.channel) or (if branch == Registry.state().defaultBranch then "prod" else "dev")
end

-- In-game DataStore (game-written data) ---------------------------------------------------------------------------

-- A private or reserved server's stored choice: { branch, setBy, setAt, pin?, code? } or nil; (nil, error) when the read
-- failed. `code` (0.3.2) is a reserved server's access code (newServer and the framework's Migrate store it).
function Registry.privateOverride(privateServerId: string): (any, string?)
	local ok, value = pcall(function()
		return getStore():GetAsync("private/" .. privateServerId)
	end)
	if not ok then
		return nil, tostring(value)
	end
	if typeof(value) ~= "table" or typeof(value.branch) ~= "string" then
		return nil, nil
	end
	if typeof(value.pin) ~= "table" or typeof(value.pin.assetId) ~= "number" then
		value.pin = nil
	end
	if typeof(value.code) ~= "string" or #value.code > 200 then
		value.code = nil
	end
	return value, nil
end

function Registry.privateBranch(privateServerId: string): (string?, string?)
	local value, err = Registry.privateOverride(privateServerId)
	return if value then value.branch else nil, err
end

-- `pin` (optional) makes the server boot that artifact instead of the branch head; see the header. `code` (0.3.2,
-- optional): the reserved server's access code (newServer); a record's existing code is kept when none is given.
function Registry.setPrivateBranch(privateServerId: string, branch: string, userId: number, pin: any?, code: string?): (boolean, string?)
	local ok, err = pcall(function()
		getStore():UpdateAsync("private/" .. privateServerId, function(existing)
			local keep = if typeof(existing) == "table" and typeof(existing.code) == "string" then existing.code else nil
			return {
				branch = branch,
				setBy = userId,
				setAt = DateTime.now():ToIsoDate(),
				pin = pin,
				code = code or keep,
			}
		end)
	end)
	return ok, if ok then nil else tostring(err)
end

-- Deployment history (in-game DataStore key "deployments") -----------------------------------------------------------
-- Every server that hears a deploy message records it, so the dev menu can list and pin earlier artifacts without the
-- CLI's registry. Entries are deduped by branch + seq (seq is global across branches); the newest 100 are kept.

local storedDeployments: { any } = {}
local deploymentsReadAt = -math.huge

local function deploymentKey(entry): string
	if typeof(entry.seq) == "number" then
		return `{entry.branch}#{entry.seq}`
	end
	return `{entry.branch}@{entry.assetId}`
end

local function cleanDeployment(entry): any?
	if typeof(entry) ~= "table" or typeof(entry.branch) ~= "string" or typeof(entry.assetId) ~= "number" then
		return nil
	end
	return {
		seq = if typeof(entry.seq) == "number" then entry.seq else nil,
		branch = entry.branch,
		channel = if entry.channel == "prod" or entry.channel == "dev" then entry.channel else nil,
		artifactId = if typeof(entry.artifactId) == "string" then entry.artifactId else nil,
		assetId = entry.assetId,
		commit = if typeof(entry.commit) == "string" then entry.commit else nil,
		at = if typeof(entry.at) == "string" then entry.at else nil,
		rollback = if entry.rollback == true or entry.action == "rollback" then true else nil,
		rollout = if typeof(entry.rollout) == "number" and entry.rollout >= 1 and entry.rollout < 100 then entry.rollout else nil,
		-- 0.3: what the signatures cover (t) and the signatures, so prod servers can check an entry before a pin, and
		-- the dev menu can show verified badges.
		t = if typeof(entry.t) == "number" then entry.t else nil,
		r = if entry.r == 1 or entry.r == "resign" then entry.r else nil,
		sig = if typeof(entry.sig) == "string" and #entry.sig <= 100 then entry.sig else nil,
		sigF = if typeof(entry.sigF) == "string" and #entry.sigF <= 100 then entry.sigF else nil,
	}
end

local function newestFirst(a, b): boolean
	local seqA, seqB = a.seq or -1, b.seq or -1
	if seqA ~= seqB then
		return seqA > seqB
	end
	if (a.at or "") ~= (b.at or "") then
		return (a.at or "") > (b.at or "")
	end
	return a.branch < b.branch
end

-- Merges lists (earlier lists win on duplicates), newest first, at most `limit` entries. An entry without a seq is
-- dropped when the same branch already lists that asset with a seq.
local function mergeDeployments(lists: { { any } }, limit: number): { any }
	local byKey = {}
	local merged = {}
	local withSeq = {}
	local pending = {}
	for _, list in lists do
		for _, raw in list do
			local entry = cleanDeployment(raw)
			if not entry then
				continue
			end
			local key = deploymentKey(entry)
			if byKey[key] then
				continue
			end
			byKey[key] = true
			if entry.seq then
				withSeq[`{entry.branch}@{entry.assetId}`] = true
				table.insert(merged, entry)
			else
				table.insert(pending, entry)
			end
		end
	end
	for _, entry in pending do
		if not withSeq[`{entry.branch}@{entry.assetId}`] then
			table.insert(merged, entry)
		end
	end
	table.sort(merged, newestFirst)
	while #merged > limit do
		table.remove(merged)
	end
	return merged
end

local function storedList(value): { any }
	return if typeof(value) == "table" and typeof(value.list) == "table" then value.list else {}
end

-- Re-reads the stored list (yields; at most once per `maxAge` seconds, default 30).
local deploymentsReading = false
function Registry.refreshDeployments(maxAge: number?)
	-- 0.3.2 (boot budget): a read in flight (the boot prefetch) isn't waited for: callers use what is cached.
	if deploymentsReading or os.clock() - deploymentsReadAt < (maxAge or 30) then
		return
	end
	deploymentsReading = true
	local ok, value = pcall(function()
		return getStore():GetAsync("deployments")
	end)
	deploymentsReading = false
	if ok then
		deploymentsReadAt = os.clock()
		-- 0.3.2: merged with what this server heard itself (only the head's winner writes the durable list, and a
		-- message whose head lost to a newer one is never written there).
		storedDeployments = mergeDeployments({ storedList(value), storedDeployments }, Constants.DEPLOYMENTS_KEPT)
	end
end

-- Merges entries into this server's cached copy; returns the clean entries it didn't have.
local function rememberDeployments(entries: { any }): { any }
	local missing = {}
	local listed = {}
	for _, entry in storedDeployments do
		listed[deploymentKey(entry)] = true
	end
	for _, raw in entries do
		local entry = cleanDeployment(raw)
		if entry and not listed[deploymentKey(entry)] then
			table.insert(missing, entry)
		end
	end
	if #missing > 0 then
		storedDeployments = mergeDeployments({ storedDeployments, missing }, Constants.DEPLOYMENTS_KEPT)
	end
	return missing
end

-- Adds entries to the durable list (one UpdateAsync, cancelled when it has them all; retried). Non-blocking.
local function writeDeployments(entries: { any })
	local clean = {}
	for _, raw in entries do
		local entry = cleanDeployment(raw)
		if entry then
			table.insert(clean, entry)
		end
	end
	if #clean == 0 then
		return
	end
	task.spawn(function()
		durably(function()
			getStore():UpdateAsync("deployments", function(existing)
				local list = storedList(existing)
				local have = {}
				for _, entry in list do
					local entryClean = cleanDeployment(entry)
					if entryClean then
						have[deploymentKey(entryClean)] = true
					end
				end
				local added = false
				for _, entry in clean do
					if not have[deploymentKey(entry)] then
						added = true
					end
				end
				if not added then
					return nil -- already there
				end
				return { list = mergeDeployments({ list, clean }, Constants.DEPLOYMENTS_KEPT) }
			end)
		end)
	end)
end

-- Adds entries this server's copy doesn't have yet, locally and (unless `durable` is false) to the durable list.
-- Non-blocking. 0.3.2: deploy messages go through saveHead instead (winner-only); this path is for the heads and
-- history the dev menu lists, which are rare and only written when something is new.
function Registry.recordDeployments(entries: { any }, durable: boolean?)
	local missing = rememberDeployments(entries)
	if #missing > 0 and durable ~= false then
		writeDeployments(missing)
	end
end

-- 0.3.2: the winner of a saveHead writes the deploy's entries whatever this server's copy already has.
function Registry.writeDeploymentsDurably(entries: { any })
	rememberDeployments(entries)
	writeDeployments(entries)
end

-- Every known deployment, newest first: the stored list, then
-- `extra` (this server's own history), at most DEPLOYMENTS_KEPT plus any `keep` entries (branch heads) the cap cut.
-- Plain tables; callers may add fields.
function Registry.deployments(extra: { any }?, keep: { any }?): { any }
	local lists = { storedDeployments, keep or {}, extra or {} }
	local merged = mergeDeployments(lists, Constants.DEPLOYMENTS_KEPT)
	if keep and #keep > 0 then
		local listed = {}
		for _, entry in merged do
			listed[deploymentKey(entry)] = true
		end
		local all = mergeDeployments(lists, math.huge)
		for _, raw in keep do
			local entry = cleanDeployment(raw)
			if entry and not listed[deploymentKey(entry)] then
				-- Use the merged copy (registry fields win over the seed).
				for _, candidate in all do
					if deploymentKey(candidate) == deploymentKey(entry) then
						table.insert(merged, candidate)
						listed[deploymentKey(entry)] = true
						break
					end
				end
			end
		end
		table.sort(merged, newestFirst)
	end
	return merged
end

-- Automatic and server-local rollbacks, pins, refusals: so `typetorch deployments` can show them later (backend phase).
-- 0.3.2: one unique key per event, `events/<yyyy-mm-dd>/<job>/<n>` (SetAsync, no contention between servers and no
-- 4 MB list), like the framework's `mod/` records. `<job>` = the JobId without dashes, first 24 characters ("studio" +
-- the boot time in Studio); `<n>` counts per server. DataStore keys stay under 50 characters. The 0.3.1 `events` list
-- key is left as it is (nothing reads it).
local eventCount = 0
local eventJob: string? = nil
function Registry.logEvent(entry: { [string]: any })
	entry.at = entry.at or DateTime.now():ToIsoDate()
	if not eventJob then
		local jobId = game.JobId
		eventJob = if jobId ~= "" then string.sub(string.gsub(jobId, "-", ""), 1, 24) else `studio{os.time()}`
	end
	eventCount += 1
	local key = `events/{string.sub(entry.at, 1, 10)}/{eventJob}/{eventCount}`
	task.spawn(function()
		pcall(function()
			getStore():SetAsync(key, entry)
		end)
	end)
end

return Registry
