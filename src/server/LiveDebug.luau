--!nonstrict
-- TypeTorch kernel 0.5.7: LIVE DEBUG (plans/34). What the game declares for the backend's explorer, on top of remote
-- debug (plans/25, RemoteDebug.luau):
--
--   * DECLARATIONS (api:debugDeclare): the running generation's custom fleet COLUMNS, read-only COMMANDS (op
--     `game.<name>`) and STREAMS. Normalized here (names ^[a-z][a-z0-9_]{0,31}$, at most LD_COLUMNS_MAX /
--     LD_COMMANDS_MAX / LD_STREAMS_MAX, labels LD_LABEL_MAX, descriptions LD_DESCRIPTION_MAX, rates LD_HZ_MIN..LD_HZ_MAX)
--     into the heartbeat's wire form `xd` = { c = { { n, l?, t? } }, cmd = { { n, l?, d? } }, st = { { n, hz, k?, l? } } }
--     and its short hash `xh`. Fleet.luau puts `xh` on every heartbeat and `xd` on the first one, after a change and when
--     the backend asked (`xq = 1`).
--   * COLUMN VALUES (`cv`, read when a heartbeat is built): each declared column's getter (api:onDebugColumn) runs on a
--     kernel thread under pcall; one that fails, yields past LD_COLUMNS_DEADLINE or returns something else than a
--     string (<= LD_VALUE_TEXT_MAX characters), a finite number or a boolean sends JSON null. api:debugColumnsChanged()
--     asks for a coalesced heartbeat (at most one per FLEET_COLUMNS_GAP s).
--   * STREAMS (POST <backend>/v1/fleet/streams { j, frames = { { t, s = { <stream> = value } } } }): while the remote
--     debug poll runs (the explorer watches this server), the built-in `positions` (every player's HumanoidRootPart,
--     health and state, LD_POSITIONS_HZ) and the generation's streams (`game.<name>`, each at its own rate, through
--     api:onDebugStream) are sampled and posted every LD_POST_SECONDS. Each value at most LD_VALUE_MAX bytes of JSON
--     (bigger: dropped, counted), a body at most LD_BODY_MAX (the oldest frames go first). It stops when a reply says
--     neither `watch` nor `lm`, when the poll stops, or after LD_FAILURES_MAX failed posts in a row (a 401/403/404 holds
--     it off LD_AUTH_HOLD s).
--   * LIVE MAP MODE (`lm`): the explorer's fleet-wide map. A wake { k = "lm" } on TypeTorch/deploy (every server; at most
--     one per LD_LM_WAKE_GAP s acted on) or a heartbeat reply with `lm = 1` makes this server post ONLY `positions`, one
--     frame every LM_INTERVAL s, while the replies say `lm` (or `watch`); it stops LM_IDLE_SECONDS after the last one.
--
-- Nothing here yields the game: the sampler and every post run on kernel threads, a getter gets pcall and a deadline
-- (and is then ignored), and the only per-tick work is reading the players' positions (LD_POSITIONS_HZ; LM_INTERVAL in
-- live map mode). Every post goes to the signed settings' backend (Fleet.target()) only, with its key, and is counted
-- in the budget view (HTTP "debug": the kernel wraps deps.http). Custom stream values are scrubbed of secrets like
-- remote debug answers. Studio and servers without a backend never post.

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local LiveDebug = {}

local deps = {
	http = nil, -- HttpService (wrapped for the budget view)
	jobId = "",
	active = false, -- a live server (a JobId, not Studio)
	-- () -> { url, token, host }? : the signed settings' backend (Fleet.target()).
	target = function()
		return nil
	end,
	encode = nil, -- (table) -> string
	decode = nil, -- (string) -> any
	-- () -> generation?: the running generation (its `debug` record and handlers, set by Api.luau).
	generation = function()
		return nil
	end,
	-- () -> { Player }
	players = function()
		return {}
	end,
	-- (text) -> (text, count): RemoteDebug.scrub with every secret the kernel knows.
	scrub = function(text)
		return text, 0
	end,
	-- (value) -> plain data (RemoteDebug.toPlain).
	toPlain = function(value)
		return value
	end,
	-- (reason) -> (): Fleet.heartbeat ("columns": coalesced, FLEET_COLUMNS_GAP).
	heartbeat = function(_reason) end,
	-- Remote debug's poll: whether it runs, its session number, and a hint that the backend says "watched".
	pollRunning = function()
		return false
	end,
	pollSession = function()
		return 0
	end,
	watchHint = function() end,
	-- Runs fn on a kernel thread (spawnOnKernel): a generation's hard stop can't end it.
	spawn = function(fn, ...)
		task.spawn(fn, ...)
	end,
	clock = os.clock,
	-- Unix milliseconds (frame times).
	nowMs = function()
		return DateTime.now().UnixTimestampMillis
	end,
	wait = function(seconds)
		return task.wait(seconds)
	end,
	warn = warn,
	print = print,
}

function LiveDebug.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

-- Declarations ---------------------------------------------------------------------------------------------------------

local KINDS = { points = true, json = true }
local TYPES = { string = true, number = true, bool = true }

local function validName(name: any): boolean
	return typeof(name) == "string" and #name >= 1 and #name <= 32 and string.match(name, "^[a-z][a-z0-9_]*$") ~= nil
end
LiveDebug.validName = validName

-- `text` without control characters, at most `max` characters (UTF-8 aware; invalid UTF-8 keeps its ASCII only), or nil
-- (not a string, or empty).
local function cleanText(text: any, max: number): string?
	if typeof(text) ~= "string" then
		return nil
	end
	local value = string.gsub(text, "%c", " ")
	if utf8.len(value) == nil then
		value = string.gsub(value, "[\128-\255]", "")
	end
	local ok, cut = pcall(utf8.offset, value, max + 1)
	if ok and cut then
		value = string.sub(value, 1, cut - 1)
	elseif not ok then
		value = string.sub(value, 1, max)
	end
	return if #value > 0 then value else nil
end
LiveDebug.cleanText = cleanText

-- 32-bit FNV-1a of `text` from `basis`, without overflowing a double.
local function fnv(text: string, basis: number): number
	local hash = basis
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = (bit32.lshift(hash, 24) + hash * 403) % 4294967296
	end
	return hash
end

local function canonical(x): string
	local parts = {}
	local function add(value)
		local text = if value == nil then "" else tostring(value)
		table.insert(parts, `{#text}:{text}`)
	end
	add("c")
	for _, column in x.c do
		add(column.n)
		add(column.l)
		add(column.t)
	end
	add("cmd")
	for _, command in x.cmd do
		add(command.n)
		add(command.l)
		add(command.d)
	end
	add("st")
	for _, stream in x.st do
		add(stream.n)
		add(string.format("%.2f", stream.hz))
		add(stream.k)
		add(stream.l)
	end
	return table.concat(parts, ",")
end

-- The short hash of a wire declaration `xd` (16 hex characters).
function LiveDebug.hash(x): string
	local text = canonical(x)
	return string.format("%08x%08x", fnv(text, 2166136261), fnv(text, 3432918353))
end

local function list(value: any): { any }
	if typeof(value) ~= "table" then
		return {}
	end
	local out = {}
	for index = 1, math.min(#value, 256) do
		table.insert(out, value[index])
	end
	return out
end

-- The game's declarations { columns = { { name, label?, type? } }, commands = { { name, label?, description? } },
-- streams = { { name, hz, kind?, label? } } } -> (record?, dropped): record = { x (the wire form), xh, columns = { name },
-- commands = { [name] = true }, streams = { { n, hz, k } } }, or nil when nothing valid is declared. Bad entries,
-- duplicates and entries past the limits are dropped (counted); labels and descriptions are cut.
function LiveDebug.normalize(declarations: any)
	local dropped = 0
	if typeof(declarations) ~= "table" then
		return nil, 0
	end
	local x = { c = {}, cmd = {}, st = {} }
	local record = { x = x, xh = "", columns = {}, commands = {}, streams = {} }
	local seen = { c = {}, cmd = {}, st = {} }
	for _, column in list(declarations.columns) do
		if typeof(column) ~= "table" or not validName(column.name) or seen.c[column.name] or #x.c >= Constants.LD_COLUMNS_MAX then
			dropped += 1
			continue
		end
		seen.c[column.name] = true
		table.insert(x.c, { n = column.name, l = cleanText(column.label, Constants.LD_LABEL_MAX), t = if TYPES[column.type] then column.type else nil })
		table.insert(record.columns, column.name)
	end
	for _, command in list(declarations.commands) do
		if typeof(command) ~= "table" or not validName(command.name) or seen.cmd[command.name] or #x.cmd >= Constants.LD_COMMANDS_MAX then
			dropped += 1
			continue
		end
		seen.cmd[command.name] = true
		table.insert(x.cmd, { n = command.name, l = cleanText(command.label, Constants.LD_LABEL_MAX), d = cleanText(command.description, Constants.LD_DESCRIPTION_MAX) })
		record.commands[command.name] = true
	end
	for _, stream in list(declarations.streams) do
		local hz = if typeof(stream) == "table" then stream.hz else nil
		if typeof(stream) ~= "table" or not validName(stream.name) or seen.st[stream.name] or #x.st >= Constants.LD_STREAMS_MAX or typeof(hz) ~= "number" or hz ~= hz then
			dropped += 1
			continue
		end
		seen.st[stream.name] = true
		hz = math.floor(math.clamp(hz, Constants.LD_HZ_MIN, Constants.LD_HZ_MAX) * 100 + 0.5) / 100
		local kind = if KINDS[stream.kind] then stream.kind else "json"
		table.insert(x.st, { n = stream.name, hz = hz, k = kind, l = cleanText(stream.label, Constants.LD_LABEL_MAX) })
		table.insert(record.streams, { n = stream.name, hz = hz, k = kind })
	end
	if #x.c == 0 and #x.cmd == 0 and #x.st == 0 then
		return nil, dropped
	end
	record.xh = LiveDebug.hash(x)
	return record, dropped
end

-- Fleet.luau: the running generation's (xh, x), or nil when it declared nothing.
function LiveDebug.declarations()
	local generation = deps.generation()
	local record = generation and generation.debug
	if not record then
		return nil, nil
	end
	return record.xh, record.x
end

-- Api.luau: `generation` declared (again). A change on the running generation asks for a heartbeat (it carries `xd`).
function LiveDebug.declared(generation, previousHash: string?)
	local record = generation and generation.debug
	local hash = if record then record.xh else nil
	if generation == deps.generation() and hash ~= previousHash then
		deps.heartbeat("columns")
	end
end

-- Api.luau (api:debugColumnsChanged): the running generation's values changed; a coalesced heartbeat.
function LiveDebug.columnsChanged(generation): boolean
	if generation ~= deps.generation() or not (generation.debug and #generation.debug.columns > 0) then
		return false
	end
	deps.heartbeat("columns")
	return true
end

-- Bounded calls ---------------------------------------------------------------------------------------------------------

local stats = {
	columnReads = 0,
	columnFailures = 0,
	columnTimeouts = 0,
	sessions = 0,
	frames = 0,
	posts = 0,
	failed = 0,
	dropped = 0, -- frames that didn't fit a body
	oversize = 0, -- values over LD_VALUE_MAX
	sampleFailures = 0,
	sampleTimeouts = 0,
	lmWakes = 0,
	lmIgnored = 0,
	lastPostAt = nil,
	lastError = nil,
	lastMode = nil,
	stopReason = nil,
}

-- Runs each job (fn, arg) on its own kernel thread under pcall and waits until all finished or `deadline` s passed.
-- Returns { { done, ok, value } } in order. Only the calling (kernel) thread waits.
local function runBounded(jobs: { { any } }, deadline: number)
	local slots = {}
	for index, job in jobs do
		local slot = { done = false, ok = false, value = nil }
		slots[index] = slot
		deps.spawn(function()
			local ok, value = pcall(job[1], job[2])
			slot.ok, slot.value, slot.done = ok, value, true
		end)
	end
	local stop = deps.clock() + deadline
	while true do
		local open = false
		for _, slot in slots do
			if not slot.done then
				open = true
				break
			end
		end
		if not open or deps.clock() >= stop then
			break
		end
		deps.wait(0.02)
	end
	return slots
end

-- A column value as it goes on the wire, or nil (JSON null).
function LiveDebug.cleanValue(value: any)
	local kind = typeof(value)
	if kind == "string" then
		return cleanText(value, Constants.LD_VALUE_TEXT_MAX) or ""
	elseif kind == "number" then
		return if value == value and value ~= math.huge and value ~= -math.huge then value else nil
	elseif kind == "boolean" then
		return value
	end
	return nil
end

-- Fleet.luau, when it builds a heartbeat: { <column> = value | Constants.FLEET_NULL } for the running generation's
-- columns, or nil (none declared). Yields at most LD_COLUMNS_DEADLINE s (on the fleet sender's kernel thread).
function LiveDebug.columnValues()
	local generation = deps.generation()
	local record = generation and generation.debug
	if not record or #record.columns == 0 then
		return nil
	end
	local out = {}
	local getter = generation.debugColumnHandler
	if typeof(getter) ~= "function" then
		for _, name in record.columns do
			out[name] = Constants.FLEET_NULL
		end
		return out
	end
	local jobs = {}
	for index, name in record.columns do
		jobs[index] = { getter, name }
	end
	local slots = runBounded(jobs, Constants.LD_COLUMNS_DEADLINE)
	for index, name in record.columns do
		local slot = slots[index]
		stats.columnReads += 1
		local value = nil
		if not slot.done then
			stats.columnTimeouts += 1
		elseif not slot.ok then
			stats.columnFailures += 1
		else
			value = LiveDebug.cleanValue(slot.value)
		end
		out[name] = if value == nil then Constants.FLEET_NULL else value
	end
	return out
end

-- Positions ----------------------------------------------------------------------------------------------------------

local function finite(n: any): boolean
	return typeof(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
local function round(n: number, places: number): number
	local scale = 10 ^ places
	return math.floor(n * scale + 0.5) / scale
end

local function positionOf(player)
	local entry = { u = player.UserId, n = player.Name, st = "none" }
	local character = player.Character
	if not character then
		return entry
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return entry
	end
	local frame = root.CFrame
	local position = frame.Position
	if not (finite(position.X) and finite(position.Y) and finite(position.Z)) then
		return entry
	end
	entry.x, entry.y, entry.z = round(position.X, 1), round(position.Y, 1), round(position.Z, 1)
	local look = frame.LookVector
	if finite(look.X) and finite(look.Z) and (look.X ~= 0 or look.Z ~= 0) then
		entry.yaw = round(math.atan2(-look.X, -look.Z), 2) -- 0 = facing -Z
	end
	local dead = false
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local health = humanoid.Health
		if finite(health) then
			entry.hp = round(health, 1)
			dead = health <= 0
		end
		local ok, humanoidState = pcall(function()
			return humanoid:GetState()
		end)
		if ok and humanoidState and humanoidState.Name == "Dead" then
			dead = true
		end
	end
	entry.st = if dead then "dead" else "alive"
	return entry
end

-- The built-in `positions` value: { players = { { u, n, x?, y?, z?, yaw?, hp?, st } } }. Reads properties only.
function LiveDebug.positions()
	local players = {}
	local ok, list = pcall(deps.players)
	if ok and typeof(list) == "table" then
		for _, player in list do
			local entryOk, entry = pcall(positionOf, player)
			if entryOk and entry then
				table.insert(players, entry)
			end
		end
	end
	return { players = players }
end

-- The stream session ---------------------------------------------------------------------------------------------------

local state = {
	running = false,
	closed = false,
	mode = nil, -- "watch" | "lm" (what the loop does now)
	lmUntil = 0, -- live map mode holds until then
	lmWakeAt = nil, -- deps.clock() of the last lm wake acted on
	holdUntil = 0, -- a 401/403/404: no posts before then
	stoppedSession = nil, -- the poll session in which a reply or failures stopped the watch streams
	failures = 0,
	inflight = false,
	buffer = {}, -- frame JSON strings, oldest first
	bufferBytes = 0,
}

local function noteError(text: string)
	stats.lastError = string.sub(string.gsub(tostring(text), "%c", " "), 1, 200)
end

-- What the loop should do now: "watch" (every stream), "lm" (positions every LM_INTERVAL) or nil (stop).
local function wantedMode(): string?
	if state.closed or not deps.active or deps.clock() < state.holdUntil or not deps.target() then
		return nil
	end
	local polling = deps.pollRunning()
	if polling and state.stoppedSession ~= deps.pollSession() then
		return "watch"
	end
	if deps.clock() < state.lmUntil then
		return "lm"
	end
	return nil
end

local function stopAll(why: string)
	state.stoppedSession = deps.pollSession()
	state.lmUntil = 0
	stats.stopReason = why
end

-- One frame's JSON `{"t":..,"s":{..}}` from { { key, json } }; values that would make it bigger than a body are dropped.
local function frameJson(t: number, values: { { string } }): string?
	local parts = {}
	local size = 32
	for _, pair in values do
		local piece = `"{pair[1]}":{pair[2]}`
		if size + #piece + 1 > Constants.LD_BODY_MAX - 256 then
			stats.oversize += 1
			continue
		end
		size += #piece + 1
		table.insert(parts, piece)
	end
	if #parts == 0 then
		return nil
	end
	return `\{"t":{string.format("%.0f", t)},"s":\{{table.concat(parts, ",")}}}`
end

-- Adds a frame to the buffer; the oldest frames go when the body would pass LD_BODY_MAX.
local function push(json: string?)
	if not json then
		return
	end
	stats.frames += 1
	table.insert(state.buffer, json)
	state.bufferBytes += #json + 1
	while state.bufferBytes > Constants.LD_BODY_MAX - 256 and #state.buffer > 1 do
		local oldest = table.remove(state.buffer, 1)
		state.bufferBytes -= #oldest + 1
		stats.dropped += 1
	end
end

-- An encoded value, or nil (can't be encoded, or over LD_VALUE_MAX: dropped and counted).
local function encodeValue(value: any, scrub: boolean): string?
	local plainOk, plain = pcall(deps.toPlain, value)
	if not plainOk then
		stats.sampleFailures += 1
		return nil
	end
	local ok, json = pcall(deps.encode, if plain == nil then {} else plain)
	if not ok or typeof(json) ~= "string" then
		stats.sampleFailures += 1
		return nil
	end
	if scrub then
		local scrubbedOk, scrubbed = pcall(deps.scrub, json)
		if not scrubbedOk or typeof(scrubbed) ~= "string" then
			stats.sampleFailures += 1
			return nil
		end
		json = scrubbed
	end
	if #json > Constants.LD_VALUE_MAX then
		stats.oversize += 1
		return nil
	end
	return json
end

local function handleReply(code: number?, body: string?)
	state.failures = 0
	stats.lastPostAt = os.time()
	local ok, reply = pcall(deps.decode, body or "")
	if not ok or typeof(reply) ~= "table" then
		return
	end
	local watch, lm = reply.watch == true, reply.lm == true
	if not watch and not lm then
		stopAll("the backend says nobody watches")
		return
	end
	local now = deps.clock()
	-- Live map mode holds while the replies say lm (or watch, while the poll doesn't run); a watch reply during the poll
	-- doesn't extend it, so the streams end with the poll.
	if lm or not deps.pollRunning() then
		state.lmUntil = math.max(state.lmUntil, now + Constants.LM_IDLE_SECONDS)
	end
	if watch then
		if not deps.pollRunning() then
			pcall(deps.watchHint) -- watched, but the poll doesn't run (yet): wake it like a heartbeat's rd = 1
		end
	elseif deps.pollRunning() then
		state.stoppedSession = deps.pollSession() -- lm only: positions every LM_INTERVAL from now on
	end
end

-- Posts the buffered frames (on its own kernel thread; one post at a time).
local function flush()
	if state.inflight or #state.buffer == 0 then
		return
	end
	local target = deps.target()
	if not target then
		return
	end
	local okHead, head = pcall(deps.encode, { j = deps.jobId })
	if not okHead or typeof(head) ~= "string" then
		return
	end
	local body = `{string.sub(head, 1, -2)},"frames":[{table.concat(state.buffer, ",")}]}`
	table.clear(state.buffer)
	state.bufferBytes = 0
	state.inflight = true
	deps.spawn(function()
		stats.posts += 1
		local headers = { ["Authorization"] = "Bearer " .. target.token, ["X-TT-Job"] = deps.jobId, ["Content-Type"] = "application/json" }
		local ok, response = pcall(deps.http.RequestAsync, deps.http, { Url = target.url .. Constants.LD_STREAMS_PATH, Method = "POST", Headers = headers, Body = body })
		state.inflight = false
		if ok and typeof(response) == "table" and response.Success == true then
			handleReply(response.StatusCode, response.Body)
			return
		end
		stats.failed += 1
		local code = if ok and typeof(response) == "table" then response.StatusCode else nil
		if not ok then
			local text = string.sub(tostring(response), 1, 200)
			local scrubbedOk, scrubbed = pcall(deps.scrub, text)
			noteError(if scrubbedOk and typeof(scrubbed) == "string" then scrubbed else "request failed")
		else
			noteError(`HTTP {tostring(code)}`)
		end
		if code == 401 or code == 403 or code == 404 then
			state.holdUntil = deps.clock() + Constants.LD_AUTH_HOLD
			stopAll(`the backend refused the streams (HTTP {code})`)
			return
		end
		state.failures += 1
		if state.failures >= Constants.LD_FAILURES_MAX then
			stopAll(`{state.failures} failed posts in a row ({stats.lastError or "?"})`)
		end
	end)
end

-- The custom streams due now, sampled at once (each on a kernel thread, LD_STREAM_DEADLINE); appended to `values`.
local function sampleCustom(generation, due: { any }, values: { { string } })
	local handler = generation and generation.debugStreamHandler
	if #due == 0 or typeof(handler) ~= "function" then
		return
	end
	local jobs = {}
	for index, stream in due do
		jobs[index] = { handler, stream.n }
	end
	local slots = runBounded(jobs, Constants.LD_STREAM_DEADLINE)
	for index, stream in due do
		local slot = slots[index]
		if not slot.done then
			stats.sampleTimeouts += 1
		elseif not slot.ok then
			stats.sampleFailures += 1
		elseif slot.value ~= nil then
			local json = encodeValue(slot.value, true)
			if json then
				table.insert(values, { `game.{stream.n}`, json })
			end
		end
	end
end

local function loop()
	state.running = true
	stats.sessions += 1
	state.failures = 0
	table.clear(state.buffer)
	state.bufferBytes = 0
	local nextAt: { [string]: number } = {}
	local nextPositions, nextPost, nextLm = deps.clock(), deps.clock() + Constants.LD_POST_SECONDS, deps.clock()
	local streamsOf = nil -- the generation whose streams `nextAt` follows
	while true do
		local mode = wantedMode()
		if not mode then
			break
		end
		local now = deps.clock()
		if mode ~= state.mode then
			state.mode = mode
			stats.lastMode = mode
			table.clear(state.buffer) -- live map mode posts positions only
			state.bufferBytes = 0
			nextLm, nextPositions, nextPost = now, now, now + Constants.LD_POST_SECONDS
		end
		local sleep
		if mode == "watch" then
			local generation = deps.generation()
			local streams = if generation and generation.debug then generation.debug.streams else {}
			if streamsOf ~= generation then
				streamsOf = generation
				table.clear(nextAt)
			end
			local values = {}
			if now >= nextPositions then
				nextPositions = math.max(nextPositions + 1 / Constants.LD_POSITIONS_HZ, now)
				local json = encodeValue(LiveDebug.positions(), false)
				if json then
					table.insert(values, { "positions", json })
				end
			end
			local due = {}
			for _, stream in streams do
				local at = nextAt[stream.n] or now
				if now >= at then
					nextAt[stream.n] = math.max(at + 1 / stream.hz, now)
					table.insert(due, stream)
				end
			end
			sampleCustom(generation, due, values)
			if #values > 0 then
				push(frameJson(deps.nowMs(), values))
			end
			now = deps.clock()
			if now >= nextPost then
				nextPost = math.max(nextPost + Constants.LD_POST_SECONDS, now)
				flush()
			end
			local wake = math.min(nextPositions, nextPost)
			for _, stream in streams do
				wake = math.min(wake, nextAt[stream.n] or now)
			end
			sleep = wake - now
		else
			if now >= nextLm then
				nextLm = math.max(nextLm + Constants.LM_INTERVAL, now)
				local json = encodeValue(LiveDebug.positions(), false)
				if json then
					table.clear(state.buffer)
					state.bufferBytes = 0
					push(frameJson(deps.nowMs(), { { "positions", json } }))
					flush()
				end
			end
			sleep = nextLm - deps.clock()
		end
		deps.wait(math.clamp(sleep, 0.05, 0.5))
	end
	state.running = false
	state.mode = nil
	table.clear(state.buffer)
	state.bufferBytes = 0
end

local function ensureLoop()
	if not state.running and wantedMode() then
		state.running = true
		deps.spawn(loop)
	end
end

-- RemoteDebug.luau: its poll started (`running`) or stopped. A new poll session may stream again.
function LiveDebug.onPoll(running: boolean)
	if running then
		ensureLoop()
	end
end

local function startLm(): boolean
	if state.closed or not deps.active or deps.clock() < state.holdUntil or not deps.target() then
		return false
	end
	state.lmUntil = math.max(state.lmUntil, deps.clock() + Constants.LM_IDLE_SECONDS)
	ensureLoop()
	return true
end

-- A heartbeat reply (Fleet.luau): `lm = 1` starts (or extends) live map mode.
function LiveDebug.onReply(reply: any)
	if typeof(reply) == "table" and (reply.lm == 1 or reply.lm == true) then
		startLm()
	end
end

-- A wake { k = "lm" } on TypeTorch/deploy (unsigned, every server): live map mode, at most once per LD_LM_WAKE_GAP s.
-- Its first post asks the backend (a forged wake costs one post). Never yields. Returns whether it was acted on.
function LiveDebug.onWake(message: any): boolean
	if typeof(message) ~= "table" or message.k ~= "lm" then
		return false
	end
	local now = deps.clock()
	if state.lmWakeAt ~= nil and now - state.lmWakeAt < Constants.LD_LM_WAKE_GAP then
		stats.lmIgnored += 1
		return false
	end
	state.lmWakeAt = now
	if not startLm() then
		stats.lmIgnored += 1
		return false
	end
	stats.lmWakes += 1
	return true
end

-- BindToClose: nothing new is posted.
function LiveDebug.close()
	state.closed = true
end

-- For status().liveDebug (no values, no URL, never the key).
function LiveDebug.info()
	local generation = deps.generation()
	local record = generation and generation.debug
	return {
		state = if state.running then (state.mode or "starting") elseif deps.clock() < state.holdUntil then "held" else "off",
		declared = if record then { hash = record.xh, columns = #record.columns, commands = #record.x.cmd, streams = #record.streams } else nil,
		columnReads = stats.columnReads,
		columnFailures = stats.columnFailures,
		columnTimeouts = stats.columnTimeouts,
		sessions = stats.sessions,
		frames = stats.frames,
		posts = stats.posts,
		failed = stats.failed,
		dropped = stats.dropped,
		oversize = stats.oversize,
		sampleFailures = stats.sampleFailures,
		sampleTimeouts = stats.sampleTimeouts,
		lmWakes = stats.lmWakes,
		lmIgnored = stats.lmIgnored,
		lastPostAt = stats.lastPostAt,
		lastMode = stats.lastMode,
		stopReason = stats.stopReason,
		lastError = stats.lastError,
	}
end

-- Tests: start over.
function LiveDebug._reset()
	state.running, state.closed, state.mode, state.lmUntil, state.lmWakeAt, state.holdUntil = false, false, nil, 0, nil, 0
	state.stoppedSession, state.failures, state.inflight, state.bufferBytes = nil, 0, false, 0
	table.clear(state.buffer)
	for key in stats do
		stats[key] = if typeof(stats[key]) == "number" then 0 else nil
	end
end

return LiveDebug
