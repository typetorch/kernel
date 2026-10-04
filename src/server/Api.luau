--!nonstrict
-- The kernel side of the generation contract (server). Each cloned Entry script calls `forEntry(script)` and passes
-- the result to the payload's `Server.boot.boot(kernel)`. The TypeScript view of this object is
-- `ServerKernel` in @typetorch/framework (src/kernel.ts); keep them in sync and bump KERNEL_API on breaking changes.
-- Methods use `:` because roblox-ts calls interface methods with `:`.

local Api = {}

local persistStore: { [string]: any } = {}
local entries: { [Script]: any } = {}
local services = nil -- set by the kernel: { Access, Transport, Logs, status, branchList, artifacts, reload, rollback,
-- switchBranch, pinArtifact, newServer }

function Api.init(kernelServices)
	services = kernelServices
end

function Api.register(entry: Script, generation)
	entries[entry] = generation
end

function Api.unregister(entry: Script)
	entries[entry] = nil
end

function Api.forEntry(entry: Script)
	local generation = entries[entry]
	assert(generation, "Entry was not registered by the kernel")
	local api = {
		kernelApi = services.KERNEL_API,
		kernelVersion = services.KERNEL_VERSION,
		artifact = table.clone(generation.artifact),
		generation = generation.number,
		branch = generation.branch,
		channel = generation.channel,
		serverType = services.serverType(),
	}

	-- State that survives swaps. Plain data or kernel-owned handles only.
	function api:persist(key: string, init: () -> any)
		local value = persistStore[key]
		if value == nil then
			value = init()
			persistStore[key] = value
		end
		return value
	end

	-- Access (plans/10).
	function api:isDev(player: Player): boolean
		return services.Access.isDev(player)
	end
	function api:devInfo(player: Player)
		local dev, reason, role = services.Access.check(player)
		return { dev = dev, reason = reason, role = role }
	end

	-- Transport: only the running generation's handler receives messages.
	function api:onMessage(fn)
		services.Transport.attach(generation.artifact.id, fn)
	end
	function api:send(player: Player, channel: string, ...)
		services.Transport.send(player, channel, ...)
	end
	function api:broadcast(channel: string, ...)
		services.Transport.broadcast(channel, ...)
	end
	function api:sendUnreliable(player: Player, channel: string, ...)
		services.Transport.sendUnreliable(player, channel, ...)
	end
	function api:broadcastUnreliable(channel: string, ...)
		services.Transport.broadcastUnreliable(channel, ...)
	end

	-- Status and control (dev menu). Control calls take the acting player and re-check permissions in the kernel.
	function api:status()
		return services.status()
	end
	function api:logs(since: number?, limit: number?)
		return services.Logs.since(since, limit)
	end
	function api:branches()
		return services.branchList()
	end
	function api:reload(player: Player)
		return services.reload(player)
	end
	function api:rollback(player: Player)
		return services.rollback(player)
	end
	function api:switchBranch(player: Player, branch: string)
		return services.switchBranch(player, branch)
	end
	-- Kernel 0.2.0+ (additive; the framework feature-detects them, KERNEL_API stays 1).
	function api:artifacts()
		return services.artifacts()
	end
	function api:pinArtifact(player: Player, assetId: number)
		return services.pinArtifact(player, assetId)
	end
	-- `assetId` (0.2.0+): the reserved server boots pinned to that known artifact.
	function api:newServer(player: Player, branch: string, assetId: number?)
		return services.newServer(player, branch, assetId)
	end

	-- Entry-only (not on the TS interface).
	function api.ready(stop: () -> ())
		generation.stop = stop
		generation.readyEvent:Fire(true)
	end
	function api.failed(err: string)
		generation.readyEvent:Fire(false, err)
	end
	return api
end

return Api
