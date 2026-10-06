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

function Logs.start()
	LogService.MessageOut:Connect(function(message, messageType)
		entries[(nextIndex - 1) % CAPACITY + 1] = {
			i = nextIndex,
			t = os.time(),
			kind = TYPES[messageType] or "output",
			text = string.sub(message, 1, 2000),
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
