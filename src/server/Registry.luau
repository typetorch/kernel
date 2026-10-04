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
--       head/<branch>              { assetId, artifactId, seq, commit, channel, deployedAt }  (from deploy messages;
--                                  the fallback registry when ConfigService isn't written; higher seq wins)
--       private/<PrivateServerId>  { branch, setBy, setAt }   (private and reserved servers' branch)
--       events                     { list }                   (automatic and server-local rollbacks)
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

local function read()
	if snapshot then
		local ok, value = pcall(function()
			return snapshot:GetValue(CONFIG_KEY)
		end)
		if ok then
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

-- Loads the config (retrying with backoff) and keeps it fresh: UpdateAvailable plus a periodic Refresh as backup.
-- Returns (state, error). In Studio, a TypeTorchDev override wins.
function Registry.start(): (any, string?)
	local override = Registry.studioOverride()
	if override then
		state = override
		return state, nil
	end
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
	if not snapshot then
		state = normalize(nil)
		return state, "ConfigService unavailable"
	end
	state = normalize(read())
	snapshot.UpdateAvailable:Connect(function()
		pcall(function()
			snapshot:Refresh()
		end)
		changed()
	end)
	task.spawn(function()
		while true do
			task.wait(Constants.POLL_SECONDS)
			pcall(function()
				snapshot:Refresh()
			end)
			local value = read()
			if HttpService:JSONEncode(normalize(value)) ~= HttpService:JSONEncode(state) then
				changed()
			end
		end
	end)
	return state, nil
end

function Registry.state()
	return state or normalize(nil)
end

-- fn(newState, oldState) after every change.
function Registry.onChange(fn)
	table.insert(listeners, fn)
end

-- Branch heads persisted by game servers from deploy messages (in-game DataStore, key "head/<branch>"). This keeps the
-- system working when the CLI can't write ConfigService (missing `universe:write` scope): every server that receives a
-- deploy message records the head, so servers started later still boot the right artifact. The head with the higher
-- seq wins between the two sources.
local storedHeads: { [string]: any } = {}

local function getStore(): DataStore
	if not store then
		store = DataStoreService:GetDataStore(Constants.DATASTORE)
	end
	return store :: DataStore
end

function Registry.refreshStoredHead(branch: string)
	local ok, value = pcall(function()
		return getStore():GetAsync("head/" .. branch)
	end)
	if ok and typeof(value) == "table" and typeof(value.assetId) == "number" then
		storedHeads[branch] = value
	end
	return storedHeads[branch]
end

function Registry.saveHead(branch: string, head)
	local current = storedHeads[branch]
	if current and (current.seq or 0) >= (head.seq or 0) then
		return
	end
	storedHeads[branch] = head
	task.spawn(function()
		pcall(function()
			getStore():UpdateAsync("head/" .. branch, function(existing)
				if typeof(existing) == "table" and (existing.seq or 0) >= (head.seq or 0) then
					return nil -- keep the newer one already stored
				end
				return head
			end)
		end)
	end)
end

-- Branch names with a stored head (ListKeysAsync over "head/"). Yields; for the dev menu.
function Registry.storedBranches(): { string }
	local names = {}
	pcall(function()
		local pages = getStore():ListKeysAsync("head/", 50)
		while true do
			for _, key in pages:GetCurrentPage() do
				table.insert(names, string.sub(key.KeyName, 6))
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
	return names
end

function Registry.branchHead(name: string)
	local fromConfig = Registry.state().branches[name]
	local fromStore = storedHeads[name]
	if fromConfig and fromStore then
		return if (fromStore.seq or 0) > (fromConfig.seq or 0) then fromStore else fromConfig
	end
	return fromConfig or fromStore
end

function Registry.channelOf(branch: string): string
	local head = Registry.branchHead(branch)
	local configured = Registry.state().channels[branch]
	return configured or (head and head.channel) or (if branch == Registry.state().defaultBranch then "prod" else "dev")
end

-- In-game DataStore (game-written data) ---------------------------------------------------------------------------

function Registry.privateBranch(privateServerId: string): (string?, string?)
	local ok, value = pcall(function()
		return getStore():GetAsync("private/" .. privateServerId)
	end)
	if not ok then
		return nil, tostring(value)
	end
	return if typeof(value) == "table" and typeof(value.branch) == "string" then value.branch else nil, nil
end

function Registry.setPrivateBranch(privateServerId: string, branch: string, userId: number): (boolean, string?)
	local ok, err = pcall(function()
		getStore():SetAsync("private/" .. privateServerId, {
			branch = branch,
			setBy = userId,
			setAt = DateTime.now():ToIsoDate(),
		})
	end)
	return ok, if ok then nil else tostring(err)
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
