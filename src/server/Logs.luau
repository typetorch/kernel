--!nonstrict
-- Ring buffer of this server's output since boot (LogService.MessageOut), for the dev menu's Logs tab.
-- Lives in the kernel so it survives generation swaps and still holds the errors of a generation that failed.

local LogService = game:GetService("LogService")

local Logs = {}

local CAPACITY = 500
local entries = {}
local nextIndex = 1

local TYPES = {
	[Enum.MessageType.MessageOutput] = "output",
	[Enum.MessageType.MessageInfo] = "info",
	[Enum.MessageType.MessageWarning] = "warning",
	[Enum.MessageType.MessageError] = "error",
}

-- 0.3.5: the engine warns 'ConfigService: Config value not found for key "<key>".' when a key nobody published is
-- read. TypeTorch's keys are optional ("TypeTorch", the registry, is never written with an API key; "TypeTorchFleet"
-- and the framework's "TypeTorchAnalytics" only once set up), so in this ring that warning becomes ONE info line per
-- key ("[TypeTorch] no ConfigService registry (optional)"; the dev menu shows kernel notes dim) and repeats are
-- dropped. Other keys (the game's own) stay as they are. Roblox's own console still prints the engine's line: game
-- code can't silence it.
local OPTIONAL_KEYS = {
	TypeTorch = "no ConfigService registry (optional)",
	TypeTorchFleet = "no ConfigService key TypeTorchFleet (optional: the fleet API is off)",
	TypeTorchAnalytics = "no ConfigService key TypeTorchAnalytics (optional: analytics settings come later or from code)",
	-- 0.3.6 (plans/18): the dev lists; without it they come from the registry (only the creator, in practice).
	TypeTorchAccess = "no ConfigService key TypeTorchAccess (optional: run typetorch access push)",
}
local noted: { [string]: boolean } = {}

-- (text, kind) to record, or nil to drop the line.
function Logs.rewrite(message: string, kind: string): (string?, string?)
	if kind ~= "warning" then
		return message, kind
	end
	local key = string.match(message, 'Config value not found for key "([%w_]+)"')
	if not key or string.sub(key, 1, 9) ~= "TypeTorch" then
		return message, kind
	end
	if noted[key] then
		return nil, nil
	end
	noted[key] = true
	return `[TypeTorch] {OPTIONAL_KEYS[key] or `no ConfigService key {key} (optional)`}`, "info"
end

function Logs.start()
	LogService.MessageOut:Connect(function(message, messageType)
		local text, kind = Logs.rewrite(message, TYPES[messageType] or "output")
		if not text then
			return
		end
		entries[(nextIndex - 1) % CAPACITY + 1] = {
			i = nextIndex,
			t = os.time(),
			kind = kind,
			text = string.sub(text, 1, 2000),
		}
		nextIndex += 1
	end)
end

-- Entries with index > since, oldest first (at most `limit`).
function Logs.since(since: number?, limit: number?)
	local from = math.max((since or 0) + 1, nextIndex - CAPACITY)
	local to = nextIndex - 1
	if limit then
		from = math.max(from, to - limit + 1)
	end
	local result = {}
	for index = from, to do
		local entry = entries[(index - 1) % CAPACITY + 1]
		if entry and entry.i == index then
			table.insert(result, entry)
		end
	end
	return result
end

return Logs
