--!nonstrict
-- Access.luau under Lune (`lune run scripts/test-access.luau` from kernel/): 0.3.8 takes the lists from the signed
-- settings' `access` through setConfig (the kernel calls it on every new good copy): members and roles, revocations,
-- the badge and its cache (cleared when the badge id changes), the old role "admin" (a dev), S-M2 (no member or badge
-- access until a settings read succeeded), revoked lists given as arrays, and Studio.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local passed, failed = 0, 0
local function check(name: string, ok: boolean, detail: any?)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}{if detail ~= nil then `  ({tostring(detail)})` else ""}`)
	end
end

local clock = 1000
local output = {}
local isStudio = false
local badgeCalls = 0
local badges = {} -- userId -> owns
local parentFolder = {
	FindFirstChild = function(_, name)
		return if name == "Registry" then "RegistryModule" else nil
	end,
}
local game = {
	CreatorType = "User",
	CreatorId = 1,
	GetService = function(_, name)
		if name == "BadgeService" then
			return {
				UserHasBadgeAsync = function(_, userId, badgeId)
					badgeCalls += 1
					return badges[userId] == badgeId
				end,
			}
		elseif name == "RunService" then
			return { IsStudio = function()
				return isStudio
			end }
		elseif name == "ReplicatedStorage" then
			return {
				WaitForChild = function()
					return { WaitForChild = function()
						return "Constants"
					end }
				end,
			}
		elseif name == "HttpService" then
			return { JSONDecode = function(_, text)
				return require("@lune/serde").decode("json", text)
			end }
		elseif name == "Players" then
			return { GetPlayerByUserId = function()
				return nil
			end }
		end
		error(`unexpected service {name}`)
	end,
}
local Enum = { CreatorType = { User = "User", Group = "Group" } }
local env = setmetatable({
	game = game,
	script = { Parent = parentFolder },
	require = function(target)
		if target == "Constants" then
			return { ACCESS_FAILURE_CACHE = 30 }
		end
		error(`unexpected require {tostring(target)}`)
	end,
	typeof = function(value)
		return type(value)
	end,
	Enum = Enum,
	os = { clock = function()
		return clock
	end, time = os.time },
	print = function(...)
		table.insert(output, table.concat({ ... }, " "))
	end,
	warn = function(...)
		table.insert(output, "warn: " .. table.concat({ ... }, " "))
	end,
}, { __index = getfenv(0) })
local Access = luau.load(fs.readFile("src/server/Access.luau"), { debugName = "Access.luau", environment = env })()

local function player(userId: number)
	return { UserId = userId, Name = `P{userId}` }
end
local function said(fragment: string): boolean
	for _, line in output do
		if string.find(line, fragment, 1, true) then
			return true
		end
	end
	return false
end

-- 1. Before any settings read: S-M2, only the creator (and Studio) count.
Access.setConfig({ members = { ["2"] = "dev" }, revoked = {} }, false)
check("unknown: a member isn't a dev until a settings read succeeded", select(2, Access.check(player(2))) == "registry-unknown")
check("unknown: the creator is an owner", Access.isOwner(player(1)) == true)
check("unknown: isDevUserId refuses members", Access.isDevUserId(2) == false and Access.revocationsKnown() == false)

-- 2. The settings' lists.
Access.setConfig({ members = { ["2"] = "dev", ["4"] = "owner" }, revoked = { ["9"] = true }, devBadgeId = 500 }, true)
check("settings: member dev", Access.check(player(2)) == true and select(3, Access.check(player(2))) == "dev")
check("settings: member owner", Access.isOwner(player(4)) == true and Access.isOwnerUserId(4) == true)
check("settings: revoked", select(2, Access.check(player(9))) == "revoked")
check("settings: stranger (one badge lookup)", select(2, Access.check(player(3))) == "none" and badgeCalls == 1, badgeCalls)
check("settings: the creator is an owner", Access.isOwner(player(1)) == true)
check("settings: printed once", said("dev access from the settings: 2 member(s), 1 revoked, dev badge 500"))
badges[7] = 500
check("settings: badge holder is a dev", select(2, Access.check(player(7))) == "badge" and badgeCalls == 2, badgeCalls)
check("badge: cached (no second web call)", Access.isDev(player(7)) and badgeCalls == 2, badgeCalls)

-- 3. A new copy replaces the lists: member 2 is out, 3 is in, 9 is no longer revoked, 4 is revoked now; the badge id
--    changed, so the badge cache is cleared and badge 500 no longer counts.
Access.setConfig({ members = { ["3"] = "owner", ["5"] = "dev" }, revoked = { ["4"] = true }, devBadgeId = 600 }, true)
local dev3, reason3, role3 = Access.check(player(3))
check("new copy: new owner member", dev3 == true and reason3 == "member" and role3 == "owner")
check("new copy: new dev member", select(3, Access.check(player(5))) == "dev")
check("new copy: the old member is no longer a dev", select(2, Access.check(player(2))) == "none")
check("new copy: the old owner is revoked now", select(2, Access.check(player(4))) == "revoked" and Access.isOwnerUserId(4) == false)
check("new copy: the old revocation is gone", select(2, Access.check(player(9))) == "none")
local beforeBadge = badgeCalls
check("new copy: badge id changed, cache cleared, badge 500 holder re-checked (badge 600) and refused", select(2, Access.check(player(7))) == "none" and badgeCalls == beforeBadge + 1, badgeCalls - beforeBadge)
check("new copy: the creator is still an owner", Access.isOwner(player(1)) == true)
check("isDevUserId: member", Access.isDevUserId(5) == true and Access.isDevUserId(2) == false)

-- 4. The old role "admin" is a dev (warned once); revoked as an array of ids; no badge id: no badge lookups.
Access.setConfig({ members = { ["8"] = "admin" }, revoked = { "2", 3 } }, true)
check("admin: a dev, not an owner", select(3, Access.check(player(8))) == "dev" and Access.isOwner(player(8)) == false and said("role admin no longer exists"))
check("revoked as a list of ids", select(2, Access.check(player(2))) == "revoked" and select(2, Access.check(player(3))) == "revoked")
beforeBadge = badgeCalls
check("no badge id: no badge lookups", Access.isDev(player(7)) == false and badgeCalls == beforeBadge, badgeCalls - beforeBadge)

-- 5. A missing record (empty lists, known): only the creator.
Access.setConfig({}, true)
check("no access field: only the creator", Access.isOwner(player(1)) == true and select(2, Access.check(player(8))) == "none" and Access.revocationsKnown() == true)

-- 6. Studio: everyone is an owner, revoked still refused.
isStudio = true
Access.setConfig({ members = {}, revoked = { ["11"] = true } }, true)
check("studio: owner", Access.check(player(12)) == true and select(2, Access.check(player(12))) == "studio")
check("studio: revoked still refused", select(2, Access.check(player(11))) == "revoked")

print(`access: {passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
