--!nonstrict
-- TypeTorch kernel: the HEALTH WINDOW (P-F1, kernel 0.3.2; moved here and made configurable per build in 0.3.7).
-- Design: plans/01 "Bad deploys are safe" and "Health thresholds per build".
--
-- A generation is unhealthy when, from its mount until `window` seconds after ready, the framework reports a failed
-- onStart (api:reportError), or its own scripts (inside its server tree, or its Entry clone) raise `errors` errors. It is
-- then rolled back to the last known good artifact and marked failed here (the kernel's healthRollback). Errors from
-- anything outside the generation (the kernel, place scripts, other generations, a generation being stopped) never
-- count. After the window errors are only counted ("degraded").
--
-- 0.3.7: the thresholds come from the build. `typetorch build` stamps typetorch.json "health" on the payload root:
-- HealthErrors (1-100), HealthWindow (5-300 s) and HealthRollback (false: count, never roll back). A missing or
-- out-of-bounds value falls back to Constants (HEALTH_ERRORS, HEALTH_WINDOW, rollback on) and is listed in
-- status().health.invalid. Prod payloads are signed deploys of the owner's uploads, so the values are trusted like the
-- code. Why: a migrated game with harmless noisy errors hit 3 errors on every server at once, every server rolled back
-- and `deploy --wait` rolled the branch back (plans/17 blocker 5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptContext = game:GetService("ScriptContext")

local Constants = require(ReplicatedStorage:WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Health = {}

-- Set by the kernel (Health.configure).
local deps = {
	current = function()
		return nil -- the running generation
	end,
	starting = function()
		return nil -- the generation being started (its scripts' errors count from its mount)
	end,
	closing = function()
		return false
	end,
	localMode = function()
		return false -- a Studio local payload: errors are counted, the dev's own code is never swapped for an upload
	end,
	failing = function()
		return false -- a deploy failed here (P-K2): the server is degraded
	end,
	rollback = function(_generation, _why) end, -- runs the kernel's healthRollback on a kernel thread
	alert = function(_level, _code, _message, _head) end, -- a fleet API alert
	noteLastError = function(_text) end, -- the fleet status `e`
	logError = function(_text) end, -- an error line that never counts (raised on a kernel thread)
	clip = function(text, _max)
		return if text == nil then nil else tostring(text)
	end,
}

function Health.configure(options)
	for key, value in options do
		deps[key] = value
	end
end

-- Assets restarted after a health rollback found nothing else to run: no second window (it would loop).
local exempt: { [number]: boolean } = {}
-- The last health-window rollback on this server: { from, to?, why, at }.
local lastRollback = nil
-- Errors of the running generation in the last 60 s (os.clock), for the fleet API's error_spike alert.
local recentErrors: { number } = {}
local reportsLogged = 0

-- Thresholds ---------------------------------------------------------------------------------------------------------

local function whole(value): boolean
	return typeof(value) == "number" and value == value and value % 1 == 0
end

-- The thresholds `payload` (its root) carries: { errors, window, rollback, source = "payload" | "default", invalid? }.
-- Each value is checked on its own; a missing one, or one of the wrong type or out of bounds, is the default.
function Health.config(payload: Instance?)
	local config = { errors = Constants.HEALTH_ERRORS, window = Constants.HEALTH_WINDOW, rollback = true, source = "default" }
	if payload == nil then
		return config
	end
	local invalid = {}
	local errors = payload:GetAttribute("HealthErrors")
	if errors ~= nil then
		local low, high = Constants.HEALTH_ERRORS_MIN, Constants.HEALTH_ERRORS_MAX
		if whole(errors) and errors >= low and errors <= high then
			config.errors = errors
			config.source = "payload"
		else
			table.insert(invalid, `HealthErrors {deps.clip(errors, 40)} (a whole number {low}-{high})`)
		end
	end
	local window = payload:GetAttribute("HealthWindow")
	if window ~= nil then
		local low, high = Constants.HEALTH_WINDOW_MIN, Constants.HEALTH_WINDOW_MAX
		if typeof(window) == "number" and window == window and window >= low and window <= high then
			config.window = window
			config.source = "payload"
		else
			table.insert(invalid, `HealthWindow {deps.clip(window, 40)} (seconds, {low}-{high})`)
		end
	end
	local rollback = payload:GetAttribute("HealthRollback")
	if rollback ~= nil then
		if typeof(rollback) == "boolean" then
			config.rollback = rollback
			config.source = "payload"
		else
			table.insert(invalid, `HealthRollback {deps.clip(rollback, 40)} (true or false)`)
		end
	end
	if #invalid > 0 then
		config.invalid = invalid
	end
	return config
end

-- A new generation's health table, with the thresholds its payload carries. `name` (the artifact id) is for the warning.
function Health.forPayload(payload: Instance?, name: string?)
	local config = Health.config(payload)
	if config.invalid then
		warn(`[TypeTorch] {name or "artifact"}: health settings out of bounds, defaults used for: {table.concat(config.invalid, ", ")}`)
	end
	return {
		errors = 0,
		startFailed = nil,
		lastError = nil,
		lastErrorAt = nil,
		readyAt = nil, -- os.clock() when it called ready(); the window runs `window` seconds from here
		failed = nil, -- why it failed its check (it is being, or couldn't be, rolled back)
		kept = nil, -- 0.3.7: why it failed its check while its build turned the rollback off (it keeps running)
		limit = config.errors,
		window = config.window,
		rollback = config.rollback,
		source = config.source,
		invalid = config.invalid,
	}
end

-- Errors -------------------------------------------------------------------------------------------------------------

-- Whether `scriptInstance` belongs to `generation` (its server tree, or its Entry clone and what it holds).
local function owns(generation, scriptInstance): boolean
	if not generation or generation.stopping then
		return false
	end
	local ok, inside = pcall(function()
		local entry = generation.entry
		if entry and (scriptInstance == entry or scriptInstance:IsDescendantOf(entry)) then
			return true
		end
		return scriptInstance:IsDescendantOf(generation.serverTree)
	end)
	return ok and inside == true
end

-- The running or starting generation `scriptInstance` belongs to, or nil.
function Health.generationOf(scriptInstance)
	if typeof(scriptInstance) ~= "Instance" then
		return nil
	end
	local current = deps.current()
	if owns(current, scriptInstance) then
		return current
	end
	local starting = deps.starting()
	if owns(starting, scriptInstance) then
		return starting
	end
	return nil
end

-- Rolls the running generation back when its health check failed inside the window (once per generation). Its build
-- may turn the rollback off (0.3.7): then the failure is only warned about once and reported as "degraded".
function Health.check(generation)
	local health = generation.health
	if generation ~= deps.current() or health.failed or health.readyAt == nil or deps.closing() or exempt[generation.artifact.assetId] then
		return
	end
	if deps.localMode() then
		return -- a Studio local payload: errors are counted, the dev's own code is never swapped for an upload
	end
	if os.clock() > health.readyAt + health.window then
		return -- after the window: counted (status, fleet status "degraded"), never rolled back
	end
	local why = nil
	if health.startFailed then
		why = `onStart failed: {health.startFailed}`
	elseif health.errors >= health.limit then
		why = `{health.errors} errors within {health.window} s of ready, last: {health.lastError}`
	end
	if not why then
		return
	end
	if not health.rollback then
		if not health.kept then
			health.kept = why
			warn(`[TypeTorch] {generation.name} failed its health check ({why}); its build turns the health rollback off (HealthRollback = false), so it keeps running`)
		end
		return
	end
	health.failed = why
	deps.rollback(generation, why)
end

-- One error of `generation` (its own scripts, or a hook the framework reported). `startFailed`: a failed onStart.
function Health.noteError(generation, message: string, startFailed: boolean?)
	local health = generation.health
	local text = deps.clip(message, 200)
	health.lastError = text
	health.lastErrorAt = os.time()
	deps.noteLastError(text)
	local now = os.clock()
	table.insert(recentErrors, now)
	while #recentErrors > 0 and now - recentErrors[1] > 60 do
		table.remove(recentErrors, 1)
	end
	if #recentErrors >= Constants.FLEET_ERROR_SPIKE then
		deps.alert("warning", "error_spike", `{#recentErrors} errors in 60 s from {generation.name}, last: {text}`, generation.head)
	end
	if startFailed then
		health.startFailed = health.startFailed or text
	else
		health.errors += 1
	end
	Health.check(generation)
end

-- Api: the framework reports a failed lifecycle hook ({kind = "onStart" | ..., module, message}). A failed onStart is
-- a health failure; anything else counts as one error. The kernel prints it as an error line from its own thread (so
-- it doesn't count twice). Returns whether it was taken.
function Health.reportError(generation, info): boolean
	if typeof(info) ~= "table" or generation.stopping or (generation ~= deps.current() and generation ~= deps.starting()) then
		return false
	end
	local kind = if typeof(info.kind) == "string" then deps.clip(info.kind, 40) else "error"
	local module = if typeof(info.module) == "string" then deps.clip(info.module, 80) else "?"
	local message = deps.clip(if info.message ~= nil then tostring(info.message) else "?", 2000)
	if reportsLogged < 200 then
		reportsLogged += 1
		deps.logError(`[TypeTorch] {module}.{kind} failed: {message}`)
	end
	Health.noteError(generation, `{module}.{kind}: {message}`, kind == "onStart")
	return true
end

-- Counts ScriptContext errors from the running (or starting) generation's own scripts.
function Health.start()
	ScriptContext.Error:Connect(function(message, _trace, scriptInstance)
		local generation = Health.generationOf(scriptInstance)
		if generation then
			Health.noteError(generation, tostring(message))
		end
	end)
end

-- Rollbacks ----------------------------------------------------------------------------------------------------------

-- An asset restarted without a window (nothing else could run after its health rollback), or cleared (nil).
function Health.exempt(assetId: any, on: boolean?)
	if typeof(assetId) == "number" then
		exempt[assetId] = if on then true else nil
	end
end

-- Records the last health-window rollback: { from, to?, why, at }.
function Health.rolledBack(record)
	lastRollback = record
end

-- State --------------------------------------------------------------------------------------------------------------

-- "ok" | "failed" (nothing runs) | "unverified" (boot fail-safe) | "backup" (0.3.6: the backup baked into the place) |
-- "degraded" (a deploy failed here, or the running generation failed its check or keeps erroring). The fleet status `h`.
function Health.state(): string
	local current = deps.current()
	if not current then
		return "failed"
	end
	if current.unverified then
		return "unverified"
	end
	if current.backup then
		return "backup"
	end
	local health = current.health
	if deps.failing() or health.failed or health.startFailed or health.errors >= (health.limit or Constants.HEALTH_ERRORS) then
		return "degraded" -- (a failed onStart after the window too: that module isn't running)
	end
	return "ok"
end

-- status().health: { state, errors, limit?, window?, rollback?, source?, invalid?, lastError?, lastErrorAt?,
-- startFailed?, failed?, kept?, windowLeft? (seconds of the window left), lastRollback? = { from, to?, why, at } }.
-- `limit`/`window`/`rollback` (0.3.7) are the running build's thresholds; `rollback` is false where nothing would roll
-- back (the build turned it off, a Studio local payload, or a build restarted after nothing else could run).
function Health.info()
	local info = { state = Health.state(), errors = 0, lastRollback = if lastRollback then table.clone(lastRollback) else nil }
	local current = deps.current()
	if current then
		local health = current.health
		local exempted = exempt[current.artifact.assetId] == true
		info.errors = health.errors
		info.limit = health.limit
		info.window = health.window
		info.rollback = health.rollback == true and not exempted and not deps.localMode()
		info.source = health.source
		info.invalid = if health.invalid then table.clone(health.invalid) else nil
		info.lastError = health.lastError
		info.lastErrorAt = health.lastErrorAt
		info.startFailed = health.startFailed
		info.failed = health.failed
		info.kept = health.kept
		if health.readyAt and not health.failed and not exempted then
			local left = health.readyAt + health.window - os.clock()
			info.windowLeft = if left > 0 then math.ceil(left) else nil
		end
	end
	return info
end

return Health
