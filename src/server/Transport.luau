--!nonstrict
-- Stable remotes owned by the kernel. They never change across generation swaps, so clients never lose them.
--
--   client -> server   Net:FireServer(artifactId, channel, ...)
--   server -> client   Net:FireClient(player, artifactId, channel, ...)
--
-- Messages tagged with another artifact than the running generation's are dropped and answered with a resync notice
-- (the client is between generations). The framework owns guards, rate limits per channel and request/response; the
-- kernel only routes and applies a coarse per-player budget so it can't be flooded.

local Players = game:GetService("Players")
local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("TypeTorchKernelShared"):WaitForChild("Constants"))

local Transport = {}

local root: Instance = nil
local net: RemoteEvent = nil
local netU: UnreliableRemoteEvent = nil

local acceptArtifact: string? = nil
local handler: ((Player, string, ...any) -> ())? = nil

-- Per-player token bucket over every message: [tokens, last refill].
local BURST, RATE = 120, 60
local buckets: { [Player]: { number } } = {}
local function allow(player: Player): boolean
	local now = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { BURST, now }
		buckets[player] = bucket
	end
	bucket[1] = math.min(BURST, bucket[1] + (now - bucket[2]) * RATE)
	bucket[2] = now
	if bucket[1] < 1 then
		return false
	end
	bucket[1] -= 1
	return true
end

local function onServerEvent(player: Player, artifactId: any, channel: any, ...)
	if typeof(channel) ~= "string" or #channel > 120 or not allow(player) then
		return
	end
	if handler and artifactId == acceptArtifact then
		task.spawn(handler, player, channel, ...)
	elseif acceptArtifact then
		net:FireClient(player, acceptArtifact, Constants.CHANNEL_RESYNC)
	end
end

function Transport.start(parent: Instance)
	root = parent
	net = Instance.new("RemoteEvent")
	net.Name = "Net"
	net.Parent = root
	netU = Instance.new("UnreliableRemoteEvent")
	netU.Name = "NetU"
	netU.Parent = root
	net.OnServerEvent:Connect(onServerEvent)
	netU.OnServerEvent:Connect(onServerEvent)
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
end

-- The running generation's inbound handler. Only messages tagged with `artifactId` reach it.
function Transport.attach(artifactId: string, fn: (Player, string, ...any) -> ())
	acceptArtifact = artifactId
	handler = fn
end

function Transport.detach()
	handler = nil
end

function Transport.current(): string?
	return acceptArtifact
end

function Transport.send(player: Player, channel: string, ...)
	net:FireClient(player, acceptArtifact, channel, ...)
end

function Transport.broadcast(channel: string, ...)
	net:FireAllClients(acceptArtifact, channel, ...)
end

function Transport.sendUnreliable(player: Player, channel: string, ...)
	netU:FireClient(player, acceptArtifact, channel, ...)
end

function Transport.broadcastUnreliable(channel: string, ...)
	netU:FireAllClients(acceptArtifact, channel, ...)
end

-- Kernel-internal messages (notices, dev status, events) bypass the generation tag check on the client.
function Transport.kernelSend(player: Player, channel: string, ...)
	net:FireClient(player, "*", channel, ...)
end

return Transport
