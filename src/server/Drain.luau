--!nonstrict
-- TypeTorch kernel: the KERNEL DRAIN (0.4.1; plans/22 "What `typetorch kernel deploy` becomes"). A kernel update through
-- the loader reaches NEW servers only; Open Cloud's server management (restartServers) needs universe:read, which API
-- keys can't get. `typetorch kernel deploy --asset --drain <minutes>` (or `typetorch kernel drain`) publishes a signed
-- message on TypeTorch/deploy (no extra subscription):
--   { k = "drain", v = kernel version, h = kernel hash, w = window seconds, t = sent ms, sig, sigF }
-- signed over "tt1drain\n" .. v .. "\n" .. h .. "\n" .. w .. "\n" .. t (the strict rule of signed deploys).
-- A PUBLIC server whose kernel hash isn't `h` picks a random moment in the window, then moves its players out
-- (TeleportAsync to the place, without a target: matchmaking; spike K5 checks they land on fresh servers) and keeps
-- moving anyone who joins it; whoever is still here after DRAIN_KICK_AFTER seconds is kicked with a rejoin message.
-- Private servers (players' own) and reserved servers (dev) never drain: they end when they empty. A server already on
-- `h`, an unsigned or badly signed message, or one older than DRAIN_MAX_AGE is ignored. Only the newest valid message
-- counts; once the drain started it can't be called off.
-- Everything Roblox is injected (Drain.configure), so this runs under Lune: scripts/test-drain.luau.

local Drain = {}

Drain.MAX_AGE = 600 -- seconds a drain message stays valid (sent time, publisher clock)
Drain.MAX_WINDOW = 3600 -- longest spread, seconds
Drain.KICK_AFTER = 30 -- seconds after the move before the last ones are kicked
Drain.KICK_MESSAGE = "This server is updating. Please rejoin."
Drain.TAG = "tt1drain"

local deps = {
	verify = function(_canonical, _sig, _sigF)
		return false, "not configured", nil
	end,
	kernelHash = nil, -- this kernel's hash (KernelHash attribute) or nil
	serverType = function()
		return "public"
	end,
	nowMs = function()
		return os.time() * 1000
	end,
	random = math.random, -- random(0, max) -> a whole number
	delay = function(_seconds, _fn) end,
	players = function()
		return {}
	end,
	teleport = function(_players, _data)
		return true, nil
	end,
	kick = function(_player, _message) end,
	onJoin = function(_fn) end,
	alert = function(_level, _code, _message) end,
	print = print,
	warn = print,
}

local state = {
	scheduled = nil, -- { v, h, w, t, at (unix ms it fires) }
	started = false,
	moved = 0,
	kicked = 0,
	ignored = 0,
	lastIgnored = nil,
}

function Drain.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

-- The signed string; nil when a field is bad.
function Drain.canonical(data): string?
	local function whole(value)
		return typeof(value) == "number" and value == value and value >= 0 and value % 1 == 0 and value <= 2 ^ 53
	end
	if typeof(data.v) ~= "string" or string.find(data.v, "\n", 1, true) or typeof(data.h) ~= "string" or string.find(data.h, "\n", 1, true) then
		return nil
	end
	if not whole(data.w) or not whole(data.t) then
		return nil
	end
	return `{Drain.TAG}\n{data.v}\n{data.h}\n{string.format("%d", data.w)}\n{string.format("%d", data.t)}`
end

local function ignore(why: string)
	state.ignored += 1
	state.lastIgnored = why
	deps.print(`[TypeTorch] drain ignored: {why}`)
	return false, why
end

local function moveOut(list)
	if #list == 0 then
		return
	end
	for first = 1, #list, 50 do
		local batch = table.move(list, first, math.min(first + 49, #list), 1, {})
		local ok, err = deps.teleport(batch, { TypeTorch = { drain = state.scheduled and state.scheduled.h } })
		if ok then
			state.moved += #batch
		else
			deps.warn(`[TypeTorch] drain: moving {#batch} player(s) failed: {tostring(err)}`)
		end
	end
end

local function start()
	if state.started then
		return
	end
	state.started = true
	local target = state.scheduled
	deps.print(`[TypeTorch] drain: moving players to servers running kernel {target.v} ({string.sub(target.h, 1, 12)})`)
	deps.alert("info", "kernel_drain", `draining for kernel {target.v}: moving {#deps.players()} player(s)`)
	deps.onJoin(function(player)
		moveOut({ player })
	end)
	moveOut(deps.players())
	deps.delay(Drain.KICK_AFTER, function()
		for _, player in deps.players() do
			state.kicked += 1
			deps.kick(player, Drain.KICK_MESSAGE)
		end
	end)
end

-- A drain message (already decoded): (true) when scheduled, else (false, why).
function Drain.onMessage(data)
	local canonical = Drain.canonical(data)
	if not canonical then
		return ignore("malformed message")
	end
	local ok, why = deps.verify(canonical, data.sig, data.sigF)
	if not ok then
		return ignore(`signature: {tostring(why)}`)
	end
	local age = (deps.nowMs() - data.t) / 1000
	if age > Drain.MAX_AGE or age < -120 then
		return ignore(`sent {math.floor(age)} s ago`)
	end
	if deps.serverType() ~= "public" then
		return ignore(`a {deps.serverType()} server doesn't drain`)
	end
	if deps.kernelHash ~= nil and deps.kernelHash == data.h then
		return ignore("this server already runs that kernel")
	end
	if state.started then
		return ignore("already draining")
	end
	if state.scheduled and state.scheduled.t >= data.t then
		return ignore("a newer drain is scheduled")
	end
	local window = math.min(data.w, Drain.MAX_WINDOW)
	local delaySeconds = if window > 0 then deps.random(0, window) else 0
	local scheduled = { v = data.v, h = data.h, w = window, t = data.t, at = deps.nowMs() + delaySeconds * 1000 }
	state.scheduled = scheduled
	deps.print(`[TypeTorch] drain for kernel {data.v} scheduled in {delaySeconds} s (window {window} s)`)
	deps.delay(delaySeconds, function()
		if state.scheduled == scheduled then
			start()
		end
	end)
	return true, nil
end

-- A fresh state (tests; a server drains at most once).
function Drain.reset()
	state.scheduled, state.started, state.moved, state.kicked, state.ignored, state.lastIgnored = nil, false, 0, 0, 0, nil
end

function Drain.status()
	return {
		scheduled = if state.scheduled then { version = state.scheduled.v, hash = state.scheduled.h, at = state.scheduled.at } else nil,
		started = state.started,
		moved = state.moved,
		kicked = state.kicked,
		ignored = state.ignored,
		lastIgnored = state.lastIgnored,
	}
end

return Drain
