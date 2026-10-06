--!nonstrict
-- TypeTorch kernel 0.3.8: GAME MESSAGING through kernel-held MessagingService topics (plans/19 item 4; plans/01 "Game
-- messaging"). The framework's `TypeTorch.messaging` (server only) is the game-facing API.
--
-- ONE TOPIC FOR THE GAME. Game topics ("anticheat", "announce", ...) ride one Roblox topic, Constants.GAME_TOPIC
-- (`TypeTorch/game`), as an envelope { v = 1, n = game topic, d = data, j = JobId, b = branch, c = "prod" | "dev"
-- (effective channel), s = server type, p = place version, to = "prod" | "branch"? }. The kernel subscribes on the
-- first listener and holds the subscription for the server's life: a swap never subscribes again, and listeners belong
-- to their generation (dropped when it stops). Messages that arrive while a swap runs (no listener for their topic yet)
-- are kept MESSAGING_REPLAY_SECONDS and replayed to the next generation's first listener of that topic.
--
-- PUBLISH. Checked at once (topic name, JSON-compatible data, the 1 KiB message limit counted on the JSON-escaped
-- envelope, the worst case), then queued: a per-server token bucket (a quarter of Roblox's per-server send limit) and
-- the universe's rate on the game topic (every server sees every message; at MESSAGING_TOPIC_SOFT messages in the last
-- 60 s publishes wait, so the universe stays under Roblox's per-topic receive limit together), retries after
-- MESSAGING_RETRY_DELAYS, and a message older than MESSAGING_MAX_DELAY is dropped (counted, warned). `to = "prod"`
-- reaches only prod-channel servers, `to = "branch"` only servers on the sender's branch (the receivers filter). Studio
-- never touches MessagingService: messages loop back to this session only (a Studio session must never reach live
-- servers).
--
-- ROLL CALL. The framework's roll call asks (Manage > Servers, TypeTorch.servers()) arrive on Constants.ROLLCALL_TOPIC
-- (`TypeTorch/rollcall`, the same topic and protocol as frameworks before 0.3.8). The kernel holds that subscription
-- too (api:onRollCall) and hands each ask to the running generation's one handler, so a swap doesn't subscribe again.
--
-- TRUST. Anything that can publish to the universe's MessagingService (any server's code, an Open Cloud key) can send
-- an envelope with any tags. The tags are for routing (ignore dev servers), not authentication.
--
-- THREADS. Subscriptions and the sender run on kernel threads (deps.onKernel), never on a generation's thread: a
-- generation's hard stop kills its threads and, on Roblox, the subscriptions its threads made.

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage:WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Messaging = {}

-- Set by the kernel (Messaging.configure).
local deps = {
	jobId = "",
	placeVersion = 0,
	-- This server now: { b = branch?, c = "prod" | "dev" (effective channel), s = server type }.
	self = function()
		return { b = nil, c = "prod", s = "public" }
	end,
	-- A swap runs or nothing runs (messages without a listener are kept for the next generation).
	swapping = function()
		return false
	end,
	closing = function()
		return false
	end,
	-- Runs fn on a kernel thread (the kernel's spawnOnKernel).
	onKernel = function(fn)
		task.spawn(fn)
	end,
	warn = warn,
	print = print,
}

function Messaging.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

local function isStudio(): boolean
	return RunService:IsStudio()
end

-- GAME TOPIC STATE ----------------------------------------------------------------------------------------------------

local topicState = {
	state = "off", -- "off" (nobody listened yet) | "subscribing" | "on" | "local" (Studio: in-process only)
	attempts = 0, -- failed SubscribeAsync calls
	subscribedAt = nil, -- unix s
	listeners = {}, -- [game topic] = { { fn, owner, topic, on } }
	received = 0,
	delivered = 0,
	ignored = 0, -- not a valid envelope
	filtered = 0, -- `to` excluded this server
	replayed = 0,
	published = 0,
	failed = 0, -- PublishAsync attempts that failed (each retry counts)
	dropped = 0, -- given up: retries out, too old, queue full
	throttled = 0, -- publishes that waited for the universe's rate on the game topic
	recent = {}, -- os.clock() of each message seen in the last 60 s
	held = {}, -- arrived during a swap: { topic, data, meta, at, takenBy = { [owner] = true } }
	lastError = nil,
	lastErrorAt = nil, -- unix s
}
local queue = {} -- { topic, text, at = os.clock(), attempts, waited }
local tokens = Constants.MESSAGING_BURST
local tokensAt = os.clock()
local senderRunning = false
local warnedAt: { [string]: number } = {}

local rollCall = {
	state = "off", -- "off" | "subscribing" | "on" | "local"
	attempts = 0,
	asks = 0,
	handled = 0,
	handler = nil, -- { fn, owner }
}

-- One warning per `kind` per MESSAGING_WARN_GAP seconds.
local function warnOnce(kind: string, text: string)
	local now = os.clock()
	local last = warnedAt[kind]
	if last and now - last < Constants.MESSAGING_WARN_GAP then
		return
	end
	warnedAt[kind] = now
	deps.warn(text)
end

local function noteError(text: string)
	topicState.lastError = string.sub(string.gsub(tostring(text), "%c", " "), 1, 200)
	topicState.lastErrorAt = os.time()
end

-- Messages seen on the game topic in the last 60 s (every server sees every message: the universe's rate).
local function rate(): number
	local recent = topicState.recent
	local cutoff = os.clock() - 60
	while #recent > 0 and recent[1] < cutoff do
		table.remove(recent, 1)
	end
	return #recent
end

local function budgetPerMinute(): number
	return Constants.MESSAGING_PUBLISH_BASE + Constants.MESSAGING_PUBLISH_PER_PLAYER * #Players:GetPlayers()
end

-- CHECKS --------------------------------------------------------------------------------------------------------------

local TOPIC_PATTERN = "^[%w_%-%.:/]+$"

-- Returns (ok, why).
local function validTopic(name: any): (boolean, string?)
	if typeof(name) ~= "string" then
		return false, "the topic must be a string"
	end
	if #name == 0 or #name > Constants.MESSAGING_TOPIC_MAX then
		return false, `the topic must be 1-{Constants.MESSAGING_TOPIC_MAX} characters`
	end
	if not string.match(name, TOPIC_PATTERN) then
		return false, "the topic may only use letters, digits and _ - . : /"
	end
	if string.sub(name, 1, 2) == "__" then
		return false, "topics starting with __ are reserved"
	end
	return true, nil
end

-- Why `value` can't travel as JSON, or nil. Plain data only: nil, booleans, finite numbers, strings, and tables that
-- are arrays (1..n, no holes) or have string keys, without metatables or cycles.
local function checkData(value: any, depth: number, seen: { [any]: boolean }): string?
	local kind = typeof(value)
	if kind == "nil" or kind == "boolean" or kind == "string" then
		return nil
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "a number that isn't finite (NaN or inf)"
		end
		return nil
	elseif kind == "table" then
		if depth > Constants.MESSAGING_DEPTH_MAX then
			return `tables nested deeper than {Constants.MESSAGING_DEPTH_MAX}`
		end
		if seen[value] then
			return "a table that contains itself"
		end
		if getmetatable(value) ~= nil then
			return "a table with a metatable (a class instance?)"
		end
		seen[value] = true
		local count, stringKeys, numberKeys = 0, false, false
		for key, inner in value do
			local keyKind = typeof(key)
			if keyKind == "string" then
				stringKeys = true
			elseif keyKind == "number" then
				numberKeys = true
			else
				return `a table key of type {keyKind}`
			end
			count += 1
			local why = checkData(inner, depth + 1, seen)
			if why then
				return why
			end
		end
		seen[value] = nil
		if stringKeys and numberKeys then
			return "a table mixing array items and string keys"
		end
		if numberKeys and count ~= #value then
			return "an array with holes or non-integer keys"
		end
		return nil
	end
	return `a value of type {kind} (send plain data: strings, numbers, booleans, tables)`
end

local function envelope(topic: string, data: any, to: string?)
	local me = deps.self()
	return {
		v = 1,
		n = topic,
		d = data,
		j = deps.jobId,
		b = me.b,
		c = me.c,
		s = me.s,
		p = deps.placeVersion,
		to = to,
	}
end

-- The size the message may count as: the envelope's JSON as a JSON string (quotes and escapes included).
local function wireBytes(text: string): number
	return #HttpService:JSONEncode(text)
end

-- RECEIVE -------------------------------------------------------------------------------------------------------------

local function callListener(listener, data, meta)
	task.spawn(function()
		local ok, err = pcall(listener.fn, data, table.clone(meta))
		if not ok then
			deps.warn(`[TypeTorch] a messaging listener on "{listener.topic}" threw: {err}`)
		end
	end)
end

local function pruneHeld()
	local held = topicState.held
	local cutoff = os.clock() - Constants.MESSAGING_REPLAY_SECONDS
	for index = #held, 1, -1 do
		if held[index].at < cutoff then
			table.remove(held, index)
		end
	end
end

local function live(listener): boolean
	return listener.on and not (listener.owner and listener.owner.stopping)
end

local function dispatch(topic: string, data: any, meta)
	local any = false
	for _, listener in table.clone(topicState.listeners[topic] or {}) do
		if live(listener) then
			any = true
			topicState.delivered += 1
			callListener(listener, data, meta)
		end
	end
	if not any and deps.swapping() then
		-- A swap runs (or nothing runs): the next generation's first listener of this topic gets it.
		pruneHeld()
		local held = topicState.held
		if #held >= Constants.MESSAGING_REPLAY_MAX then
			table.remove(held, 1)
		end
		table.insert(held, { topic = topic, data = data, meta = meta, at = os.clock(), takenBy = {} })
	end
end

local function text(value: any, max: number): boolean
	return typeof(value) == "string" and #value <= max
end

-- One message on the game topic (`data` = the envelope's JSON, `sent` = Roblox's unix seconds).
local function receive(data: any, sent: any)
	table.insert(topicState.recent, os.clock())
	topicState.received += 1
	if typeof(data) ~= "string" or #data > 4 * Constants.MESSAGE_MAX_BYTES then
		topicState.ignored += 1
		return
	end
	local ok, env = pcall(HttpService.JSONDecode, HttpService, data)
	if
		not ok
		or typeof(env) ~= "table"
		or env.v ~= 1
		or not validTopic(env.n)
		or not text(env.j, 64)
		or (env.b ~= nil and not text(env.b, 64))
		or (env.c ~= "prod" and env.c ~= "dev")
		or not text(env.s, 16)
		or (env.p ~= nil and typeof(env.p) ~= "number")
		or (env.to ~= nil and env.to ~= "prod" and env.to ~= "branch")
	then
		topicState.ignored += 1
		return
	end
	local me = deps.self()
	if (env.to == "prod" and me.c ~= "prod") or (env.to == "branch" and env.b ~= me.b) then
		topicState.filtered += 1
		return
	end
	dispatch(env.n, env.d, {
		channel = env.c,
		branch = env.b,
		jobId = env.j,
		serverType = env.s,
		placeVersion = env.p,
		sentAt = if typeof(sent) == "number" then sent else os.time(),
		self = env.j == deps.jobId,
	})
end

-- SUBSCRIPTIONS -------------------------------------------------------------------------------------------------------

-- Holds `topic` for the server's life (retried like the kernel's own topics). Runs on a kernel thread.
local function holdTopic(state, topic: string, handler, label: string)
	while not deps.closing() do
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(topic, handler)
		end)
		if ok then
			state.state = "on"
			state.subscribedAt = os.time()
			if state.attempts > 0 then
				deps.print(`[TypeTorch] {label}: subscribed after {state.attempts} failed attempts`)
			end
			return
		end
		state.attempts += 1
		noteError(`subscribe {topic}: {err}`)
		local delays = Constants.SUBSCRIBE_RETRY_DELAYS
		local delay = delays[math.min(state.attempts, #delays)]
		warnOnce(`subscribe {topic}`, `[TypeTorch] {label} unavailable (attempt {state.attempts}): {err}; retrying in {delay} s`)
		task.wait(delay)
	end
end

local function ensureGameTopic()
	if topicState.state ~= "off" then
		return
	end
	if isStudio() then
		topicState.state = "local"
		return
	end
	topicState.state = "subscribing"
	deps.onKernel(function()
		holdTopic(topicState, Constants.GAME_TOPIC, function(message)
			receive(message and message.Data, message and message.Sent)
		end, "game messages")
	end)
end

-- Replays the messages kept during a swap to a new listener (each one once per generation).
local function replayTo(listener)
	pruneHeld()
	local owner = listener.owner or Messaging
	for _, entry in table.clone(topicState.held) do
		if entry.topic == listener.topic and not entry.takenBy[owner] and live(listener) then
			entry.takenBy[owner] = true
			topicState.replayed += 1
			local meta = table.clone(entry.meta)
			meta.replayed = true
			callListener(listener, entry.data, meta)
		end
	end
end

-- api:messagingSubscribe: fn(data, meta) for every message on `topic` while `owner` (a generation) runs. Errors on a
-- bad topic or a missing function. Returns a disconnect function.
function Messaging.subscribe(owner, topic: string, fn): () -> ()
	local ok, why = validTopic(topic)
	if not ok then
		error(`messaging subscribe: {why}`, 3)
	end
	if typeof(fn) ~= "function" then
		error("messaging subscribe: the listener must be a function", 3)
	end
	local listener = { fn = fn, owner = owner, topic = topic, on = true }
	local list = topicState.listeners[topic]
	if not list then
		list = {}
		topicState.listeners[topic] = list
	end
	table.insert(list, listener)
	ensureGameTopic()
	task.defer(replayTo, listener)
	return function()
		listener.on = false
		local current = topicState.listeners[topic]
		local index = current and table.find(current, listener)
		if index then
			table.remove(current, index)
			if #current == 0 then
				topicState.listeners[topic] = nil
			end
		end
	end
end

-- PUBLISH -------------------------------------------------------------------------------------------------------------

local function refill()
	local now = os.clock()
	tokens = math.min(Constants.MESSAGING_BURST, tokens + (now - tokensAt) * budgetPerMinute() / 60)
	tokensAt = now
end

local function dropHead(why: string, item)
	table.remove(queue, 1)
	topicState.dropped += 1
	warnOnce(`drop {why}`, `[TypeTorch] messaging: dropped a message on "{item.topic}" ({why})`)
end

-- The one sender (a kernel thread): oldest first, within the token bucket and the universe's rate, retried on failure.
local function sender()
	while #queue > 0 and not deps.closing() do
		local item = queue[1]
		if os.clock() - item.at > Constants.MESSAGING_MAX_DELAY then
			dropHead(`waited more than {Constants.MESSAGING_MAX_DELAY} s`, item)
			continue
		end
		refill()
		if tokens < 1 then
			task.wait(0.25)
			continue
		end
		local seen = rate()
		if topicState.state == "on" and seen >= Constants.MESSAGING_TOPIC_SOFT then
			if not item.waited then
				item.waited = true
				topicState.throttled += 1
			end
			warnOnce("throttled", `[TypeTorch] messaging: the game topic carries {seen} messages a minute (soft limit {Constants.MESSAGING_TOPIC_SOFT}, Roblox's about 80 for the whole universe); publishes are waiting`)
			task.wait(0.5 + math.random() * 1.5)
			continue
		end
		tokens -= 1
		local ok, err = pcall(function()
			MessagingService:PublishAsync(Constants.GAME_TOPIC, item.text)
		end)
		if ok then
			table.remove(queue, 1)
			topicState.published += 1
		else
			topicState.failed += 1
			item.attempts += 1
			noteError(`publish: {err}`)
			local delays = Constants.MESSAGING_RETRY_DELAYS
			if item.attempts > #delays then
				dropHead(`publish failed {item.attempts} times: {topicState.lastError}`, item)
			else
				task.wait(delays[item.attempts])
			end
		end
	end
	senderRunning = false
end

-- api:messagingPublish: one message to every server's listeners of `topic` (this one too). Doesn't yield. Returns
-- { ok, queued?, loopback?, size?, error?, detail?, limit?, overhead? }; errors: "bad_topic", "bad_options",
-- "bad_data", "too_big" (size > limit; `overhead` = the envelope's own bytes), "queue_full", "closing", "stopping".
function Messaging.publish(owner, topic: string, data: any, options: any?)
	local ok, why = validTopic(topic)
	if not ok then
		return { ok = false, error = "bad_topic", detail = why }
	end
	local to = if typeof(options) == "table" then options.to else nil
	if to == "all" then
		to = nil
	end
	if to ~= nil and to ~= "prod" and to ~= "branch" then
		return { ok = false, error = "bad_options", detail = 'options.to must be "all", "prod" or "branch"' }
	end
	local bad = checkData(data, 1, {})
	if bad then
		return { ok = false, error = "bad_data", detail = bad }
	end
	if owner and owner.stopping then
		return { ok = false, error = "stopping" }
	end
	if deps.closing() then
		return { ok = false, error = "closing" }
	end
	local encoded, textOrError = pcall(HttpService.JSONEncode, HttpService, envelope(topic, data, to))
	if not encoded then
		return { ok = false, error = "bad_data", detail = tostring(textOrError) }
	end
	local size = wireBytes(textOrError)
	if size > Constants.MESSAGE_MAX_BYTES then
		local overhead = wireBytes(HttpService:JSONEncode(envelope(topic, 0, to))) - 1
		return { ok = false, error = "too_big", size = size, limit = Constants.MESSAGE_MAX_BYTES, overhead = overhead }
	end
	if isStudio() then
		-- Studio never reaches live servers: this session's listeners only.
		topicState.published += 1
		local sent = os.time()
		deps.onKernel(function()
			receive(textOrError, sent)
		end)
		return { ok = true, loopback = true, size = size }
	end
	if #queue >= Constants.MESSAGING_QUEUE_MAX then
		topicState.dropped += 1
		warnOnce("queue", `[TypeTorch] messaging: the publish queue is full ({Constants.MESSAGING_QUEUE_MAX}); dropped a message on "{topic}"`)
		return { ok = false, error = "queue_full" }
	end
	table.insert(queue, { topic = topic, text = textOrError, at = os.clock(), attempts = 0 })
	if not senderRunning then
		senderRunning = true
		deps.onKernel(sender)
	end
	return { ok = true, queued = true, size = size }
end

-- ROLL CALL -----------------------------------------------------------------------------------------------------------

-- api:onRollCall: fn(data) for every roll call ask (the raw message Data) while `owner` runs. One handler; the newest
-- wins. The topic is subscribed on the first call (not in Studio: no JobId there) and held.
function Messaging.onRollCall(owner, fn)
	if typeof(fn) ~= "function" then
		error("onRollCall: the handler must be a function", 3)
	end
	rollCall.handler = { fn = fn, owner = owner }
	if rollCall.state ~= "off" then
		return
	end
	if isStudio() or deps.jobId == "" then
		rollCall.state = "local"
		return
	end
	rollCall.state = "subscribing"
	deps.onKernel(function()
		holdTopic(rollCall, Constants.ROLLCALL_TOPIC, function(message)
			rollCall.asks += 1
			local handler = rollCall.handler
			if handler and not (handler.owner and handler.owner.stopping) then
				rollCall.handled += 1
				local data = message and message.Data
				task.spawn(function()
					local ok, err = pcall(handler.fn, data)
					if not ok then
						deps.warn(`[TypeTorch] the roll call handler threw: {err}`)
					end
				end)
			end
		end, "roll call asks")
	end)
end

-- LIFECYCLE -----------------------------------------------------------------------------------------------------------

-- A stopping generation's listeners and roll call handler go with it (queued publishes still go out).
function Messaging.dropGeneration(owner)
	if owner == nil then
		return
	end
	for topic, list in topicState.listeners do
		for index = #list, 1, -1 do
			if list[index].owner == owner then
				list[index].on = false
				table.remove(list, index)
			end
		end
		if #list == 0 then
			topicState.listeners[topic] = nil
		end
	end
	if rollCall.handler and rollCall.handler.owner == owner then
		rollCall.handler = nil
	end
end

-- status().messaging: { topic, state, topics, listeners, received, delivered, ignored, filtered, replayed, held,
-- published, failed, dropped, throttled, queued, rate, softLimit, budget, lastError?, lastErrorAt?, rollCall = { state,
-- asks, handled } }. `rate` = messages on the game topic in the last 60 s (the whole universe's); `budget` = this
-- server's publishes a minute. Cheap, no yield.
function Messaging.status()
	pruneHeld()
	local topics, listeners = 0, 0
	for _, list in topicState.listeners do
		topics += 1
		listeners += #list
	end
	return {
		topic = Constants.GAME_TOPIC,
		state = topicState.state,
		subscribedAt = topicState.subscribedAt,
		topics = topics,
		listeners = listeners,
		received = topicState.received,
		delivered = topicState.delivered,
		ignored = topicState.ignored,
		filtered = topicState.filtered,
		replayed = topicState.replayed,
		held = #topicState.held,
		published = topicState.published,
		failed = topicState.failed,
		dropped = topicState.dropped,
		throttled = topicState.throttled,
		queued = #queue,
		rate = rate(),
		softLimit = Constants.MESSAGING_TOPIC_SOFT,
		budget = budgetPerMinute(),
		lastError = topicState.lastError,
		lastErrorAt = topicState.lastErrorAt,
		rollCall = { state = rollCall.state, asks = rollCall.asks, handled = rollCall.handled },
	}
end

return Messaging
