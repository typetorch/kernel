--!nonstrict
-- Where the kernel learns which artifact a branch runs.
--
-- Interim registry (plans/05: the backend replaces it):
--   * ConfigService key "TypeTorch" (repository InExperienceConfig), written by the CLI through the Open Cloud configs
--     API (draft -> publish). Server-only (clients can't read configs) and pushed to live servers
--     (ConfigSnapshot.UpdateAvailable). One key, because a repository holds at most 100 keys and the game shares it:
--       { v, defaultBranch, channels = { [branch] = "prod"|"dev" }, members = { [userId] = role },
--         revoked = { [userId] = true }, devBadgeId?,
--         branches = { [name] = { artifactId, assetId, channel, commit, commitHash, seq, deployedAt, by } },
--         deployments = { newest last, at most 25 } }
--   * In-game DataStore "TypeTorch" for what game servers write themselves (no Open Cloud scope needed):
--       heads                      { [branch] = { assetId, artifactId, seq, commit, channel, deployedAt, rollout?, t?,
--                                  rollback?, sig?, sigF? } } (from deploy messages; the fallback registry when
--                                  ConfigService isn't written; higher seq wins, but a signed prod head (0.3) is never
--                                  replaced by an unsigned one; mirrored in MemoryStore HashMap "TypeTorch" for
--                                  polling; see "Branch heads" below). Game code can write these stores, so prod
--                                  servers (0.3) only follow heads whose signatures check out (Signing.luau).
--       private/<PrivateServerId>  { branch, setBy, setAt, pin?, code? } (private and reserved servers' branch; `pin` =
--                                  { assetId, artifactId, seq, commit, channel, branch, headSeq } boots that artifact
--                                  until the branch gets a deploy newer than headSeq; `code` (0.3.2) = a reserved
--                                  server's access code, kept by every later write)
--       deployments                { list }                   (newest first, at most 100: { seq, branch, channel,
--                                  artifactId, assetId, commit, at, rollback?, rollout?, t?, sig?, sigF? } from deploy
--                                  messages and known heads; rollout = the deploy's `ro` %, 0.2.3; t/sig/sigF 0.3;
--                                  0.3.2: written by the server that won the head's MemoryStore update only)
--       events/<date>/<job>/<n>    { action, at, ... }        (0.3.2: one key per event, SetAsync: automatic and
--                                  server-local rollbacks, health rollbacks, pins, refusals; the 0.3.1 `events` list
--                                  key is no longer written)
--
-- Studio without published configs: ServerStorage.TypeTorchDev may carry a "Registry" JSON attribute (same shape) or a
-- "BootAssetId" number attribute; see Registry.studioOverride. 0.3.1: a "Payload" Model child is mounted instead of any
-- registry head (the kernel's "Studio local payload"; this module doesn't read it).

local ConfigService = game:GetService("ConfigService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local CONFIG_KEY = "TypeTorch"

local Registry = {}

local snapshot = nil
local state = nil
local listeners = {}
local store: DataStore? = nil

local function normalize(value)
	value = if typeof(value) == "table" then value else {}
	value.v = value.v or 1
	value.defaultBranch = value.defaultBranch or "prod"
	value.channels = value.channels or {}
	value.members = value.members or {}
	value.revoked = value.revoked or {}
	value.branches = value.branches or {}
	value.deployments = value.deployments or {}
	return value
end

-- Studio fallback for places whose configs aren't readable in Studio.
function Registry.studioOverride()
	if not RunService:IsStudio() then
		return nil
	end
	local dev = ServerStorage:FindFirstChild("TypeTorchDev")
	if not dev then
		return nil
	end
	local json = dev:GetAttribute("Registry")
	if typeof(json) == "string" and json ~= "" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
		if ok then
			return normalize(decoded)
		end
	end
	local assetId = dev:GetAttribute("BootAssetId")
	if typeof(assetId) == "number" then
		local branch = dev:GetAttribute("Branch") or "dev"
		return normalize({
			defaultBranch = branch,
			channels = { [branch] = dev:GetAttribute("Channel") or "dev" },
			branches = { [branch] = { assetId = assetId, artifactId = dev:GetAttribute("ArtifactId"), seq = 0 } },
		})
	end
	return nil
end

-- The engine warns 'Config value not found for key "TypeTorch"' on every GetValue of a missing key, which floods the
-- dev Logs tab. So once the key is missing, it is only read again after a publish (UpdateAvailable, or the key's own
-- changed signal), never from the periodic refresh.
local keyMissing = false
-- 0.3.2 (audit S-M2): whether a registry read has ever succeeded (a missing key counts: no registry, nothing revoked).
-- Until then `revoked` is unknown and Access denies badge devs. A failed read later keeps the last good registry.
local known = false
local lastReadError: string? = nil

-- (ok, value): ok = false when the read itself failed (keep what we have); value = nil when the key is missing.
local function read(): (boolean, any)
	if not snapshot then
		return false, nil
	end
	if keyMissing then
		return true, nil
	end
	local ok, value = pcall(function()
		return snapshot:GetValue(CONFIG_KEY)
	end)
	if not ok then
		lastReadError = tostring(value)
		return false, nil
	end
	keyMissing = value == nil
	return true, value
end

-- Re-reads the registry; a failed read keeps the last good state (S-M2: a read error never empties `revoked`).
local function changed()
	local ok, value = read()
	if not ok then
		return
	end
	known = true
	lastReadError = nil
	local newState = normalize(value)
	local before = state
	state = newState
	for _, listener in listeners do
		task.spawn(listener, newState, before)
	end
end

local function watch()
	snapshot.UpdateAvailable:Connect(function()
		pcall(function()
			snapshot:Refresh()
		end)
		keyMissing = false -- a publish may have added the key
		changed()
	end)
	-- Also covers a key added by a Refresh from the sync loop (if the engine has the per-key signal).
	pcall(function()
		snapshot:GetValueChangedSignal(CONFIG_KEY):Connect(function()
			keyMissing = false
			changed()
		end)
	end)
end

-- One GetConfigAsync attempt; on success the snapshot is watched and its value read (listeners fire).
local function connect(): (boolean, string?)
	local ok, result = pcall(ConfigService.GetConfigAsync, ConfigService)
	if not ok then
		lastReadError = tostring(result)
		return false, tostring(result)
	end
	snapshot = result
	watch()
	changed()
	return true, nil
end

-- Loads the config and keeps it fresh: UpdateAvailable, plus the sync loop's Refresh (Registry.startSync). Returns
-- (state, error). In Studio, a TypeTorchDev override wins.
-- 0.3 (audit P-K5): ConfigService is off the boot path. The first retries (with backoff, about 60 s) run on their own
-- thread; boot waits at most `bootWait` seconds for the first snapshot and continues with an empty registry (the
-- stored heads still work). A snapshot that arrives later fires the onChange listeners like any update. 0.3.2: after
-- those retries the sync loop keeps trying once per tick (S-M2: "retry the boot read").
function Registry.start(bootWait: number?): (any, string?)
	local override = Registry.studioOverride()
	if override then
		state = override
		known = true
		return state, nil
	end
	state = normalize(nil)
	local finished = false
	task.spawn(function()
		local delay = 1
		for attempt = 1, 6 do
			local ok, connectError = connect()
			if ok then
				break
			end
			warn(`[TypeTorch] ConfigService unavailable (attempt {attempt}): {connectError}`)
			task.wait(delay)
			delay = math.min(delay * 2, 30)
		end
		finished = true
	end)
	local deadline = os.clock() + (bootWait or 3)
	while not finished and not snapshot and os.clock() < deadline do
		task.wait(0.05)
	end
	if not snapshot then
		return state, if finished then "ConfigService unavailable" else "ConfigService slow (still retrying)"
	end
	return state, nil
end

-- 0.3.2 (S-M2): a registry read has succeeded at least once, so `revoked` (and `members`) are known.
function Registry.known(): boolean
	return known
end

-- 0.3.2: the last registry read error since the last success, or nil.
function Registry.readError(): string?
	return lastReadError
end

-- 0.3.2 (audit: one sync loop owner): THE periodic loop of the kernel. Every `interval` seconds it refreshes
-- ConfigService (or retries connecting to it), then calls `onTick` (the kernel re-reads the stored head and follows
-- it). Errors in a tick are logged and don't end the loop. Call once.
local syncStarted = false
function Registry.startSync(interval: number, onTick: () -> ())
	assert(not syncStarted, "Registry.startSync runs once")
	syncStarted = true
	task.spawn(function()
		while true do
			task.wait(interval)
			if Registry.studioOverride() == nil then
				if snapshot then
					pcall(function()
						snapshot:Refresh()
					end)
					if not keyMissing then
						local ok, value = read()
						if ok and (not known or HttpService:JSONEncode(normalize(value)) ~= HttpService:JSONEncode(state)) then
							changed()
						end
					end
				else
					connect()
				end
			end
			local ok, tickError = pcall(onTick)
			if not ok then
				warn(`[TypeTorch] sync tick failed: {tickError}`)
			end
		end
	end)
end

function Registry.state()
	return state or normalize(nil)
end

-- fn(newState, oldState) after every change.
function Registry.onChange(fn)
	table.insert(listeners, fn)
end

-- Branch heads persisted by game servers from deploy messages. This keeps the system working when the CLI can't write
-- ConfigService (missing `universe:write` scope): every server that receives a deploy message records the head, so
-- servers started later still boot the right artifact. The head with the higher seq wins between the sources.
--
-- All heads live in ONE key, { [branch] = head }, so a read is one request and listing branches needs no ListKeysAsync
-- (its budget is a few calls per minute per server; the dev menu used to hit it on every Branch tab load):
--   * MemoryStore HashMap "TypeTorch", key "heads": the fast copy every server polls (universe-wide quota, cheap);
--   * DataStore "TypeTorch", key "heads": the durable copy (MemoryStore entries expire), read when MemoryStore has
--     nothing or fails. Kernel 0.2.0's per-branch "head/<branch>" keys are read once at boot as a migration fallback.
-- Writes: the server whose MemoryStore update wins (seq newer than what's stored) also writes the DataStore copy, so a
-- deploy costs one durable write however many servers hear the message.
local storedHeads: { [string]: any } = {}
local headsReadAt = -math.huge
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

-- Re-reads all heads (yields): MemoryStore, else DataStore. At most once per `maxAge` seconds (default 15).
function Registry.refreshHeads(maxAge: number?)
	if os.clock() - headsReadAt < (maxAge or 15) then
		return
	end
	headsReadAt = os.clock()
	local ok, value = pcall(function()
		return getMemory():GetAsync(HEADS_KEY)
	end)
	if ok and typeof(value) == "table" then
		local durableToo = needsDurable(value)
		mergeHeads(storedHeads, value)
		if not durableToo then
			return
		end
	end
	local durableOk, durable = pcall(function()
		return getStore():GetAsync(HEADS_KEY)
	end)
	if durableOk then
		mergeHeads(storedHeads, durable)
	end
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
	storedHeads[branch] = head
	task.spawn(function()
		local won = false
		local memoryOk = pcall(function()
			getMemory():UpdateAsync(HEADS_KEY, function(existing)
				local heads = if typeof(existing) == "table" then existing else {}
				local stored = heads[branch]
				if not replaces(stored, head, branch) then
					won = false
					return nil -- another server already stored this deploy (or a newer one)
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
				if not replaces(stored, head, branch) then
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

-- The branch's head: the newer of the ConfigService head and the stored head. 0.3: with `accept`, only heads it
-- accepts count (prod servers pass a check for signed prod heads).
function Registry.branchHead(name: string, accept: ((any) -> boolean)?)
	local fromConfig = Registry.state().branches[name]
	local fromStore = storedHeads[name]
	if accept then
		if fromConfig and not (isHead(fromConfig) and accept(fromConfig)) then
			fromConfig = nil
		end
		if fromStore and not (isHead(fromStore) and accept(fromStore)) then
			fromStore = nil
		end
	end
	if fromConfig and fromStore then
		local storeSeq, configSeq = fromStore.seq or 0, fromConfig.seq or 0
		-- 0.2.3: the same deploy from a message carries its rollout %; a config head without one would undo it.
		local sameWithRollout = storeSeq == configSeq and fromStore.assetId == fromConfig.assetId and fromStore.rollout ~= nil and fromConfig.rollout == nil
		return if storeSeq > configSeq or sameWithRollout then fromStore else fromConfig
	end
	return fromConfig or fromStore
end

-- 0.3 boot fail-safe: every head this server can find for `branch` (ConfigService, the cached copy, and fresh reads of
-- the MemoryStore and DataStore copies), distinct by asset and seq, newest seq first. Yields. Untrusted: the kernel
-- checks each one.
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
	add(Registry.state().branches[branch])
	add(storedHeads[branch])
	local memoryOk, memory = pcall(function()
		return getMemory():GetAsync(HEADS_KEY)
	end)
	if memoryOk and typeof(memory) == "table" then
		add(memory[branch])
	end
	local durableOk, durable = pcall(function()
		return getStore():GetAsync(HEADS_KEY)
	end)
	if durableOk and typeof(durable) == "table" then
		add(durable[branch])
	end
	table.sort(list, function(a, b)
		local seqA, seqB = if typeof(a.seq) == "number" then a.seq else -1, if typeof(b.seq) == "number" then b.seq else -1
		return seqA > seqB
	end)
	return list
end

-- 0.3: both candidate heads of a branch (ConfigService, stored), either may be nil.
function Registry.headCandidates(name: string): (any?, any?)
	local fromConfig = Registry.state().branches[name]
	local fromStore = storedHeads[name]
	return if isHead(fromConfig) then fromConfig else nil, if isHead(fromStore) then fromStore else nil
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

-- Deployment history (in-game DataStore key "deployments", merged with ConfigService `deployments`) -----------------
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
function Registry.refreshDeployments(maxAge: number?)
	if os.clock() - deploymentsReadAt < (maxAge or 30) then
		return
	end
	local ok, value = pcall(function()
		return getStore():GetAsync("deployments")
	end)
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

-- Every known deployment, newest first: ConfigService `deployments` (when readable), then the stored list, then
-- `extra` (this server's own history), at most DEPLOYMENTS_KEPT plus any `keep` entries (branch heads) the cap cut.
-- Plain tables; callers may add fields.
function Registry.deployments(extra: { any }?, keep: { any }?): { any }
	local lists = { Registry.state().deployments, storedDeployments, keep or {}, extra or {} }
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
