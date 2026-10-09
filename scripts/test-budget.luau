--!nonstrict
-- Budget.luau under Lune (`lune run scripts/test-budget.luau` from kernel/), 0.4.0 (problem 25): counting per caller,
-- kind and op; the sliding per-minute estimate; the counting proxies (DataStore categories with UpdateAsync as read +
-- write, MemoryStore units, HTTP labels, MessagingService) that pass self, results and errors through; Roblox's limits
-- for the player count; api counts (callers checked, n clamped); the counter cap; the game's DataStore budget left; the
-- heartbeat summary (`bu`) and the dev menu snapshot; 0.4.2: TPS (`pf` per heartbeat window, status().perf over the
-- last minute, the slowest second, physics FPS) and the Lua heap fallback. A fake clock.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local passed, failed = 0, 0
local function check(name: string, ok: boolean, detail: any?)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL  {name}{if detail ~= nil then `  ({tostring(detail)})` else ""}`)
	end
end

local now = 1791547200 -- a whole minute (unix seconds)
local Constants = luau.load(fs.readFile("src/shared/Constants.luau"), { debugName = "Constants.luau" })()
local game = {
	GetService = function(_, name)
		if name == "ReplicatedStorage" then
			return { WaitForChild = function()
				return { WaitForChild = function()
					return "Constants"
				end }
			end }
		end
		error(`unexpected service {name}`)
	end,
}
local FakeEnum = {
	DataStoreRequestType = { StandardRead = "SR", StandardWrite = "SW", StandardList = "SL", StandardRemove = "SX" },
	DeveloperMemoryTag = { LuaHeap = "LuaHeap", Script = "Script", Instances = "Instances" },
}
local env = setmetatable({
	game = game,
	Enum = FakeEnum,
	require = function(target)
		if target == "Constants" then
			return Constants
		end
		error(`unexpected require {tostring(target)}`)
	end,
}, { __index = getfenv(0) })
local Budget = luau.load(fs.readFile("src/server/Budget.luau"), { debugName = "Budget.luau", environment = env })()

local players = 10
local left = { SR = 1180, SW = 900, SL = 25, SX = 460 }
Budget.configure({
	time = function()
		return now
	end,
	players = function()
		return players
	end,
	dataStores = {
		GetRequestBudgetForRequestType = function(_, item)
			return left[item]
		end,
	},
	stats = {
		GetTotalMemoryUsageMb = function()
			return 812.5
		end,
		GetMemoryUsageMbForTag = function(_, tag)
			return ({ LuaHeap = 120.25, Script = 30, Instances = 200 })[tag]
		end,
	},
	heap = function()
		return 123456.7
	end,
	generations = function()
		return { { name = "prod-a1b2c3d#3", modules = 140, running = true } }
	end,
})

local function rowOf(snapshot, kind: string, name: string)
	for _, row in snapshot.kinds[kind].rows do
		if row.name == name then
			return row
		end
	end
	return nil
end

-- 1. Limits for the player count (Roblox's documented formulas, Budget.luau's header).
local limits = Budget.limits(10)
check("DataStore: read/write/remove 60 + 40 x players, list 5 + 2 x players", limits.datastore.read == 460 and limits.datastore.write == 460 and limits.datastore.remove == 460 and limits.datastore.list == 25)
check("MemoryStore 120 x players (this server's part), HTTP 500, MessagingService 600 + 240 x players / 240 subscribes", limits.memorystore.units == 1200 and limits.http.request == 500 and limits.messaging.publish == 3000 and limits.messaging.subscribe == 240)
check("an empty server keeps the base limits", Budget.limits(0).datastore.read == 60 and Budget.limits(0).messaging.publish == 600)

-- 2. The proxies.
local calls = {}
local function method(name: string, result: any?)
	return function(self, ...)
		table.insert(calls, { name = name, self = self, args = { ... } })
		if result == "throw" then
			error("throttled (fake)", 0)
		end
		return result
	end
end
local store = {
	GetAsync = method("GetAsync", "value"),
	SetAsync = method("SetAsync"),
	UpdateAsync = method("UpdateAsync", "updated"),
	RemoveAsync = method("RemoveAsync"),
	ListKeysAsync = method("ListKeysAsync"),
	IncrementAsync = method("IncrementAsync", "throw"),
	Name = "TypeTorch",
}
local dataStores = { GetDataStore = function(self, name)
	table.insert(calls, { name = "GetDataStore", self = self, args = { name } })
	return store
end }
local wrapped = Budget.wrap(dataStores, "kernel", "datastore")
local proxyStore = wrapped:GetDataStore("TypeTorch")
check("GetDataStore hands out a wrapped store (the real service is self)", calls[1].self == dataStores and proxyStore ~= store and proxyStore.Name == "TypeTorch")
check("results pass through", proxyStore:GetAsync("heads") == "value" and proxyStore:UpdateAsync("heads", function() end) == "updated")
check("the real store is self, arguments pass through", calls[2].self == store and calls[2].args[1] == "heads")
proxyStore:SetAsync("k", 1)
proxyStore:RemoveAsync("k")
proxyStore:ListKeysAsync()
local ok, err = pcall(function()
	return proxyStore:IncrementAsync("k", 1)
end)
check("errors pass through (still counted: the request was made)", not ok and err == "throttled (fake)")
local snapshot = Budget.snapshot()
check("UpdateAsync counts as one read and one write", rowOf(snapshot, "datastore", "read").used == 2 and rowOf(snapshot, "datastore", "write").used == 3, `{rowOf(snapshot, "datastore", "read").used} {rowOf(snapshot, "datastore", "write").used}`)
check("RemoveAsync: remove; ListKeysAsync: list", rowOf(snapshot, "datastore", "remove").used == 1 and rowOf(snapshot, "datastore", "list").used == 1)
check("the game's DataStore budget left, next to each limit", rowOf(snapshot, "datastore", "read").left == 1180 and rowOf(snapshot, "datastore", "write").left == 900 and rowOf(snapshot, "datastore", "read").limit == 460)

local hashMap = { UpdateAsync = method("UpdateAsync"), GetAsync = method("GetAsync") }
local memory = Budget.wrap({ GetHashMap = function()
	return hashMap
end }, "kernel", "memorystore")
local map = memory:GetHashMap("TypeTorch")
map:UpdateAsync("heads", function() end, 60)
map:GetAsync("heads")
local http = Budget.wrap({ RequestAsync = method("RequestAsync", { Success = true }) }, "kernel", "http", "fleet")
check("HTTP passes the response through", http:RequestAsync({ Url = "https://x" }).Success == true)
local messaging = Budget.wrap({ PublishAsync = method("PublishAsync"), SubscribeAsync = method("SubscribeAsync", "connection") }, "kernel", "messaging")
messaging:PublishAsync("TypeTorch/deploy", "{}")
check("pcall(service.Method, service, ...) works on a proxy", select(2, pcall(messaging.SubscribeAsync, messaging, "TypeTorch/deploy", function() end)) == "connection")
snapshot = Budget.snapshot()
check("MemoryStore units: UpdateAsync 2, GetAsync 1", rowOf(snapshot, "memorystore", "units").used == 3)
check("HTTP counted under its label", rowOf(snapshot, "http", "requests").used == 1)
check("MessagingService publish and subscribe", rowOf(snapshot, "messaging", "publish").used == 1 and rowOf(snapshot, "messaging", "subscribe").used == 1)
local fleetRow = nil
for _, row in snapshot.detail do
	if row.kind == "http" and row.op == "fleet" then
		fleetRow = row
	end
end
check("detail rows name caller, kind and op", fleetRow ~= nil and fleetRow.caller == "kernel" and fleetRow.perMinute == 1 and fleetRow.total == 1)

-- 3. Callers through the API.
Budget._reset()
Budget.countFromApi("analytics", "datastore", "read", 3)
Budget.countFromApi("devtools", "http", "claude", 2)
Budget.countFromApi("kernel", "messaging", "publish", 1) -- the kernel's name can't be borrowed: counts as game
Budget.countFromApi("game", "bogus", "x", 1) -- an unknown kind: ignored
Budget.countFromApi("game", "datastore", "write", 1e9) -- n clamped to 1000
Budget.countFromApi("game", "http", "bad op!", 1) -- a bad op name: "other"
snapshot = Budget.snapshot()
check("callers per kind", snapshot.kinds.datastore.callers.analytics == 3 and snapshot.kinds.http.callers.devtools == 2)
check("api counts can't claim the kernel's name", snapshot.kinds.messaging.callers.kernel == nil and snapshot.kinds.messaging.callers.game == 1)
check("n is clamped (1..1000), unknown kinds ignored", rowOf(snapshot, "datastore", "write").used == 1000)
local other = false
for _, row in snapshot.detail do
	other = other or (row.kind == "http" and row.op == "other" and row.caller == "game")
end
check("a bad op name counts as other", other)

-- 4. Per minute: a sliding estimate of the last 60 s.
Budget._reset()
for _ = 1, 40 do
	Budget.count("kernel", "datastore", "read")
end
now += 60 + 30 -- half way through the next minute
for _ = 1, 10 do
	Budget.count("kernel", "datastore", "read")
end
snapshot = Budget.snapshot()
check("per minute = this minute + the previous one weighted by what is left of the window (10 + 40 x 0.5)", rowOf(snapshot, "datastore", "read").used == 30, rowOf(snapshot, "datastore", "read").used)
now += 120
check("two quiet minutes later: 0 a minute (totals kept)", rowOf(Budget.snapshot(), "datastore", "read").used == 0 and Budget.snapshot().detail[1].total == 50)

-- 5. The counter cap.
Budget._reset()
for index = 1, Constants.BUDGET_KEYS_MAX + 20 do
	Budget.count("game", "http", `label{index}`)
end
snapshot = Budget.snapshot()
check("at most BUDGET_KEYS_MAX counters; the rest go to other and are counted", #snapshot.detail == Constants.BUDGET_KEYS_MAX + 1 and snapshot.refused == 20 and rowOf(snapshot, "http", "requests").used == Constants.BUDGET_KEYS_MAX + 20, `{#snapshot.detail} {snapshot.refused}`)

-- 6. The heartbeat summary (`bu`) and the snapshot's memory.
Budget._reset()
Budget.count("kernel", "datastore", "read", 7)
Budget.count("kernel", "datastore", "write", 2)
Budget.count("analytics", "http", "ingest", 4)
Budget.count("devtools", "memorystore", "units", 3)
Budget.count("game", "messaging", "publish", 5)
local summary = Budget.summary()
check("summary: DataStore use, limits and the budget left", summary.p == 10 and summary.ds.r == 7 and summary.ds.w == 2 and summary.ds.lr == 460 and summary.ds.br == 1180 and summary.ds.bw == 900)
check("summary: MemoryStore, HTTP, MessagingService", summary.ms.u == 3 and summary.ms.l == 1200 and summary.h.r == 4 and summary.h.l == 500 and summary.mg.p == 5 and summary.mg.lp == 3000)
check("summary: per caller over every kind (k, a, d, g)", summary.by.k == 9 and summary.by.a == 4 and summary.by.d == 3 and summary.by.g == 5)
check("summary: memory in MB (total, LuaHeap)", summary.mem.t == 812.5 and summary.mem.h == 120.3)
local size = #serde.encode("json", summary)
check("summary: small enough to ride every heartbeat (< 400 bytes of JSON)", size < 400, size)
snapshot = Budget.snapshot()
check("snapshot: memory tags biggest first, the Lua heap, the mounted generations", snapshot.memory.tags[1].name == "Instances" and snapshot.memory.heapKb == 123456 and snapshot.generations[1].modules == 140)
left = {}
check("no DataStore budget readable: left is simply missing", Budget.summary().ds.br == nil and rowOf(Budget.snapshot(), "datastore", "read").left == nil)

-- 7. 0.4.2: the Lua heap when the LuaHeap tag can't be read; TPS (`pf`, status().perf) from Heartbeat frames.
Budget.configure({
	stats = {
		GetTotalMemoryUsageMb = function()
			return 812.5
		end,
		GetMemoryUsageMbForTag = function()
			error("no such tag")
		end,
	},
})
check("summary: no LuaHeap tag: h is the Lua VM heap in MB", Budget.summary().mem.h == 120.6 and Budget.summary().mem.t == 812.5, Budget.summary().mem.h)
Budget._reset()
check("perf: nothing before the first whole second", Budget.perfWindow() == nil and Budget.perf() == nil)
local connected = nil
Budget.configure({
	heartbeat = {
		Connect = function(_, fn)
			connected = fn
			return { Disconnect = function() end }
		end,
	},
	physicsFps = function()
		return 59.94
	end,
})
check("perf: startPerf connects RunService.Heartbeat once", Budget.startPerf() == true and connected == Budget.frame and Budget.startPerf() == true)
local function frames(count: number, dt: number)
	for _ = 1, count do
		connected(dt)
	end
end
frames(128, 1 / 64) -- 2 s at 64 TPS (1/64 and 1/8 add up exactly)
frames(8, 0.125) -- 1 s at 8 TPS
frames(32, 1 / 64) -- half a second: the open bucket, not counted yet
local pf = Budget.perfWindow()
check("pf: average and the slowest second since the last heartbeat (frames / seconds), physics FPS, 0.1 steps", pf ~= nil and pf.a == 45.3 and pf.m == 8 and pf.p == 59.9, pf and `{pf.a} {pf.m} {pf.p}`)
local pfSize = #serde.encode("json", pf)
check("pf: a few bytes of JSON (<= 40)", pfSize <= 40, pfSize)
local again = Budget.perfWindow()
check("pf: a heartbeat within the same second repeats the newest second (the window goes on)", again ~= nil and again.a == 8 and again.m == 8)
frames(32, 1 / 64) -- closes the open bucket (64 frames in 1 s)
frames(64, 1 / 64)
pf = Budget.perfWindow()
check("pf: the next window starts after the last heartbeat (no 8 TPS second in it)", pf ~= nil and pf.a == 64 and pf.m == 64, pf and `{pf.a} {pf.m}`)
local perf = Budget.perf()
check("status().perf: the last minute (s = seconds counted), untouched by the heartbeat window", perf ~= nil and perf.s == 5 and perf.m == 8 and perf.a == 52.8 and perf.p == 59.9, perf and `{perf.a} {perf.m} {perf.s}`)
frames(70 * 64, 1 / 64) -- 70 more seconds at 64 TPS: the slow second leaves the minute
perf = Budget.perf()
check("status().perf keeps PERF_KEEP (60) seconds", perf.s == 60 and perf.m == 64 and perf.a == 64, `{perf.s} {perf.m}`)
frames(1, 3) -- one 3 s hitch: a bucket of one frame
pf = Budget.perfWindow()
check("pf: a hitch shows as the slowest second (one frame in 3 s)", pf.m == 0.3, pf.m)
Budget.configure({
	physicsFps = function()
		error("no workspace")
	end,
})
pf = Budget.perfWindow()
check("pf: an unreadable physics FPS is left out (TPS still sent)", pf ~= nil and pf.p == nil and pf.a ~= nil)

print(`budget: {passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
