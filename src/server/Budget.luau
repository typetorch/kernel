--!nonstrict
-- TypeTorch kernel 0.4.0: THE BUDGET VIEW (problem 25; plans/21 part C).
--
-- Counts every DataStore, MemoryStore, HTTP and MessagingService request TypeTorch makes on this server, per minute and
-- per caller, and puts them next to Roblox's limits for the current player count:
--   kernel     the kernel's own requests (Registry, Settings, Messaging, Fallback, Fleet, Errors, the deploy topics),
--              counted through Budget.wrap (a counting proxy of a store or service) or Budget.count
--   devtools   the framework's dev menu (api:budgetCount)
--   analytics  the framework's analytics engine (api:budgetCount)
--   game       game code through TypeTorch helpers that go through a kernel API (TypeTorch.messaging publishes count here)
--              and anything the game counts itself (api:budgetCount)
--   framework  the rest of the framework
-- The game's own DataStore use shows through DataStoreService:GetRequestBudgetForRequestType (what is left of this
-- server's budget, which every caller shares). Memory: Stats (total, per developer tag) and the Lua heap.
--
-- Roblox's documented limits (checked 2026-10-09):
--   DataStore, per game server per minute (create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits,
--     "Server limits"): StandardRead (GetAsync, GetVersionAsync, UpdateAsync's read) 60 + 40 x players; StandardWrite
--     (SetAsync, IncrementAsync, UpdateAsync's write) 60 + 40 x players; StandardList (ListKeysAsync, ListVersionsAsync,
--     ListDataStoresAsync) 5 + 2 x players; StandardRemove (RemoveAsync) 60 + 40 x players. UpdateAsync uses both the
--     read and the write budget. (Ordered stores: read 60 + 40p, write 30 + 5p, list 5 + 2p, remove 30 + 5p; TypeTorch
--     uses none.) The experience as a whole: read 300 + 40 x CCU, write 300 + 20 x CCU a minute.
--   MemoryStore (create.roblox.com/docs/cloud-services/memory-stores, "Limits and quotas"): 1000 + 120 x CCU request
--     units a minute for the whole EXPERIENCE (not per server); most calls cost 1 unit, a hash map UpdateAsync at least
--     2. Per server we show 120 x players here (this server's players' part of the quota).
--   HttpService (create.roblox.com/docs/cloud-services/http-service): 500 HTTP requests a minute per game server (Open
--     Cloud requests have their own 2500; TypeTorch's servers make none).
--   MessagingService (the MessagingService "Limitations", checked 2026-10-06, see Constants): a server sends at most
--     600 + 240 x players messages a minute, holds at most 20 + 8 x players subscriptions and makes at most 240
--     subscribe requests a minute.
--
-- Per minute = a sliding estimate of the last 60 s: this clock minute's count plus the previous minute's, weighted by how
-- much of it is still inside the window. Cheap: one table per (caller, kind, op), at most BUDGET_KEYS_MAX of them.
--
-- 0.4.2 (heartbeat metrics): SERVER TPS from RunService.Heartbeat (one counter a frame, closed into one-second buckets)
-- and the physics FPS (workspace:GetRealPhysicsFPS()). Heartbeats carry `pf` = { a = average TPS, m = the slowest
-- second's TPS, p = physics FPS } over the time since the previous heartbeat (Budget.perfWindow); status().perf has the
-- same numbers over the last PERF_KEEP seconds (Budget.perf). Memory stays in the summary (`bu.mem`).

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Budget = {}

local deps = {
	time = os.time,
	players = function()
		return 0
	end,
	-- DataStoreService (GetRequestBudgetForRequestType), Stats; nil under tests that don't need them.
	dataStores = nil,
	stats = nil,
	-- () -> { { name, modules, running } }: the mounted generations (the kernel passes it).
	generations = function()
		return {}
	end,
	heap = function()
		return collectgarbage("count")
	end,
	-- 0.4.2: RunService.Heartbeat (a signal; nil under tests that drive Budget.frame themselves) and () -> number, the
	-- physics FPS (workspace:GetRealPhysicsFPS()).
	heartbeat = nil,
	physicsFps = nil,
}

function Budget.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

local CALLERS = { kernel = "k", devtools = "d", analytics = "a", game = "g", framework = "f" }
local KINDS = { datastore = true, memorystore = true, http = true, messaging = true }
-- Callers game code may name through api:budgetCount (the kernel's own counts never come from there).
local API_CALLERS = { devtools = true, analytics = true, game = true, framework = true }

-- key "caller|kind|op" -> { caller, kind, op, minute, cur, prev, total }
local counters: { [string]: any } = {}
local keys = 0
local refused = 0 -- counts that found no free counter (BUDGET_KEYS_MAX) and went to op "other"

local function minuteNow(): (number, number)
	local now = deps.time()
	return math.floor(now / 60), (now % 60) / 60
end

local function roll(entry, minute: number)
	if entry.minute ~= minute then
		entry.prev = if entry.minute == minute - 1 then entry.cur else 0
		entry.cur = 0
		entry.minute = minute
	end
end

-- Requests in the last 60 s (an estimate: see the header).
local function rate(entry, minute: number, fraction: number): number
	roll(entry, minute)
	return entry.cur + entry.prev * (1 - fraction)
end

-- Counts `n` requests (default 1). `op`: a category ("read", "write", "list", "remove", "publish", "subscribe") or a
-- label ("fleet", "errors", "ingest"). Returns nothing; never errors.
function Budget.count(caller: string, kind: string, op: string, n: number?)
	if not CALLERS[caller] or not KINDS[kind] then
		return
	end
	n = if typeof(n) == "number" and n == n then math.clamp(math.floor(n), 1, 1000) else 1
	if typeof(op) ~= "string" or #op == 0 or #op > 24 or not string.match(op, "^[%w_%.%-]+$") then
		op = "other"
	end
	local key = `{caller}|{kind}|{op}`
	local entry = counters[key]
	if not entry then
		if keys >= Constants.BUDGET_KEYS_MAX then
			-- Full: counted under "other" (one more counter per caller and kind at most).
			refused += 1
			op = "other"
			key = `{caller}|{kind}|other`
			entry = counters[key]
		end
		if not entry then
			entry = { caller = caller, kind = kind, op = op, minute = 0, cur = 0, prev = 0, total = 0 }
			counters[key] = entry
			keys += 1
		end
	end
	local minute = minuteNow()
	roll(entry, minute)
	entry.cur += n
	entry.total += n
end

-- api:budgetCount(caller, kind, op, n): the framework's and the game's own counts. `caller` must be one of devtools,
-- analytics, game, framework (anything else counts as "game"). Untrusted input: checked like any count.
function Budget.countFromApi(caller: any, kind: any, op: any, n: any)
	if typeof(caller) ~= "string" or not API_CALLERS[caller] then
		caller = "game"
	end
	if typeof(kind) ~= "string" or not KINDS[kind] then
		return
	end
	Budget.count(caller, kind, if typeof(op) == "string" then op else "other", if typeof(n) == "number" then n else 1)
end

-- Proxies -------------------------------------------------------------------------------------------------------------

-- DataStore methods -> the budget categories they use (UpdateAsync: read and write).
local DATASTORE = {
	GetAsync = { "read" },
	GetVersionAsync = { "read" },
	GetVersionAtTimeAsync = { "read" },
	SetAsync = { "write" },
	IncrementAsync = { "write" },
	UpdateAsync = { "read", "write" },
	RemoveAsync = { "remove" },
	ListKeysAsync = { "list" },
	ListVersionsAsync = { "list" },
	ListDataStoresAsync = { "list" },
	GetSortedAsync = { "list" },
}
-- MemoryStore methods -> request units (a hash map UpdateAsync costs at least 2; GetRangeAsync at least 1).
local MEMORYSTORE = {
	GetAsync = 1,
	SetAsync = 1,
	UpdateAsync = 2,
	RemoveAsync = 1,
	GetRangeAsync = 1,
	GetSizeAsync = 1,
	ListItemsAsync = 1,
	AddAsync = 1,
	ReadAsync = 1,
}
local MESSAGING = { PublishAsync = "publish", SubscribeAsync = "subscribe" }
local HTTP = { RequestAsync = true, GetAsync = true, PostAsync = true }
-- Service methods that hand out a store: the store is wrapped too.
local FACTORIES = { GetDataStore = "datastore", GetGlobalDataStore = "datastore", GetHashMap = "memorystore", GetSortedMap = "memorystore", GetQueue = "memorystore" }

local function counter(kind: string, method: string, caller: string, label: string?): (() -> ())?
	if kind == "datastore" then
		local ops = DATASTORE[method]
		return ops and function()
			for _, op in ops do
				Budget.count(caller, "datastore", op)
			end
		end
	elseif kind == "memorystore" then
		local units = MEMORYSTORE[method]
		return units and function()
			Budget.count(caller, "memorystore", label or "units", units)
		end
	elseif kind == "messaging" then
		local op = MESSAGING[method]
		return op and function()
			Budget.count(caller, "messaging", op)
		end
	elseif kind == "http" then
		return HTTP[method] and function()
			Budget.count(caller, "http", label or "request")
		end
	end
	return nil
end

-- A counting proxy of `object` (a DataStoreService, MemoryStoreService, MessagingService or HttpService, or a store
-- they handed out): every request method counts for `caller` before it runs; GetDataStore and the like return wrapped
-- stores. Everything else passes through. `kind` names what `object` is (services: "datastore" for DataStoreService,
-- "memorystore", "messaging", "http"); `label` replaces the op name of HTTP requests (fleet, errors) and MemoryStore units.
function Budget.wrap(object: any, caller: string, kind: string, label: string?): any
	if object == nil then
		return nil
	end
	local cache = {}
	return setmetatable({}, {
		__index = function(_, key)
			local cached = cache[key]
			if cached ~= nil then
				return cached
			end
			local value = object[key]
			if typeof(value) ~= "function" then
				return value
			end
			local wrapped
			local factory = FACTORIES[key]
			local before = if factory then nil else counter(kind, key, caller, label)
			if factory then
				wrapped = function(_, ...)
					return Budget.wrap(value(object, ...), caller, factory, label)
				end
			elseif before then
				wrapped = function(_, ...)
					before()
					return value(object, ...)
				end
			else
				wrapped = function(_, ...)
					return value(object, ...)
				end
			end
			cache[key] = wrapped
			return wrapped
		end,
		__tostring = function()
			return tostring(object)
		end,
	})
end

-- Limits and snapshots ------------------------------------------------------------------------------------------------

-- Roblox's per-minute limits for `players` players on this server (see the header for the sources).
function Budget.limits(players: number)
	return {
		datastore = { read = 60 + 40 * players, write = 60 + 40 * players, list = 5 + 2 * players, remove = 60 + 40 * players },
		memorystore = { units = 120 * players },
		http = { request = 500 },
		messaging = { publish = 600 + 240 * players, subscribe = 240 },
	}
end

-- What is left of this server's DataStore budget per category (shared by the game and TypeTorch), or nil per category
-- when it can't be read. Kernels on engines without the Standard* request types read the older ones.
local REQUEST_TYPES = {
	read = { "StandardRead", "GetAsync" },
	write = { "StandardWrite", "SetIncrementAsync" },
	list = { "StandardList", "ListAsync" },
	remove = { "StandardRemove", "SetIncrementAsync" },
}
local requestTypes = nil -- category -> Enum item (resolved once)
function Budget.gameBudget()
	local service = deps.dataStores
	if not service then
		return {}
	end
	if not requestTypes then
		requestTypes = {}
		for category, names in REQUEST_TYPES do
			for _, name in names do
				local ok, item = pcall(function()
					return (Enum :: any).DataStoreRequestType[name]
				end)
				if ok and item then
					requestTypes[category] = item
					break
				end
			end
		end
	end
	local left = {}
	for category, item in requestTypes do
		local ok, value = pcall(service.GetRequestBudgetForRequestType, service, item)
		if ok and typeof(value) == "number" then
			left[category] = value
		end
	end
	return left
end

-- Developer memory tags worth a look on a game server (Stats:GetMemoryUsageMbForTag).
local TAGS = { "LuaHeap", "Script", "Instances", "Signals", "PhysicsCollision", "PhysicsParts", "Animation", "Navigation", "HttpCache", "Internal" }
local function memory(detail: boolean)
	local stats = deps.stats
	local result = { heapKb = math.floor(deps.heap()) }
	if not stats then
		return result
	end
	local ok, total = pcall(stats.GetTotalMemoryUsageMb, stats)
	result.total = if ok and typeof(total) == "number" then total else nil
	local tags = {}
	for _, name in (if detail then TAGS else { "LuaHeap" }) do
		local found, value = pcall(function()
			return stats:GetMemoryUsageMbForTag((Enum :: any).DeveloperMemoryTag[name])
		end)
		if found and typeof(value) == "number" then
			if name == "LuaHeap" then
				result.luaHeap = value
			end
			if detail then
				table.insert(tags, { name = name, mb = value })
			end
		end
	end
	if detail then
		table.sort(tags, function(a, b)
			return a.mb > b.mb
		end)
		result.tags = tags
	end
	return result
end

local function round(value: number, places: number?): number
	local scale = 10 ^ (places or 0)
	return math.floor(value * scale + 0.5) / scale
end

-- Per (kind, op) and per (kind, caller) sliding counts.
local function tally()
	local minute, fraction = minuteNow()
	local byOp, byCaller, rows = {}, {}, {}
	for _, entry in counters do
		local used = rate(entry, minute, fraction)
		byOp[entry.kind] = byOp[entry.kind] or {}
		byOp[entry.kind][entry.op] = (byOp[entry.kind][entry.op] or 0) + used
		byCaller[entry.kind] = byCaller[entry.kind] or {}
		byCaller[entry.kind][entry.caller] = (byCaller[entry.kind][entry.caller] or 0) + used
		table.insert(rows, { caller = entry.caller, kind = entry.kind, op = entry.op, perMinute = round(used, 1), total = entry.total })
	end
	table.sort(rows, function(a, b)
		if a.perMinute ~= b.perMinute then
			return a.perMinute > b.perMinute
		end
		return a.total > b.total
	end)
	return byOp, byCaller, rows
end

local function sum(map): number
	local total = 0
	if map then
		for _, value in map do
			total += value
		end
	end
	return total
end

-- The full view for the dev menu (api:budget(), Server > Budget). Cheap: no yield, no web call.
-- { players, window = 60, kinds = { [kind] = { rows = { { name, used, limit, left? } }, callers = { [caller] = n } } },
--   detail = { { caller, kind, op, perMinute, total } } (busiest first), memory = { total?, luaHeap?, heapKb, tags },
--   generations = { { name, modules, running } }, refused }
function Budget.snapshot()
	local players = deps.players()
	local limits = Budget.limits(players)
	local byOp, byCaller, rows = tally()
	local left = Budget.gameBudget()
	local kinds = {}
	local function used(kind: string, op: string): number
		return round((byOp[kind] and byOp[kind][op]) or 0, 1)
	end
	kinds.datastore = {
		rows = {
			{ name = "read", used = used("datastore", "read"), limit = limits.datastore.read, left = left.read },
			{ name = "write", used = used("datastore", "write"), limit = limits.datastore.write, left = left.write },
			{ name = "list", used = used("datastore", "list"), limit = limits.datastore.list, left = left.list },
			{ name = "remove", used = used("datastore", "remove"), limit = limits.datastore.remove, left = left.remove },
		},
	}
	kinds.memorystore = { rows = { { name = "units", used = round(sum(byOp.memorystore), 1), limit = limits.memorystore.units } } }
	kinds.http = { rows = { { name = "requests", used = round(sum(byOp.http), 1), limit = limits.http.request } } }
	kinds.messaging = {
		rows = {
			{ name = "publish", used = used("messaging", "publish"), limit = limits.messaging.publish },
			{ name = "subscribe", used = used("messaging", "subscribe"), limit = limits.messaging.subscribe },
		},
	}
	for kind, entry in kinds do
		local callers = {}
		for caller, value in byCaller[kind] or {} do
			callers[caller] = round(value, 1)
		end
		entry.callers = callers
	end
	local ok, generations = pcall(deps.generations)
	return {
		players = players,
		window = 60,
		kinds = kinds,
		detail = rows,
		memory = memory(true),
		generations = if ok and typeof(generations) == "table" then generations else {},
		refused = refused,
	}
end

-- The compact per-minute summary that rides on fleet heartbeats (key `bu`; the backend stores it per server):
-- { p = players, ds = { r, w, l, x, lr, lw, br?, bw? }, ms = { u, l }, h = { r, l }, mg = { p, lp, s, ls },
--   by = { k, d, a, g, f }, mem = { t?, h? } }: requests in the last 60 s (rounded), limits, the DataStore budget left
-- (br/bw: read/write, shared with the game), requests per caller over every kind, memory in MB (h: the LuaHeap tag;
-- 0.4.2: the Lua VM heap when the tag can't be read).
function Budget.summary()
	local players = deps.players()
	local limits = Budget.limits(players)
	local byOp, byCaller = tally()
	local left = Budget.gameBudget()
	local function op(kind: string, name: string): number
		return round((byOp[kind] and byOp[kind][name]) or 0)
	end
	local by = {}
	for _, callers in byCaller do
		for caller, value in callers do
			local short = CALLERS[caller]
			by[short] = (by[short] or 0) + value
		end
	end
	for short, value in by do
		by[short] = round(value)
	end
	local mem = memory(false)
	return {
		p = players,
		ds = {
			r = op("datastore", "read"),
			w = op("datastore", "write"),
			l = op("datastore", "list"),
			x = op("datastore", "remove"),
			lr = limits.datastore.read,
			lw = limits.datastore.write,
			br = if left.read then round(left.read) else nil,
			bw = if left.write then round(left.write) else nil,
		},
		ms = { u = round(sum(byOp.memorystore)), l = limits.memorystore.units },
		h = { r = round(sum(byOp.http)), l = limits.http.request },
		mg = { p = op("messaging", "publish"), lp = limits.messaging.publish, s = op("messaging", "subscribe"), ls = limits.messaging.subscribe },
		by = by,
		mem = {
			t = if mem.total then round(mem.total, 1) else nil,
			h = if mem.luaHeap then round(mem.luaHeap, 1) elseif mem.heapKb > 0 then round(mem.heapKb / 1024, 1) else nil,
		},
	}
end

-- Perf (0.4.2) --------------------------------------------------------------------------------------------------------

-- TPS = Heartbeat frames a second. Each frame adds to the open bucket; once it holds a second (the frames' dt summed) it
-- closes: its frames and seconds go into a ring of the last PERF_KEEP buckets (status().perf) and into the window since
-- the last heartbeat (`pf`), whose slowest bucket is the minimum. A frame costs two adds and a compare.
local PERF_KEEP = 60
local perf = {
	connection = nil,
	frames = 0, -- the open bucket
	seconds = 0,
	ringFrames = table.create(PERF_KEEP, 0),
	ringSeconds = table.create(PERF_KEEP, 0),
	ringMin = table.create(PERF_KEEP, 0),
	closed = 0, -- buckets closed since start (the ring holds the last PERF_KEEP)
	last = nil, -- the newest closed bucket's TPS
	window = { frames = 0, seconds = 0, min = math.huge, buckets = 0 },
}

local function closeBucket()
	local tps = perf.frames / perf.seconds
	perf.closed += 1
	local slot = (perf.closed - 1) % PERF_KEEP + 1
	perf.ringFrames[slot], perf.ringSeconds[slot], perf.ringMin[slot] = perf.frames, perf.seconds, tps
	perf.last = tps
	local window = perf.window
	window.frames += perf.frames
	window.seconds += perf.seconds
	window.buckets += 1
	if tps < window.min then
		window.min = tps
	end
	perf.frames, perf.seconds = 0, 0
end

-- One Heartbeat frame (`dt` seconds since the last one).
function Budget.frame(dt: number)
	perf.frames += 1
	perf.seconds += dt
	if perf.seconds >= 1 then
		closeBucket()
	end
end

-- Connects deps.heartbeat (RunService.Heartbeat) once. Returns whether frames are counted.
function Budget.startPerf(): boolean
	if perf.connection then
		return true
	end
	local signal = deps.heartbeat
	if signal == nil then
		return false
	end
	local ok, connection = pcall(function()
		return signal:Connect(Budget.frame)
	end)
	if ok then
		perf.connection = connection
	end
	return ok
end

local function physics(): number?
	local read = deps.physicsFps
	if not read then
		return nil
	end
	local ok, value = pcall(read)
	return if ok and typeof(value) == "number" and value == value and value >= 0 and value < 1e6 then round(value, 1) else nil
end

-- `pf` for a heartbeat: { a, m, p } (TPS average, the slowest second, physics FPS; 0.1 steps) over the buckets closed
-- since the previous call, which starts a new window. No bucket closed since (two heartbeats within a second): the
-- newest one, and the window goes on. nil before the first second was counted (p alone is not worth sending).
function Budget.perfWindow()
	local window = perf.window
	local average, slowest
	if window.buckets > 0 then
		average, slowest = window.frames / window.seconds, window.min
		window.frames, window.seconds, window.min, window.buckets = 0, 0, math.huge, 0
	elseif perf.last then
		average, slowest = perf.last, perf.last
	else
		return nil
	end
	return { a = round(average, 1), m = round(slowest, 1), p = physics() }
end

-- status().perf (the dev menu): { a, m, p, s } over the last PERF_KEEP seconds (s = the seconds counted); nil before the
-- first second. Doesn't touch the heartbeat window.
function Budget.perf()
	local count = math.min(perf.closed, PERF_KEEP)
	if count == 0 then
		return nil
	end
	local frames, seconds, slowest = 0, 0, math.huge
	for slot = 1, count do
		frames += perf.ringFrames[slot]
		seconds += perf.ringSeconds[slot]
		slowest = math.min(slowest, perf.ringMin[slot])
	end
	return { a = round(frames / seconds, 1), m = round(slowest, 1), p = physics(), s = math.floor(seconds + 0.5) }
end

-- Tests: forget every count.
function Budget._reset()
	table.clear(counters)
	keys = 0
	refused = 0
	requestTypes = nil
	perf.frames, perf.seconds, perf.closed, perf.last = 0, 0, 0, nil
	perf.window = { frames = 0, seconds = 0, min = math.huge, buckets = 0 }
end

return Budget
