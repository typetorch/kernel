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
--       private/<PrivateServerId>  { branch, setBy, setAt, pin? }   (private and reserved servers' branch; `pin` =
--                                  { assetId, artifactId, seq, commit, channel, branch, headSeq } boots that artifact
--                                  until the branch gets a deploy newer than headSeq)
--       deployments                { list }                   (newest first, at most 100: { seq, branch, channel,
--                                  artifactId, assetId, commit, at, rollback?, rollout?, t?, sig?, sigF? } from deploy
--                                  messages and known heads; rollout = the deploy's `ro` %, 0.2.3; t/sig/sigF 0.3)
--       events                     { list }                   (automatic and server-local rollbacks, pins)
--
-- Studio without published configs: ServerStorage.TypeTorchDev may carry a "Registry" JSON attribute (same shape) or a
-- "BootAssetId" number attribute; see Registry.studioOverride.

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

local function read()
	if snapshot and not keyMissing then
		local ok, value = pcall(function()
			return snapshot:GetValue(CONFIG_KEY)
		end)
		if ok then
			keyMissing = value == nil
			return value
		end
	end
	return nil
end

local function changed()
	local newState = normalize(read())
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
	-- Also covers a key added by a Refresh from the loop below (if the engine has the per-key signal).
	pcall(function()
		snapshot:GetValueChangedSignal(CONFIG_KEY):Connect(function()
			keyMissing = false
			changed()
		end)
	end)
	task.spawn(function()
		while true do
			task.wait(Constants.POLL_SECONDS)
			pcall(function()
				snapshot:Refresh()
			end)
			if not keyMissing then
				local value = read()
				if HttpService:JSONEncode(normalize(value)) ~= HttpService:JSONEncode(state) then
					changed()
				end
			end
		end
	end)
end

-- Loads the config and keeps it fresh: UpdateAvailable plus a periodic Refresh as backup. Returns (state, error). In
-- Studio, a TypeTorchDev override wins.
-- 0.3 (audit P-K5): ConfigService is off the boot path. The retries (with backoff, up to about 30 s) run on their own
-- thread; boot waits at most `bootWait` seconds for the first snapshot and continues with an empty registry (the
-- stored heads still work). A snapshot that arrives later fires the onChange listeners like any update.
function Registry.start(bootWait: number?): (any, string?)
	local override = Registry.studioOverride()
	if override then
		state = override
		return state, nil
	end
	state = normalize(nil)
	local finished = false
	task.spawn(function()
		local delay = 1
		for attempt = 1, 6 do
			local ok, result = pcall(ConfigService.GetConfigAsync, ConfigService)
			if ok then
				snapshot = result
				break
			end
			warn(`[TypeTorch] ConfigService unavailable (attempt {attempt}): {result}`)
			task.wait(delay)
			delay = math.min(delay * 2, 30)
		end
		finished = true
		if not snapshot then
			return
		end
		local value = read()
		watch()
		if value ~= nil then
			changed() -- also when boot already gave up waiting: listeners get the late snapshot
		end
	end)
	local deadline = os.clock() + (bootWait or 3)
	while not finished and os.clock() < deadline do
		task.wait(0.05)
	end
	if not snapshot then
		return state, if finished then "ConfigService unavailable" else "ConfigService slow (still retrying)"
	end
	return state, nil
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

-- Kernel 0.2.0 stored one key per branch; read this branch's old key once (boot only).
function Registry.migrateLegacyHead(branch: string)
	if storedHeads[branch] then
		return
	end
	local ok, value = pcall(function()
		return getStore():GetAsync("head/" .. branch)
	end)
	if ok and isHead(value) then
		storedHeads[branch] = value
	end
end

-- The stored head of `branch`, refreshed when older than `maxAge` seconds (default 15). Yields when it refreshes.
function Registry.refreshStoredHead(branch: string, maxAge: number?)
	Registry.refreshHeads(maxAge)
	return storedHeads[branch]
end

function Registry.saveHead(branch: string, head)
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
		-- Lost the race: the winner writes the durable copy. MemoryStore down: write it ourselves.
		if memoryOk and not won then
			return
		end
		pcall(function()
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

-- A private or reserved server's stored choice: { branch, setBy, setAt, pin? } or nil.
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
	return value, nil
end

function Registry.privateBranch(privateServerId: string): (string?, string?)
	local value, err = Registry.privateOverride(privateServerId)
	return if value then value.branch else nil, err
end

-- `pin` (optional) makes the server boot that artifact instead of the branch head; see the header.
function Registry.setPrivateBranch(privateServerId: string, branch: string, userId: number, pin: any?): (boolean, string?)
	local ok, err = pcall(function()
		getStore():SetAsync("private/" .. privateServerId, {
			branch = branch,
			setBy = userId,
			setAt = DateTime.now():ToIsoDate(),
			pin = pin,
		})
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
		storedDeployments = mergeDeployments({ storedList(value) }, Constants.DEPLOYMENTS_KEPT)
	end
end

-- Adds entries the stored list doesn't have yet (one UpdateAsync, cancelled when nothing is new). Non-blocking.
function Registry.recordDeployments(entries: { any })
	local missing = {}
	local known = {}
	for _, entry in storedDeployments do
		known[deploymentKey(entry)] = true
	end
	for _, raw in entries do
		local entry = cleanDeployment(raw)
		if entry and not known[deploymentKey(entry)] then
			table.insert(missing, entry)
		end
	end
	if #missing == 0 then
		return
	end
	storedDeployments = mergeDeployments({ storedDeployments, missing }, Constants.DEPLOYMENTS_KEPT)
	task.spawn(function()
		pcall(function()
			getStore():UpdateAsync("deployments", function(existing)
				local list = storedList(existing)
				local have = {}
				for _, entry in list do
					local clean = cleanDeployment(entry)
					if clean then
						have[deploymentKey(clean)] = true
					end
				end
				local added = false
				for _, entry in missing do
					if not have[deploymentKey(entry)] then
						added = true
					end
				end
				if not added then
					return nil -- another server already wrote them
				end
				return { list = mergeDeployments({ list, missing }, Constants.DEPLOYMENTS_KEPT) }
			end)
		end)
	end)
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

-- Automatic and server-local rollbacks, so `typetorch deployments` can show them later (backend phase).
function Registry.logEvent(entry: { [string]: any })
	task.spawn(function()
		pcall(function()
			getStore():UpdateAsync("events", function(current)
				local list = if typeof(current) == "table" and typeof(current.list) == "table" then current.list else {}
				entry.at = entry.at or DateTime.now():ToIsoDate()
				table.insert(list, entry)
				while #list > 200 do
					table.remove(list, 1)
				end
				return { list = list }
			end)
		end)
	end)
end

return Registry
