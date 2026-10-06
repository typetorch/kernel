--!nonstrict
-- Access.luau under Lune (`lune run scripts/test-access.luau` from kernel/): the registry lists, and the ConfigService
-- key TypeTorchAccess (0.3.6, `typetorch access push`) replacing them: present, absent, bad, a JSON string, unavailable
-- (the last lists stay), the refresh interval, and the badge cache clearing when the badge id changes.
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

-- A fake Registry sibling: readKey answers (found, value) from `keys`; `down` = ConfigService unavailable.
local keys = {}
local down = false
local reads = 0
local fakeRegistry = {
	readKey = function(key)
		reads += 1
		if down then
			return false, nil
		end
		return true, keys[key]
	end,
}

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
		elseif target == "RegistryModule" then
			return fakeRegistry
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

-- 1. The registry's lists (no key).
Access.setConfig({ members = { ["2"] = "dev", ["4"] = "owner" }, revoked = { ["9"] = true }, devBadgeId = 500 }, true)
check("registry: member dev", Access.check(player(2)) == true and select(3, Access.check(player(2))) == "dev")
check("registry: member owner", Access.isOwner(player(4)) == true)
check("registry: revoked", select(2, Access.check(player(9))) == "revoked")
check("registry: stranger (one badge lookup)", select(2, Access.check(player(3))) == "none" and badgeCalls == 1, badgeCalls)
check("registry: the creator is an owner", Access.isOwner(player(1)) == true)
check("source: registry", Access.source() == "registry")
check("the key was read once with setConfig", reads == 1, reads)
badges[7] = 500
check("registry: badge holder is a dev", select(2, Access.check(player(7))) == "badge" and badgeCalls == 2, badgeCalls)
check("badge: cached (no second web call)", Access.isDev(player(7)) and badgeCalls == 2, badgeCalls)

-- 2. The key appears: its lists replace the registry's (member 2 is out, 3 is in, 9 is no longer revoked, 4 is revoked
--    now; the badge id changed, so the badge cache is cleared and badge 500 no longer counts).
keys.TypeTorchAccess = { v = 1, members = { ["3"] = "owner", ["5"] = "dev" }, revoked = { ["4"] = true }, devBadgeId = 600 }
clock += 61
local dev3, reason3, role3 = Access.check(player(3))
check("key: new owner member", dev3 == true and reason3 == "member" and role3 == "owner")
check("key: new dev member", select(3, Access.check(player(5))) == "dev")
check("key: registry member no longer a dev", select(2, Access.check(player(2))) == "none")
check("key: registry owner now revoked", select(2, Access.check(player(4))) == "revoked" and Access.isOwnerUserId(4) == false)
check("key: registry revocation gone", select(2, Access.check(player(9))) == "none")
local beforeBadge = badgeCalls
check("key: badge id changed, cache cleared, badge 500 holder re-checked (badge 600) and refused", select(2, Access.check(player(7))) == "none" and badgeCalls == beforeBadge + 1, badgeCalls - beforeBadge)
check("key: the creator is still an owner", Access.isOwner(player(1)) == true)
check("source: config-key", Access.source() == "config-key")
check("key: printed once", said("dev access from ConfigService TypeTorchAccess: 2 member(s), 1 revoked, dev badge 600"))
check("isDevUserId: key member", Access.isDevUserId(5) == true and Access.isDevUserId(2) == false)
check("isOwnerUserId: key owner member", Access.isOwnerUserId(3) == true)

-- 3. Not re-read before the interval; re-read after it.
local before = reads
keys.TypeTorchAccess = { v = 1, members = { ["3"] = "owner" }, revoked = {}, devBadgeId = 600 }
Access.check(player(5))
check("refresh: within 60 s the key isn't read again", reads == before and Access.isDev(player(5)) == true, reads - before)
clock += 61
check("refresh: after 60 s the change applies", Access.isDev(player(5)) == false and reads == before + 1, reads - before)

-- 4. ConfigService unavailable: the last lists stay (S-M2).
down = true
clock += 61
check("unavailable: last lists kept", Access.isOwner(player(3)) == true and Access.source() == "config-key")
down = false

-- 5. A JSON string value works; a bad value is ignored with one warning (the registry's lists come back).
keys.TypeTorchAccess = '{"v":1,"members":{"8":"dev"},"revoked":["2"],"devBadgeId":null}'
clock += 61
check("json string: parsed", select(2, Access.check(player(8))) == "member" and select(2, Access.check(player(2))) == "revoked" and Access.check(player(3)) == false)
beforeBadge = badgeCalls
check("json string: no badge id, so no badge lookups", Access.isDev(player(7)) == false and badgeCalls == beforeBadge, badgeCalls - beforeBadge)
keys.TypeTorchAccess = { nope = true }
clock += 61
check("bad value: ignored, registry lists back", Access.isOwner(player(4)) == true and select(2, Access.check(player(2))) == "member" and Access.source() == "registry")
check("bad value: warned once", said("warn: [TypeTorch] ConfigService key TypeTorchAccess ignored"))
local warnings = 0
for _, line in output do
	if string.find(line, "ignored: not a", 1, true) then
		warnings += 1
	end
end
clock += 61
Access.check(player(2))
check("bad value: no repeat warning", warnings == 1, warnings)

-- 6. The key removed: back to the registry, said once.
keys.TypeTorchAccess = { v = 1, members = { ["3"] = "owner" }, revoked = {}, devBadgeId = nil }
clock += 61
Access.check(player(3))
keys.TypeTorchAccess = nil
clock += 61
check("removed: registry lists", Access.isOwner(player(3)) == false and Access.isOwner(player(4)) == true and said("is gone: dev access from the registry again"))

-- 7. setConfig after the key exists keeps the key's lists (the registry changing doesn't override the key).
keys.TypeTorchAccess = { v = 1, members = { ["6"] = "owner" }, revoked = {}, devBadgeId = nil }
Access.setConfig({ members = { ["2"] = "dev" }, revoked = {} }, true)
check("setConfig: key still wins", Access.isOwner(player(6)) == true and Access.isDev(player(2)) == false)
check("refresh(): forces a read", (function()
	local n = reads
	Access.refresh()
	return reads == n + 1
end)())

-- 8. Studio: everyone is an owner, revoked still refused.
isStudio = true
keys.TypeTorchAccess = { v = 1, members = {}, revoked = { ["11"] = true }, devBadgeId = nil }
Access.refresh()
check("studio: owner", Access.check(player(12)) == true and select(2, Access.check(player(12))) == "studio")
check("studio: revoked still refused", select(2, Access.check(player(11))) == "revoked")

print(`access: {passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
