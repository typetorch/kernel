--!nocheck
-- The kernel drain (src/server/Drain.luau; 0.4.1, plans/22): `lune run scripts/test-drain.luau`. The signed messages in
-- scripts/loader-vectors.json are made with the PUBLIC test keys (scripts/test-signing.luau) and checked with the real
-- Signing.luau (fallback key only: the key asset hasn't loaded, so sigF counts).
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Drain = require("../src/server/Drain")
local Signing = require("../src/server/Signing")
local VECTORS = serde.decode("json", fs.readFile("scripts/loader-vectors.json"))

local passed, failed = 0, 0
local function check(name: string, condition: boolean, detail: any?)
	if condition then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}{if detail ~= nil then `: {tostring(detail)}` else ""}`)
	end
end

Signing.init({
	GetAttribute = function(_, name)
		return if name == "FallbackPublicKey" then VECTORS.keys.fallback else nil
	end,
}, function(text)
	return serde.decode("json", text)
end)

local function message(name)
	local copy = table.clone(VECTORS[name])
	copy.canonical = nil
	return copy
end

-- A fake server: players, teleports, kicks, timers that run when asked.
local function server(options)
	options = options or {}
	local world = { players = options.players or { "a", "b", "c" }, teleported = {}, kicked = {}, timers = {}, alerts = {}, joins = {} }
	Drain.configure({
		verify = function(canonical, sig, sigF)
			return Signing.verify(canonical, sig, sigF)
		end,
		kernelHash = options.hash or false, -- (configure skips nil values)
		serverType = function()
			return options.serverType or "public"
		end,
		nowMs = function()
			return options.nowMs or 1791500000000 + 5000
		end,
		random = function(low, high)
			return options.pick or high
		end,
		delay = function(seconds, fn)
			table.insert(world.timers, { seconds = seconds, fn = fn })
		end,
		players = function()
			return world.players
		end,
		teleport = function(list, data)
			if options.teleportFails then
				return false, "Teleport failed"
			end
			for _, player in list do
				table.insert(world.teleported, { player = player, data = data })
			end
			return true
		end,
		kick = function(player, text)
			table.insert(world.kicked, { player = player, text = text })
		end,
		onJoin = function(fn)
			table.insert(world.joins, fn)
		end,
		alert = function(level, code, text)
			table.insert(world.alerts, { level = level, code = code, text = text })
		end,
		print = function() end,
		warn = function() end,
	})
	return world
end

check("canonical", Drain.canonical({ v = "0.4.1", h = "abc", w = 600, t = 1791500000000 }) == "tt1drain\n0.4.1\nabc\n600\n1791500000000")
check("canonical refuses a newline", Drain.canonical({ v = "0.4.1\n", h = "abc", w = 600, t = 1 }) == nil)
check("canonical refuses a fraction", Drain.canonical({ v = "0.4.1", h = "abc", w = 1.5, t = 1 }) == nil)

-- A valid drain on a public server on another kernel: scheduled at a random moment, then everyone moves out.
local world = server({ pick = 120 })
local ok, why = Drain.onMessage(message("drain"))
check("scheduled", ok == true, why)
check("at a random moment in the window", #world.timers == 1 and world.timers[1].seconds == 120)
world.timers[1].fn()
check("everyone moved", #world.teleported == 3 and world.teleported[1].data.TypeTorch.drain == VECTORS.drain.h)
check("an info alert", world.alerts[1] and world.alerts[1].code == "kernel_drain")
check("joiners move too", #world.joins == 1)
world.joins[1]("late")
check("the late joiner moved", #world.teleported == 4)
check("a kick timer for the rest", #world.timers == 2 and world.timers[2].seconds == Drain.KICK_AFTER)
world.players = { "stuck" }
world.timers[2].fn()
check("the rest are kicked with the rejoin message", #world.kicked == 1 and world.kicked[1].text == Drain.KICK_MESSAGE)
local status = Drain.status()
check("status", status.started and status.moved == 4 and status.kicked == 1)
check("once started, no other drain", not (Drain.onMessage(message("drain"))))

-- Ignored: already on that kernel, a private or reserved server, a bad signature, too old.
local function ignored(options, name, mutate)
	local w = server(options)
	local data = message(name or "drain")
	if mutate then
		mutate(data)
	end
	local okIgnored, whyIgnored = Drain.onMessage(data)
	return not okIgnored and #w.timers == 0, whyIgnored
end
-- (a new state for these: the drain above started)
Drain.reset()
local same, whySame = ignored({ hash = VECTORS.drain.h })
check("a server already on that kernel ignores it", same and string.find(whySame, "already runs", 1, true) ~= nil, whySame)
local private, whyPrivate = ignored({ serverType = "private" })
check("private servers don't drain", private and string.find(whyPrivate, "private", 1, true) ~= nil, whyPrivate)
local reserved = ignored({ serverType = "reserved" })
check("reserved servers don't drain", reserved)
local forged, whyForged = ignored({}, "drain", function(data)
	data.w = 0
end)
check("a changed window breaks the signature", forged and string.find(whyForged, "signature", 1, true) ~= nil, whyForged)
local unsigned = ignored({}, "drain", function(data)
	data.sig, data.sigF = nil, nil
end)
check("unsigned is ignored", unsigned)
local old, whyOld = ignored({ nowMs = 1791500000000 + 3600 * 1000 })
check("an old message is ignored", old and string.find(whyOld, "ago", 1, true) ~= nil, whyOld)

-- No window: now.
Drain.reset()
local nowWorld = server({ pick = 0 })
local okNow, whyNow = Drain.onMessage(message("drainNow"))
check("window 0 fires at once", okNow == true and nowWorld.timers[1].seconds == 0, whyNow)

print(`{passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
