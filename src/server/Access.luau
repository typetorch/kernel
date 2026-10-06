--!nonstrict
-- Who is a dev (plans/10): a Studio session, OR the experience owner, OR a registry member, OR a dev-badge holder,
-- AND not revoked. 0.3.4: two roles, "owner" (the experience creator, the owning group's owner, members with role
-- "owner") and "dev". There are no admins: a member with the old role "admin" is a dev (least privilege), with a warning
-- once per server.
-- Decided on the server only. Roblox has no in-game "edit access" API, so this is TypeTorch's own rule.
--
-- 0.3.2 (audit S-M2): revocation fails closed. Until a settings read has succeeded on this server (Registry.known()),
-- badge holders and members are NOT devs (a badge can't be revoked by the game, so the list is the off switch). Studio
-- and the owner are unaffected (the owner can't be revoked). A later failed or refused read keeps the last good copy
-- (Settings.luau), so revocations never vanish on an error.
-- 0.3.2 (audit P-K9): a failed badge, rank or group web call counts as "no" for ACCESS_FAILURE_CACHE seconds instead of
-- being retried on every check (an outage must not turn every dev check into a web call); successes stay cached.
--
-- 0.3.8 (plans/20): the lists come from the signed settings record's `access` = { members, revoked, devBadgeId }
-- (`typetorch access push`), which the kernel hands over with setConfig on every new good copy. The record is signed
-- with both prod keys, so in-universe code can't add itself as an owner even though it can write the DataStore.
-- (0.3.6-0.3.7 read them from the ConfigService key TypeTorchAccess, before that from the never-written registry.)

local BadgeService = game:GetService("BadgeService")
local RunService = game:GetService("RunService")
local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Access = {}

local config = { members = {}, revoked = {} }
local known = false -- a settings read (and so `revoked`) has succeeded at least once on this server
-- userId -> true/false badge ownership for this server's lifetime (cleared when the badge id changes).
local badgeCache: { [number]: boolean } = {}
-- userId -> owns the experience (user-owned: the creator; group-owned: rank 255 in the group).
local ownerCache: { [number]: boolean } = {}
-- "<kind>:<userId>" -> os.clock() of the last failed web call (P-K9).
local failedAt: { [string]: number } = {}

local function recentlyFailed(key: string): boolean
	local at = failedAt[key]
	return at ~= nil and os.clock() - at < Constants.ACCESS_FAILURE_CACHE
end

local function isOwner(player: Player): boolean
	local cached = ownerCache[player.UserId]
	if cached ~= nil then
		return cached
	end
	local owner = false
	if game.CreatorType == Enum.CreatorType.User then
		owner = player.UserId == game.CreatorId
	else
		local key = `rank:{player.UserId}`
		if recentlyFailed(key) then
			return false
		end
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		if not ok then
			failedAt[key] = os.clock() -- "no" for a while, then retried
			return false
		end
		owner = rank == 255
	end
	ownerCache[player.UserId] = owner
	return owner
end

-- 0.3.4: member roles are "owner" or "dev"; anything else (the old "admin") is "dev", with a warning once per server.
local warnedRoles: { [string]: boolean } = {}
local function normalizedMembers(members)
	local result = {}
	if typeof(members) ~= "table" then
		return result
	end
	for key, role in members do
		if typeof(role) == "string" then
			if role ~= "owner" and role ~= "dev" then
				local warnKey = `{tostring(key)}/{role}`
				if not warnedRoles[warnKey] then
					warnedRoles[warnKey] = true
					warn(`[TypeTorch] member {tostring(key)}: role {role} no longer exists: use owner or dev (treated as dev)`)
				end
				role = "dev"
			end
			result[tostring(key)] = role
		end
	end
	return result
end

-- `revoked` as the CLI writes it ({ ["123"] = true }), or as a list of ids.
local function normalizedRevoked(revoked)
	local result = {}
	if typeof(revoked) ~= "table" then
		return result
	end
	for key, value in revoked do
		if value == true then
			result[tostring(key)] = true
		elseif typeof(key) == "number" and (typeof(value) == "string" or typeof(value) == "number") then
			result[tostring(value)] = true
		end
	end
	return result
end

local listsNote = nil -- the last line printed about the lists, so a change prints once

local function count(map): number
	local n = 0
	for _ in map do
		n += 1
	end
	return n
end

-- `lists` = { members, revoked, devBadgeId } (the settings' `access`, or empty); `isKnown` (0.3.2): a settings read
-- has succeeded on this server (a missing record counts); see S-M2 above.
function Access.setConfig(lists, isKnown: boolean?)
	lists = if typeof(lists) == "table" then lists else {}
	local before = config.devBadgeId
	config = {
		members = normalizedMembers(lists.members),
		revoked = normalizedRevoked(lists.revoked),
		devBadgeId = tonumber(lists.devBadgeId),
	}
	if config.devBadgeId ~= before then
		table.clear(badgeCache)
	end
	known = isKnown == true
	local note = `{count(config.members)} member(s), {count(config.revoked)} revoked{if config.devBadgeId then `, dev badge {config.devBadgeId}` else ""}`
	if known and note ~= listsNote then
		listsNote = note
		print(`[TypeTorch] dev access from the settings: {note}`)
	end
end

-- Whether the revocation list is known (a settings read succeeded).
function Access.revocationsKnown(): boolean
	return known
end

local function hasBadge(userId: number): boolean
	local badgeId = tonumber(config.devBadgeId)
	if not badgeId then
		return false
	end
	local cached = badgeCache[userId]
	if cached ~= nil then
		return cached
	end
	local key = `badge:{userId}`
	if recentlyFailed(key) then
		return false
	end
	local ok, owns = pcall(BadgeService.UserHasBadgeAsync, BadgeService, userId, badgeId)
	if not ok then
		-- A failed web call means "not a dev for now"; it is tried again after ACCESS_FAILURE_CACHE seconds.
		failedAt[key] = os.clock()
		return false
	end
	badgeCache[userId] = owns
	return owns
end

-- Returns (isDev, reason, role). role is "owner" | "dev" | nil (0.3.4: no "admin"). Reasons: "studio", "owner", "member",
-- "badge", "revoked", "none", and (0.3.2) "registry-unknown" (a badge or member check while the revocation list is
-- unknown).
function Access.check(player: Player): (boolean, string, string?)
	local key = tostring(player.UserId)
	if config.revoked[key] then
		return false, "revoked", nil
	end
	if RunService:IsStudio() then
		return true, "studio", "owner"
	end
	if isOwner(player) then
		return true, "owner", "owner"
	end
	if not known then
		return false, "registry-unknown", nil -- S-M2: no badge or member access until revocations are known
	end
	local role = config.members[key]
	if typeof(role) == "string" then
		return true, "member", role
	end
	if hasBadge(player.UserId) then
		return true, "badge", "dev"
	end
	return false, "none", nil
end

function Access.isDev(player: Player): boolean
	local dev = Access.check(player)
	return dev
end

-- 0.3.4: an owner (Studio counts as one): owner-only actions (A/B, public servers, prod rollbacks, kick/ban, ...).
function Access.isOwner(player: Player): boolean
	local dev, _, role = Access.check(player)
	return dev and role == "owner"
end

-- userId -> owns the experience, for users who may not be in this server (group owners: GroupService, cached).
local ownerIdCache: { [number]: boolean } = {}

-- 0.2.3: whether `userId` is an owner, for messages from other servers (pin messages carry `by`). The player is usually
-- elsewhere: members with role "owner", the user-owned creator, or rank 255 in the owning group (a web call, cached; a
-- failure counts as "no" for a while). Revoked users never are.
function Access.isOwnerUserId(userId: number): boolean
	if typeof(userId) ~= "number" or userId <= 0 or userId % 1 ~= 0 then
		return false
	end
	local key = tostring(userId)
	if config.revoked[key] then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	if config.members[key] == "owner" then
		return true
	end
	local player = game:GetService("Players"):GetPlayerByUserId(userId)
	if player then
		return isOwner(player)
	end
	if game.CreatorType == Enum.CreatorType.User then
		return userId == game.CreatorId
	end
	local cached = ownerIdCache[userId]
	if cached ~= nil then
		return cached
	end
	local failKey = `groups:{userId}`
	if recentlyFailed(failKey) then
		return false
	end
	local ok, groups = pcall(game:GetService("GroupService").GetGroupsAsync, game:GetService("GroupService"), userId)
	if not ok or typeof(groups) ~= "table" then
		failedAt[failKey] = os.clock()
		return false
	end
	local owner = false
	for _, group in groups do
		if typeof(group) == "table" and group.Id == game.CreatorId then
			owner = group.Rank == 255
			break
		end
	end
	ownerIdCache[userId] = owner
	return owner
end

-- 0.3: whether `userId` is a dev (owner, member or dev-badge holder, not revoked), for users who may not be in
-- this server. Used at boot to decide whether a player-owned private server may follow its stored (game-written)
-- branch choice. A failed web call counts as "no". 0.3.2: badge holders and members only once revocations are known.
function Access.isDevUserId(userId: number): boolean
	if typeof(userId) ~= "number" or userId <= 0 or userId % 1 ~= 0 then
		return false
	end
	if config.revoked[tostring(userId)] then
		return false
	end
	if Access.isOwnerUserId(userId) then
		return true -- before the registry is known, only the creator or the group owner can be one
	end
	if not known then
		return false
	end
	if typeof(config.members[tostring(userId)]) == "string" then
		return true
	end
	return hasBadge(userId)
end

return Access
