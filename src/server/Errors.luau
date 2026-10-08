--!nonstrict
-- TypeTorch kernel 0.4.0: ERROR REPORTS (problem 19; plans/21 part C).
--
-- The kernel collects this server's errors (ScriptContext.Error and LogService error lines, from every generation and
-- the kernel itself) and its clients' (the kernel client forwards its own on Constants.CHANNEL_ERRORS, rate limited per
-- player), and posts them to the backend's POST <url>/v1/errors with the settings' one key (settings.backend, else the
-- old settings.fleet: Fleet.target()). Each message:
--   1. is TEMPLATED: every current player's (and, for ERRORS_LEFT_SECONDS, every player who just left) Name,
--      DisplayName and UserId, as whole words, become <player.name>, <player.display_name>, <player.user_id>; the
--      generation in mount paths (Generations.<artifact id>#<n>) becomes <gen>, so every swap keeps the same kind;
--   2. is FINGERPRINTED: fp = two 32-bit hashes (FNV-1a and djb2) of the template plus the top stack line, 16 hex
--      characters;
--   3. is COUNTED per minute, per fingerprint, realm ("server" | "client"), branch and build (the artifact id), with the
--      pseudonymous analytics ids (pids, from the framework's analytics engine through api:setAnalyticsId) of the
--      players it affects: the client that sent it, and players the message named (at most ERRORS_PIDS_MAX);
--   4. is KEPT IN BOUNDED MEMORY: at most ERRORS_KINDS_MAX kinds (template + the first stack) and ERRORS_ITEMS_MAX
--      per-minute items wait; at most ERRORS_RECORD_PER_SECOND errors a second are looked at. Everything past a limit
--      is dropped and counted (Errors.info().dropped).
-- Batches (at most ERRORS_BATCH_MAX items and ERRORS_BATCH_BYTES of JSON, gzip) go out every ERRORS_FLUSH_SECONDS
-- while items wait, at most ERRORS_RATE_PER_MINUTE requests a minute (the backend allows 30 per JobId). A kind's stack
-- rides only until one batch with it was accepted. Failures back off like Fleet's (0.3.9): jittered retries
-- (FLEET_RETRY_DELAYS), then exponential backoff from FLEET_HEARTBEAT_SECONDS to FLEET_BACKOFF_MAX; 401/403/404 hold off
-- FLEET_AUTH_HOLD; 429 waits its Retry-After; 413 halves the batch; 400 drops the batch (counted as rejected). One
-- warning line a minute at most, and one line when it works again. Nothing is posted from Studio (counts still show
-- in the dev menu). The key is never logged.
--
-- Contract (the backend's README "Error logs"): { v = 1, j = JobId, errors = { { fp, template, stack?, count, firstAt,
-- lastAt (unix ms), branch?, build?, realm, pids? } } } -> 202 { accepted, rejected, errors? }.

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Errors = {}

local deps = {
	active = false, -- posts (a live server: a JobId, not Studio)
	jobId = "",
	http = nil, -- HttpService (the kernel passes a Budget proxy)
	encode = nil, -- (table) -> string
	decode = nil, -- (string) -> any
	gzip = nil, -- Enum.HttpCompression.Gzip (nil: plain bodies)
	-- () -> { url, token, host } or nil: the backend (Fleet.target(): settings.backend, else settings.fleet).
	target = function()
		return nil
	end,
	-- (script?) -> { branch?, build? }: the generation an error came from (the running one without a script).
	context = function(_script)
		return {}
	end,
	nowMs = function()
		return DateTime.now().UnixTimestampMillis
	end,
	clock = os.clock,
	random = math.random,
	warn = warn,
	print = print,
}

function Errors.configure(overrides)
	for key, value in overrides do
		deps[key] = value
	end
end

-- State -----------------------------------------------------------------------------------------------------------------

local roster: { [number]: any } = {} -- UserId -> { name, display, id, leftAt?, pid? }
local rosterVersion = 0
local needles = nil -- { { text, mark, userId } }, longest first; nil = rebuild
local cache: { [string]: any } = {} -- raw message + stack -> { fp, named } for this roster version
local cacheSize, cacheVersion = 0, -1
local CACHE_MAX = 256

local kinds: { [string]: any } = {} -- fp -> { template, stack?, top, realm, total, seenAt, stackSent, waiting }
local kindCount = 0
local items: { [string]: any } = {} -- "fp|realm|build|branch|minute" -> item
local itemCount = 0
local logQueue = {} -- LogService error lines waiting for the ScriptContext dedup: { text, at }
local scriptSeen: { [string]: number } = {} -- ScriptContext messages in the last 2 s (dedup)
local clientAt: { [any]: number } = {} -- player -> clock of their last accepted batch
local second = { at = -math.huge, count = 0 } -- the per-second gate
local tokens, tokensAt = 2, -math.huge
local batchMax = Constants.ERRORS_BATCH_MAX
local started, closed, inHandler = false, false, false
local nextFlushAt = 0
local retry = 0 -- failed tries of the current batch (the retries before a failed cycle)
local stats = {
	server = 0, -- errors seen (each occurrence)
	client = 0,
	sent = 0, -- items the backend accepted
	requests = 0,
	failed = 0, -- failed requests
	rejected = 0, -- items the backend refused (202 rejected, or a 400 batch)
	dropped = { kinds = 0, items = 0, rate = 0, old = 0, client = 0 },
	lastOkAt = nil,
	lastError = nil,
	lastErrorAt = nil,
	lastStatus = nil,
}
local outage = { failures = 0, cycles = 0, untilAt = 0, since = nil, reason = nil, loggedAt = -math.huge }
local warnedAt: { [string]: number } = {}

local function warnOnce(kind: string, text: string)
	local now = deps.clock()
	if warnedAt[kind] and now - warnedAt[kind] < 60 then
		return
	end
	warnedAt[kind] = now
	deps.warn(text)
end

-- Text helpers (pure; exported for the tests) -------------------------------------------------------------------------

-- `text` cut to at most `max` bytes without splitting a UTF-8 character.
local function cut(text: string, max: number): string
	if #text <= max then
		return text
	end
	local result = string.sub(text, 1, max)
	for _ = 1, 3 do
		if utf8.len(result) then
			return result
		end
		result = string.sub(result, 1, -2)
	end
	return (string.gsub(result, "[\128-\255]", "?"))
end
Errors.cut = cut

local GENERATION_FOLDERS = { "Generations", "TypeTorchRetry", "TypeTorchResend" }
-- Mount paths name the generation (Generations.<artifact id>#<n>): <gen> instead, so a kind survives swaps.
function Errors.normalize(text: string): string
	for _, folder in GENERATION_FOLDERS do
		text = string.gsub(text, folder .. "%.[%w_%-]+#%d+", folder .. ".<gen>")
	end
	return text
end

local function isWord(byte: number?): boolean
	return byte ~= nil and ((byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95)
end

-- Replaces `needle` where it stands as a whole word (no letter, digit or underscore right before or after it, on the
-- sides where the needle itself starts or ends with one). Returns (text, found).
local function replaceWord(text: string, needle: string, replacement: string): (string, boolean)
	if needle == "" then
		return text, false
	end
	local startsWord, endsWord = isWord(string.byte(needle, 1)), isWord(string.byte(needle, -1))
	local parts, from, search, found = {}, 1, 1, false
	while true do
		local first, last = string.find(text, needle, search, true)
		if not first then
			break
		end
		local before = if first > 1 then string.byte(text, first - 1) else nil
		local after = string.byte(text, last + 1)
		if (not startsWord or not isWord(before)) and (not endsWord or not isWord(after)) then
			table.insert(parts, string.sub(text, from, first - 1))
			table.insert(parts, replacement)
			from, search, found = last + 1, last + 1, true
		else
			search = first + 1
		end
	end
	if not found then
		return text, false
	end
	table.insert(parts, string.sub(text, from))
	return table.concat(parts), true
end

-- Marks (control bytes, which the text no longer holds) keep a later needle from matching inside a replacement.
local MARKS = { name = "\1n\2", display = "\1d\2", id = "\1u\2" }
local TOKENS = { ["\1n\2"] = "<player.name>", ["\1d\2"] = "<player.display_name>", ["\1u\2"] = "<player.user_id>" }
local TOKEN_MARKS = { ["<player.name>"] = MARKS.name, ["<player.display_name>"] = MARKS.display, ["<player.user_id>"] = MARKS.id }

-- The needles for `players` ({ { name, display, id } }): longest first; on equal length a Name before a DisplayName
-- before a UserId (a display name that equals the name is the name).
function Errors.needles(players): { any }
	local list = {}
	local rank = { name = 1, display = 2, id = 3 }
	for _, player in players do
		for _, field in { "name", "display", "id" } do
			local text = player[field]
			if typeof(text) == "string" and #text > 0 and not string.find(text, "%c") then
				table.insert(list, { text = text, mark = MARKS[field], rank = rank[field], userId = player.userId })
			end
		end
	end
	table.sort(list, function(a, b)
		if #a.text ~= #b.text then
			return #a.text > #b.text
		end
		return a.rank < b.rank
	end)
	return list
end

-- `text` (control characters already flattened) with every needle replaced. Returns (template, { [userId] = true }).
function Errors.template(text: string, list): (string, { [any]: boolean })
	local named = {}
	text = string.gsub(text, "<player%.[%a_]+>", TOKEN_MARKS) -- tokens already there stay tokens
	for _, needle in list do
		local replaced, found = replaceWord(text, needle.text, needle.mark)
		if found then
			text = replaced
			if needle.userId ~= nil then
				named[needle.userId] = true
			end
		end
	end
	text = string.gsub(text, "\1[ndu]\2", TOKENS)
	return text, named
end

-- FNV-1a and djb2 (32 bits each, exact in doubles), as 16 hex characters.
function Errors.fingerprint(text: string): string
	local fnv, djb = 2166136261, 5381
	for index = 1, #text do
		local byte = string.byte(text, index)
		fnv = bit32.bxor(fnv, byte)
		fnv = (bit32.lshift(fnv, 24) + fnv * 403) % 4294967296 -- fnv * 16777619 mod 2^32 without losing bits
		djb = (djb * 33 + byte) % 4294967296
	end
	return string.format("%08x%08x", fnv, djb)
end

-- The first non-empty line of a (normalized, templated) stack, trimmed.
function Errors.topLine(stack: string?): string
	if not stack then
		return ""
	end
	for line in string.gmatch(stack, "[^\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" then
			return cut(trimmed, 300)
		end
	end
	return ""
end

-- Flattens control characters (a message: all of them; a stack: all but line breaks).
local function flatten(text: string, keepLines: boolean): string
	if keepLines then
		text = string.gsub(text, "\r\n?", "\n")
		return (string.gsub(text, "%c", function(c)
			return if c == "\n" then "\n" else " "
		end))
	end
	return (string.gsub(text, "%c", " "))
end

-- message, stack -> { template, stack?, top, fp, named }.
function Errors.describe(message: string, stack: string?, list)
	local template, named = Errors.template(Errors.normalize(flatten(message, false)), list)
	template = cut(template, Constants.ERRORS_TEMPLATE_MAX)
	local stackText = nil
	if typeof(stack) == "string" and string.find(stack, "%S") then
		local templated, stackNamed = Errors.template(Errors.normalize(flatten(stack, true)), list)
		for userId in stackNamed do
			named[userId] = true
		end
		stackText = cut(templated, Constants.ERRORS_STACK_MAX)
	end
	local top = Errors.topLine(stackText)
	return { template = template, stack = stackText, top = top, fp = Errors.fingerprint(template .. "\n" .. top), named = named }
end

-- Players -------------------------------------------------------------------------------------------------------------

local function rosterChanged()
	rosterVersion += 1
	needles = nil
end

local function currentNeedles()
	if not needles then
		local players = {}
		for userId, entry in roster do
			table.insert(players, { name = entry.name, display = entry.display, id = entry.id, userId = userId })
		end
		needles = Errors.needles(players)
	end
	return needles
end

function Errors.playerAdded(player)
	local ok, userId, name, display = pcall(function()
		return player.UserId, player.Name, player.DisplayName
	end)
	if not ok or typeof(userId) ~= "number" then
		return
	end
	local entry = roster[userId]
	roster[userId] = {
		name = name,
		display = display,
		-- Studio's test players have negative ids ("-1" is too common a word to replace); real ones are positive.
		id = if userId > 0 then string.format("%d", userId) else nil,
		pid = entry and entry.pid,
	}
	rosterChanged()
end

function Errors.playerRemoving(player)
	local ok, userId = pcall(function()
		return player.UserId
	end)
	local entry = ok and roster[userId]
	if entry then
		entry.leftAt = deps.clock()
	end
	clientAt[player] = nil
end

-- api:setAnalyticsId(player, pid): the framework's analytics engine tells the kernel a player's pid (the pseudonymous
-- analytics id the backend counts players by). Returns whether it was taken.
function Errors.setPid(player, pid): boolean
	if typeof(pid) ~= "string" or #pid == 0 or #pid > 64 or not string.match(pid, "^[%w_%-]+$") then
		return false
	end
	local ok, userId = pcall(function()
		return player.UserId
	end)
	if not ok or typeof(userId) ~= "number" then
		return false
	end
	if not roster[userId] then
		Errors.playerAdded(player)
	end
	local entry = roster[userId]
	if not entry then
		return false
	end
	entry.pid = pid
	return true
end

-- Players who left ERRORS_LEFT_SECONDS ago are forgotten.
local function purgeRoster()
	local now = deps.clock()
	local changed = false
	for userId, entry in roster do
		if entry.leftAt and now - entry.leftAt > Constants.ERRORS_LEFT_SECONDS then
			roster[userId] = nil
			changed = true
		end
	end
	if changed then
		rosterChanged()
	end
end

-- Recording -----------------------------------------------------------------------------------------------------------

local function newKind(fp: string, described, realm: string): boolean
	if kindCount >= Constants.ERRORS_KINDS_MAX then
		-- Full: forget the kind seen longest ago that has nothing waiting.
		local oldest, oldestAt = nil, math.huge
		for key, kind in kinds do
			if kind.waiting == 0 and kind.seenAt < oldestAt then
				oldest, oldestAt = key, kind.seenAt
			end
		end
		if not oldest then
			return false
		end
		kinds[oldest] = nil
		kindCount -= 1
	end
	kinds[fp] = { template = described.template, stack = described.stack, top = described.top, realm = realm, total = 0, seenAt = deps.clock(), stackSent = described.stack == nil, waiting = 0 }
	kindCount += 1
	return true
end

local function addPid(item, pid)
	if typeof(pid) ~= "string" or item.pidSet[pid] or #item.pids >= Constants.ERRORS_PIDS_MAX then
		return
	end
	item.pidSet[pid] = true
	table.insert(item.pids, pid)
end

-- Adds `other` (an item that wasn't sent) back into the waiting items.
local function merge(key: string, other)
	local item = items[key]
	if not item then
		if itemCount >= Constants.ERRORS_ITEMS_MAX then
			stats.dropped.items += other.count
			local kind = kinds[other.fp]
			if kind then
				kind.waiting -= 1
			end
			return
		end
		items[key] = other
		itemCount += 1
		return
	end
	local total = item.count + other.count
	if total > Constants.ERRORS_COUNT_MAX then
		stats.dropped.items += total - Constants.ERRORS_COUNT_MAX
		total = Constants.ERRORS_COUNT_MAX
	end
	item.count = total
	item.firstAt = math.min(item.firstAt, other.firstAt)
	item.lastAt = math.max(item.lastAt, other.lastAt)
	for _, pid in other.pids do
		addPid(item, pid)
	end
	local kind = kinds[other.fp]
	if kind then
		kind.waiting -= 1 -- the merged item no longer waits on its own
	end
end

-- Records `n` occurrences of one error. `realm` "server" | "client"; `info` = { branch?, build?, pid? (the sender's) }.
-- Returns the fingerprint, or nil when it was dropped.
function Errors.record(realm: string, message: any, stack: any, n: number?, info): string?
	n = if typeof(n) == "number" and n == n then math.clamp(math.floor(n), 1, Constants.ERRORS_COUNT_MAX) else 1
	if realm == "client" then
		stats.client += n
	else
		realm = "server"
		stats.server += n
	end
	local now = deps.clock()
	if now - second.at >= 1 then
		second.at, second.count = now, 0
	end
	if second.count >= Constants.ERRORS_RECORD_PER_SECOND then
		stats.dropped.rate += n
		return nil
	end
	second.count += 1
	message = if typeof(message) == "string" then message else tostring(message)
	stack = if typeof(stack) == "string" then stack else nil
	if cacheVersion ~= rosterVersion or cacheSize >= CACHE_MAX then
		table.clear(cache)
		cacheSize, cacheVersion = 0, rosterVersion
	end
	local cacheKey = `{message}\0{stack or ""}`
	local described = cache[cacheKey]
	if not described then
		described = Errors.describe(message, stack, currentNeedles())
		cache[cacheKey] = described
		cacheSize += 1
	end
	local fp = described.fp
	local kind = kinds[fp]
	if not kind then
		if not newKind(fp, described, realm) then
			stats.dropped.kinds += n
			return nil
		end
		kind = kinds[fp]
	elseif kind.stack == nil and described.stack ~= nil then
		kind.stack, kind.stackSent = described.stack, false
	end
	info = if typeof(info) == "table" then info else {}
	local at = deps.nowMs()
	local minute = math.floor(at / 60000)
	local key = `{fp}|{realm}|{info.build or ""}|{info.branch or ""}|{minute}`
	local item = items[key]
	if not item then
		if itemCount >= Constants.ERRORS_ITEMS_MAX then
			stats.dropped.items += n
			return nil
		end
		item = { fp = fp, realm = realm, branch = info.branch, build = info.build, count = 0, firstAt = at, lastAt = at, pids = {}, pidSet = {} }
		items[key] = item
		itemCount += 1
		kind.waiting += 1
	end
	local total = item.count + n
	if total > Constants.ERRORS_COUNT_MAX then
		stats.dropped.items += total - Constants.ERRORS_COUNT_MAX
		total = Constants.ERRORS_COUNT_MAX
	end
	item.count = total
	item.lastAt = at
	kind.total += n
	kind.seenAt = now
	addPid(item, info.pid)
	for userId in described.named do
		local entry = roster[userId]
		if entry then
			addPid(item, entry.pid)
		end
	end
	return fp
end

-- Sources -------------------------------------------------------------------------------------------------------------

-- ScriptContext.Error(message, stack, script): an error from any script on the server.
function Errors.noteScriptError(message, stack, scriptInstance)
	if inHandler then
		return -- an error inside this handler must not loop
	end
	inHandler = true
	pcall(function()
		local text = tostring(message)
		scriptSeen[text] = deps.clock()
		local context = deps.context(scriptInstance) or {}
		Errors.record("server", text, stack, 1, { branch = context.branch, build = context.build })
	end)
	inHandler = false
end

-- LogService error lines: script errors print one too, so each waits half a second and is dropped when ScriptContext
-- reported the same message (either order); the rest (engine errors, module load failures) are recorded.
function Errors.noteLogError(message)
	if #logQueue >= 100 then
		stats.dropped.rate += 1
		return
	end
	table.insert(logQueue, { text = tostring(message), at = deps.clock() })
end

local function processLogQueue()
	local now = deps.clock()
	while #logQueue > 0 and now - logQueue[1].at >= 0.5 do
		local entry = table.remove(logQueue, 1)
		local seen = scriptSeen[entry.text]
		if not (seen and math.abs(seen - entry.at) <= 2) then
			local context = deps.context(nil) or {}
			Errors.record("server", entry.text, nil, 1, { branch = context.branch, build = context.build })
		end
	end
	for text, at in scriptSeen do
		if now - at > 5 then
			scriptSeen[text] = nil
		end
	end
end

-- The artifact id in a generation name ("<artifact id>#<n>"), or nil.
local function buildOf(name: any): string?
	if typeof(name) ~= "string" or #name > 80 then
		return nil
	end
	local id = string.match(name, "^([%w_%-]+)#%d+$") or string.match(name, "^([%w_%-]+)$")
	return if id and #id <= 64 then id else nil
end

-- The kernel client's batch (CHANNEL_ERRORS): { e = { { m, s?, n, g? }, ... }, d = dropped on the client }. Untrusted:
-- one batch per ERRORS_CLIENT_SERVER_GAP s per player (others are dropped and counted), ERRORS_CLIENT_BATCH entries,
-- sizes and counts capped. Returns how many entries were taken.
function Errors.fromClient(player, payload): number
	if typeof(payload) ~= "table" then
		return 0
	end
	local now = deps.clock()
	local entries = if typeof(payload.e) == "table" then payload.e else {}
	local last = clientAt[player]
	if last and now - last < Constants.ERRORS_CLIENT_SERVER_GAP then
		stats.dropped.client += math.min(#entries, Constants.ERRORS_CLIENT_BATCH)
		return 0
	end
	clientAt[player] = now
	if typeof(payload.d) == "number" and payload.d == payload.d then
		stats.dropped.client += math.clamp(math.floor(payload.d), 0, 100000)
	end
	local ok, userId = pcall(function()
		return player.UserId
	end)
	local entry = ok and roster[userId]
	local pid = entry and entry.pid
	local context = deps.context(nil) or {}
	local taken = 0
	for index = 1, math.min(#entries, Constants.ERRORS_CLIENT_BATCH) do
		local raw = entries[index]
		if typeof(raw) == "table" and typeof(raw.m) == "string" and #raw.m > 0 then
			taken += 1
			local count = if typeof(raw.n) == "number" and raw.n == raw.n then math.clamp(math.floor(raw.n), 1, Constants.ERRORS_CLIENT_COUNT_MAX) else 1
			local stack = if typeof(raw.s) == "string" then string.sub(raw.s, 1, Constants.ERRORS_CLIENT_STACK_MAX) else nil
			Errors.record("client", string.sub(raw.m, 1, Constants.ERRORS_CLIENT_MESSAGE_MAX), stack, count, {
				pid = pid,
				build = buildOf(raw.g) or context.build,
				branch = context.branch,
			})
		end
	end
	if #entries > Constants.ERRORS_CLIENT_BATCH then
		stats.dropped.client += #entries - Constants.ERRORS_CLIENT_BATCH
	end
	return taken
end

-- Sending -------------------------------------------------------------------------------------------------------------

local function jittered(seconds: number): number
	local spread = Constants.FLEET_JITTER or 0.25
	return seconds * (1 - spread + 2 * spread * deps.random())
end

local function takeToken(): boolean
	local now = deps.clock()
	local rate = Constants.ERRORS_RATE_PER_MINUTE / 60
	if tokensAt == -math.huge then
		tokensAt = now
	end
	tokens = math.min(2, tokens + (now - tokensAt) * rate)
	tokensAt = now
	if tokens >= 1 then
		tokens -= 1
		return true
	end
	return false
end

local function scrub(text: any, max: number): string
	local value = tostring(text)
	local target = deps.target()
	local token = target and target.token
	if typeof(token) == "string" and token ~= "" then
		local from = 1
		while true do
			local first, last = string.find(value, token, from, true)
			if not first then
				break
			end
			value = string.sub(value, 1, first - 1) .. "<key>" .. string.sub(value, last + 1)
			from = first + 5
		end
	end
	return cut((string.gsub(value, "%c", " ")), max)
end

local function outageLine(text: string)
	local now = deps.clock()
	if now - outage.loggedAt < (Constants.FLEET_LOG_GAP or 60) then
		return
	end
	outage.loggedAt = now
	deps.warn(text)
end

local function hintFor(code: number?, errorText: string?): string
	local text = errorText or ""
	if code == 401 or code == 403 then
		return "the backend key is wrong (settings.backend.key: run typetorch backend setup)"
	elseif code == 404 then
		return "no /v1/errors at this URL (an older backend? check settings.backend.url)"
	elseif code == 530 or string.find(text, "DnsResolve", 1, true) then
		return "the host doesn't resolve: a stale trycloudflare URL? (restart the backend, then typetorch backend setup)"
	elseif string.find(text, "NetFail", 1, true) then
		return "the connection broke mid-request (a restarting quick tunnel?)"
	elseif code == 429 then
		return "the backend rate-limits this server"
	elseif code == 413 then
		return "the batch was too large"
	elseif typeof(code) == "number" and code >= 500 then
		return "the backend failed"
	elseif typeof(code) == "number" then
		return "the backend refused the batch"
	end
	return "no answer"
end

-- The waiting items as one batch: oldest first, at most batchMax items and ERRORS_BATCH_BYTES of JSON. Items too old for
-- the backend are dropped. Returns ({ v, j, errors }, taken = { [key] = item }, stacks = { [fp] = true }).
function Errors.buildBatch()
	local now = deps.nowMs()
	local keys = {}
	for key, item in items do
		if now - item.lastAt > Constants.ERRORS_MAX_AGE * 1000 then
			items[key] = nil
			itemCount -= 1
			stats.dropped.old += item.count
			local kind = kinds[item.fp]
			if kind then
				kind.waiting -= 1
			end
		else
			table.insert(keys, key)
		end
	end
	table.sort(keys, function(a, b)
		return items[a].firstAt < items[b].firstAt
	end)
	local list, taken, stacks = {}, {}, {}
	local bytes = 64
	for _, key in keys do
		if #list >= batchMax then
			break
		end
		local item = items[key]
		local kind = kinds[item.fp]
		local entry = {
			fp = item.fp,
			template = if kind then kind.template else "?",
			count = item.count,
			firstAt = item.firstAt,
			lastAt = item.lastAt,
			realm = item.realm,
			branch = item.branch,
			build = item.build,
			pids = if #item.pids > 0 then table.clone(item.pids) else nil,
		}
		if kind and not kind.stackSent and kind.stack and not stacks[item.fp] then
			entry.stack = kind.stack
		end
		local ok, text = pcall(deps.encode, entry)
		if ok then
			if bytes + #text + 1 > Constants.ERRORS_BATCH_BYTES and #list > 0 then
				break
			end
			bytes += #text + 1
			table.insert(list, entry)
			taken[key] = item
			if entry.stack then
				stacks[item.fp] = true
			end
		end
	end
	return { v = 1, j = deps.jobId, errors = list }, taken, stacks
end

-- Takes the batch's items out of the waiting set (new errors meanwhile start new items).
local function detach(taken)
	for key in taken do
		if items[key] then
			items[key] = nil
			itemCount -= 1
		end
	end
end

-- Puts a batch that didn't go out back (merged with what arrived meanwhile).
local function restore(taken)
	for key, item in taken do
		merge(key, item)
	end
end

local function settle(taken, stacks)
	for _, item in taken do
		local kind = kinds[item.fp]
		if kind then
			kind.waiting -= 1
		end
	end
	for fp in stacks do
		local kind = kinds[fp]
		if kind then
			kind.stackSent = true
		end
	end
end

local function noteSuccess()
	if outage.failures > 0 then
		local seconds = if outage.since then math.floor(deps.clock() - outage.since + 0.5) else 0
		deps.print(`[TypeTorch] error reports: posting works again (after {outage.failures} failed request(s) in {seconds} s)`)
	end
	outage.failures, outage.cycles, outage.untilAt, outage.since, outage.reason = 0, 0, 0, nil, nil
	retry = 0
end

local function noteFailure(reason: string)
	stats.failed += 1
	stats.lastErrorAt = os.time()
	outage.failures += 1
	outage.since = outage.since or deps.clock()
	outage.reason = reason
end

-- A batch and its retries all failed (or a 401/403/404 / 429): nothing goes out until the wait ends.
local function noteFailedCycle(code: number?, errorText: string?, retryAfter: number?)
	local hold = code == 401 or code == 403 or code == 404
	outage.cycles += 1
	retry = 0
	local wait
	if hold then
		wait = jittered(Constants.FLEET_AUTH_HOLD or 300)
	elseif code == 429 and retryAfter then
		wait = math.clamp(retryAfter, 1, Constants.FLEET_BACKOFF_MAX or 300)
	else
		wait = jittered(math.min(Constants.FLEET_BACKOFF_MAX or 300, Constants.FLEET_HEARTBEAT_SECONDS * 2 ^ (outage.cycles - 1)))
	end
	outage.untilAt = deps.clock() + wait
	local target = deps.target()
	local host = if target then target.host else "?"
	outageLine(`[TypeTorch] error reports: backend {host} {if hold then "refused" else "unreachable"} ({outage.reason or "?"}): {hintFor(code, errorText)}; {outage.failures} failed request(s) in a row, next try in {math.ceil(wait)} s`)
end

local function header(headers, name: string): string?
	if typeof(headers) ~= "table" then
		return nil
	end
	for key, value in headers do
		if typeof(key) == "string" and string.lower(key) == name and typeof(value) == "string" then
			return value
		end
	end
	return nil
end

-- One POST of `body`. Returns (ok, code?, errorText?, answer?, retryAfter?).
local function post(body)
	local target = deps.target()
	if not target then
		return false, nil, "no backend settings"
	end
	local encodedOk, encoded = pcall(deps.encode, body)
	if not encodedOk then
		return false, 400, `the batch can't be encoded: {scrub(encoded, 120)}`
	end
	local request = {
		Url = target.url .. Constants.ERRORS_PATH,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. target.token },
		Body = encoded,
	}
	if deps.gzip and #encoded > 1024 then
		request.Compress = deps.gzip
	end
	stats.requests += 1
	local ok, response = pcall(deps.http.RequestAsync, deps.http, request)
	if not ok then
		local text = scrub(response, 200)
		stats.lastError, stats.lastStatus = text, nil
		noteFailure(text)
		return false, nil, text
	end
	local code = if typeof(response) == "table" and typeof(response.StatusCode) == "number" then response.StatusCode else nil
	stats.lastStatus = code
	if typeof(response) == "table" and response.Success == true then
		local answer = nil
		if deps.decode and typeof(response.Body) == "string" and #response.Body > 0 then
			local decoded, value = pcall(deps.decode, response.Body)
			answer = if decoded and typeof(value) == "table" then value else nil
		end
		return true, code, nil, answer
	end
	stats.lastError = `HTTP {tostring(code)}`
	noteFailure(`HTTP {tostring(code)}`)
	local retryAfter = tonumber(header(response.Headers, "retry-after") or "")
	return false, code, stats.lastError, nil, retryAfter
end

-- One step of the sender: a batch when one is due. Returns whether it posted (or tried).
function Errors.step(): boolean
	processLogQueue()
	purgeRoster()
	if not deps.active or closed or itemCount == 0 or not deps.target() then
		return false
	end
	local now = deps.clock()
	if now < outage.untilAt or now < nextFlushAt then
		return false
	end
	if not takeToken() then
		return false
	end
	local body, taken, stacks = Errors.buildBatch()
	if #body.errors == 0 then
		return false
	end
	detach(taken)
	nextFlushAt = now + jittered(Constants.ERRORS_FLUSH_SECONDS)
	local ok, code, errorText, answer, retryAfter = post(body)
	if ok then
		settle(taken, stacks)
		local accepted = if answer and typeof(answer.accepted) == "number" then answer.accepted else #body.errors
		local rejected = if answer and typeof(answer.rejected) == "number" then answer.rejected else 0
		stats.sent += accepted
		stats.rejected += rejected
		stats.lastOkAt = os.time()
		if rejected > 0 then
			local why = if answer and typeof(answer.errors) == "table" and typeof(answer.errors[1]) == "string" then `: {scrub(answer.errors[1], 120)}` else ""
			warnOnce("rejected", `[TypeTorch] error reports: the backend refused {rejected} item(s){why}`)
		end
		noteSuccess()
		batchMax = math.min(Constants.ERRORS_BATCH_MAX, batchMax * 2)
		return true
	end
	if code == 413 and #body.errors > 1 then
		-- Too large: half the size, at once (the items go back).
		restore(taken)
		batchMax = math.max(1, math.floor(#body.errors / 2))
		nextFlushAt = now
		return true
	end
	if typeof(code) == "number" and code >= 400 and code < 500 and code ~= 401 and code ~= 403 and code ~= 404 and code ~= 429 then
		-- The backend is up and refused this batch (400, a 413 of one item): dropped, no backoff.
		settle(taken, stacks)
		stats.rejected += #body.errors
		outageLine(`[TypeTorch] error reports: the backend answered {code}: {hintFor(code, errorText)}; {#body.errors} item(s) dropped`)
		return true
	end
	restore(taken)
	local again = code == nil or code == 429 or code >= 500
	if again and code ~= 429 and retry < #Constants.FLEET_RETRY_DELAYS then
		retry += 1
		nextFlushAt = deps.clock() + jittered(Constants.FLEET_RETRY_DELAYS[retry])
		tokens = math.min(2, tokens + 1) -- a retry doesn't spend the minute's budget
		return true
	end
	noteFailedCycle(code, errorText, retryAfter)
	return true
end

-- Starts the sources and the sender thread (once). `sources` = { scriptContext, logService } (the kernel passes the
-- services; nil under tests).
function Errors.start(sources)
	if started then
		return
	end
	started = true
	sources = sources or {}
	if sources.scriptContext then
		sources.scriptContext.Error:Connect(Errors.noteScriptError)
	end
	if sources.logService then
		sources.logService.MessageOut:Connect(function(message, messageType)
			if messageType == Enum.MessageType.MessageError then
				Errors.noteLogError(message)
			end
		end)
	end
	if sources.players then
		for _, player in sources.players:GetPlayers() do
			Errors.playerAdded(player)
		end
		sources.players.PlayerAdded:Connect(Errors.playerAdded)
		sources.players.PlayerRemoving:Connect(Errors.playerRemoving)
	end
	task.spawn(function()
		while not closed do
			local ok, problem = pcall(Errors.step)
			if not ok then
				warnOnce("step", `[TypeTorch] error reports: {scrub(problem, 200)}`)
			end
			task.wait(0.5)
		end
	end)
end

-- BindToClose: one last batch (yields up to the request), then nothing more.
function Errors.closing()
	if closed then
		return
	end
	processLogQueue()
	if deps.active and itemCount > 0 and deps.target() and deps.clock() >= outage.untilAt then
		nextFlushAt, tokens = 0, math.max(tokens, 1)
		pcall(Errors.step)
	end
	closed = true
end

-- status().errors (the dev menu): never the key, never a raw message (templates only).
function Errors.info()
	local target = deps.target()
	local top = {}
	for fp, kind in kinds do
		table.insert(top, { fp = fp, template = cut(kind.template, 160), total = kind.total, realm = kind.realm })
	end
	table.sort(top, function(a, b)
		return a.total > b.total
	end)
	while #top > 5 do
		table.remove(top)
	end
	local now = deps.clock()
	return {
		enabled = deps.active and target ~= nil,
		host = target and target.host,
		kinds = kindCount,
		waiting = itemCount,
		seen = { server = stats.server, client = stats.client },
		sent = stats.sent,
		requests = stats.requests,
		failed = stats.failed,
		rejected = stats.rejected,
		dropped = table.clone(stats.dropped),
		failures = outage.failures,
		retryIn = if outage.untilAt > now then math.ceil(outage.untilAt - now) else nil,
		lastOkAt = stats.lastOkAt,
		lastError = stats.lastError,
		lastErrorAt = stats.lastErrorAt,
		lastStatus = stats.lastStatus,
		top = top,
	}
end

-- Tests: forget everything.
function Errors._reset()
	table.clear(roster)
	rosterChanged()
	table.clear(cache)
	cacheSize, cacheVersion = 0, -1
	table.clear(kinds)
	kindCount = 0
	table.clear(items)
	itemCount = 0
	table.clear(logQueue)
	table.clear(scriptSeen)
	table.clear(clientAt)
	second.at, second.count = -math.huge, 0
	tokens, tokensAt = 2, -math.huge
	batchMax = Constants.ERRORS_BATCH_MAX
	started, closed, inHandler = false, false, false
	nextFlushAt, retry = 0, 0
	stats.server, stats.client, stats.sent, stats.requests, stats.failed, stats.rejected = 0, 0, 0, 0, 0, 0
	stats.dropped = { kinds = 0, items = 0, rate = 0, old = 0, client = 0 }
	stats.lastOkAt, stats.lastError, stats.lastErrorAt, stats.lastStatus = nil, nil, nil, nil
	outage.failures, outage.cycles, outage.untilAt, outage.since, outage.reason, outage.loggedAt = 0, 0, 0, nil, nil, -math.huge
	table.clear(warnedAt)
end

return Errors
