--!nonstrict
-- Who is a dev (plans/10): a Studio session, OR the experience owner, OR a registry member, OR a dev-badge holder,
-- AND not revoked.
-- Decided on the server only. Roblox has no in-game "edit access" API, so this is TypeTorch's own rule.

local BadgeService = game:GetService("BadgeService")
local RunService = game:GetService("RunService")

local Access = {}

local config = { members = {}, revoked = {} }
-- userId -> true/false badge ownership for this server's lifetime (cleared when the badge id changes).
local badgeCache: { [number]: boolean } = {}
-- userId -> owns the experience (user-owned: the creator; group-owned: rank 255 in the group).
local ownerCache: { [number]: boolean } = {}

local function isOwner(player: Player): boolean
	local cached = ownerCache[player.UserId]
	if cached ~= nil then
		return cached
	end
	local owner = false
	if game.CreatorType == Enum.CreatorType.User then
		owner = player.UserId == game.CreatorId
	else
		local ok, rank = pcall(player.GetRankInGroup, player, game.CreatorId)
		if not ok then
			return false -- retried on the next check
		end
		owner = rank == 255
	end
	ownerCache[player.UserId] = owner
	return owner
end

function Access.setConfig(newConfig)
	if newConfig.devBadgeId ~= config.devBadgeId then
		table.clear(badgeCache)
	end
	config = newConfig
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
	local ok, owns = pcall(BadgeService.UserHasBadgeAsync, BadgeService, userId, badgeId)
	if not ok then
		-- A failed web call means "not a dev for now"; it is retried on the next check.
		return false
	end
	badgeCache[userId] = owns
	return owns
end

-- Returns (isDev, reason, role). role is "owner" | "admin" | "dev" | nil.
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

function Access.isAdmin(player: Player): boolean
	local dev, _, role = Access.check(player)
	return dev and (role == "owner" or role == "admin")
end

return Access
