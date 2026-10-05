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
-- 0.3.2 (audit P-N1): the network protocol hash of recent generations (the payload's ProtocolHash attribute), by
-- artifact id. A client message tagged with an older artifact whose hash equals the running one's is the same
-- protocol (a client mid-swap): it reaches the running generation instead of being dropped. No hash, no match.
local acceptProtocol: string? = nil
local protocols: { [string]: string } = {}
local protocolOrder: { string } = {}
-- 0.3.2: kernel channels clients send to (tagged "*" instead of an artifact id), e.g. __tt/client (P-K7).
local kernelHandlers: { [string]: (Player, ...any) -> () } = {}

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
	if artifactId == "*" then
		-- Kernel channels only (__tt/...); the generation never sees "*" messages.
		local kernelHandler = kernelHandlers[channel]
		if kernelHandler then
			task.spawn(kernelHandler, player, ...)
		end
		return
	end
	-- Only events ("e:" channels, fire-and-forget): a request's reply is tagged with the running artifact, which the old
	-- client generation drops, so a request would take effect without an answer. Requests get the resync instead (the
	-- client fails them at once and the next try reaches the new generation).
	local sameProtocol = acceptProtocol ~= nil
		and typeof(artifactId) == "string"
		and protocols[artifactId] == acceptProtocol
		and string.sub(channel, 1, 2) == "e:"
	if handler and (artifactId == acceptArtifact or sameProtocol) then
		task.spawn(handler, player, channel, ...)
	elseif acceptArtifact then
		-- 0.3.2: names the artifact whose message was dropped, so only that client generation rejects its pending calls.
		net:FireClient(player, acceptArtifact, Constants.CHANNEL_RESYNC, if typeof(artifactId) == "string" then string.sub(artifactId, 1, 120) else nil)
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

-- The running generation's inbound handler. Only messages tagged with `artifactId` reach it, and (0.3.2) messages
-- tagged with a recent artifact of the same non-empty `protocolHash`.
function Transport.attach(artifactId: string, fn: (Player, string, ...any) -> (), protocolHash: string?)
	acceptArtifact = artifactId
	handler = fn
	acceptProtocol = if typeof(protocolHash) == "string" and protocolHash ~= "" then protocolHash else nil
	if acceptProtocol and protocols[artifactId] == nil then
		protocols[artifactId] = acceptProtocol
		table.insert(protocolOrder, artifactId)
		while #protocolOrder > 5 do
			protocols[table.remove(protocolOrder, 1)] = nil
		end
	end
end

function Transport.detach()
	handler = nil
end

-- 0.3.2: a kernel handler for client messages tagged "*" on `channel` (a "__tt/" channel). Untrusted input.
function Transport.onKernel(channel: string, fn: (Player, ...any) -> ())
	kernelHandlers[channel] = fn
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

function Transport.kernelBroadcast(channel: string, ...)
	net:FireAllClients("*", channel, ...)
end

return Transport
