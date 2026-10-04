--!nonstrict
-- The kernel side of the generation contract (client). Same shape as the server Api; the TypeScript view is
-- `ClientKernel` in @typetorch/framework (src/kernel.ts).

local ClientApi = {}

local persistStore: { [string]: any } = {}
local entries: { [LocalScript]: any } = {}
local services = nil -- set by KernelClient: { transport, logs, devStatus, onKernelEvent, KERNEL_API, KERNEL_VERSION }

function ClientApi.init(kernelServices)
	services = kernelServices
end

function ClientApi.register(entry: LocalScript, generation)
	entries[entry] = generation
end

function ClientApi.unregister(entry: LocalScript)
	entries[entry] = nil
end

function ClientApi.forEntry(entry: LocalScript)
	local generation = entries[entry]
	assert(generation, "ClientEntry was not registered by the kernel")
	local api = {
		kernelApi = services.KERNEL_API,
		kernelVersion = services.KERNEL_VERSION,
		artifact = { id = generation.artifactId },
		generation = generation.number,
		branch = generation.branch,
		channel = generation.channel,
	}
	function api:persist(key: string, init: () -> any)
		local value = persistStore[key]
		if value == nil then
			value = init()
			persistStore[key] = value
		end
		return value
	end
	function api:onMessage(fn)
		services.transport.attach(generation.artifactId, fn)
	end
	function api:send(channel: string, ...)
		services.transport.send(channel, ...)
	end
	function api:sendUnreliable(channel: string, ...)
		services.transport.sendUnreliable(channel, ...)
	end
	-- { dev, reason, role, channel } as last told by the server (cosmetic: the server re-checks everything).
	function api:devStatus()
		return services.devStatus()
	end
	-- fn(name) for kernel events such as "dev-open"; returns a disconnect function.
	function api:onKernelEvent(fn)
		return services.onKernelEvent(fn)
	end
	function api:logs(since: number?, limit: number?)
		return services.logs.since(since, limit)
	end
	function api.ready(stop: () -> ())
		generation.stop = stop
		generation.readyEvent:Fire(true)
	end
	function api.failed(err: string)
		generation.readyEvent:Fire(false, err)
	end
	return api
end

return ClientApi
