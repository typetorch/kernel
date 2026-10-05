--!nonstrict
-- The kernel side of the generation contract (server). Each cloned Entry script calls `forEntry(script)` and passes
-- the result to the payload's `Server.boot.boot(kernel)`. The TypeScript view of this object is
-- `ServerKernel` in @typetorch/framework (src/kernel.ts); keep them in sync and bump KERNEL_API on breaking changes.
-- Methods use `:` because roblox-ts calls interface methods with `:`.

local Api = {}

local persistStore: { [string]: any } = {}
local entries: { [Script]: any } = {}
local services = nil -- set by the kernel: { Access, Transport, Logs, status, branchList, artifacts, reload, rollback,
-- switchBranch, pinArtifact, newServer, requestReload, unpin, experiment, KERNEL_BUILD, keys, reportError, fleetStatus,
-- addReportListener, deployReports, accessCode }. 0.3.2: reload, rollback, switchBranch, pinArtifact and unpin run
-- on a kernel thread (the caller waits).

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
		-- 0.3 (P-V1): the kernel build (short commit, "*" = dirty) stamped by `typetorch kernel deploy`, or nil.
		kernelBuild = services.KERNEL_BUILD,
		artifact = table.clone(generation.artifact),
		generation = generation.number,
		branch = generation.branch,
		channel = generation.channel,
		serverType = services.serverType(),
		-- 0.2.2: { kind, reason, requestedBy?, previous?, branchChanged, startedAt, loadSeconds, stopSeconds?,
		-- swapSeconds? }. The kernel's own table: it adds swapSeconds once the swap finished.
		start = generation.start,
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
		-- 0.3.2 (P-N1): with the payload's ProtocolHash, clients still tagging an older artifact of the same protocol
		-- reach this handler too.
		services.Transport.attach(generation.artifact.id, fn, generation.artifact.protocolHash)
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
	-- 0.2.3: `options` = { experiment = true } pins as an A/B experiment (owner only; any channel, public servers
	-- too). Only `experiment` is read: who asked is always `player` here.
	function api:pinArtifact(player: Player, assetId: number, options: any?)
		local experiment = typeof(options) == "table" and options.experiment == true
		if not experiment then
			return services.pinArtifact(player, assetId)
		end
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return { ok = false, error = "bad player" }
		end
		return services.pinArtifact(player, assetId, { experiment = true })
	end
	-- `assetId` (0.2.0+): the reserved server boots pinned to that known artifact.
	function api:newServer(player: Player, branch: string, assetId: number?)
		return services.newServer(player, branch, assetId)
	end

	-- Kernel 0.2.2+ (additive). One handler each per generation; the framework installs them and fans out.
	-- Whether this generation is pinned now (a pin on the running artifact sets it without a swap).
	function api:pinned(): boolean
		return generation.pinned == true
	end
	-- fn({reason, branch, artifactId?, commit?, eta, cancelled?}): a swap is coming in about `eta` s, or was called off.
	function api:onPending(fn)
		generation.pendingHandler = fn
	end
	-- fn(player, {dev, reason, role}) when a player's dev decision changes after the first one (revoked, new member).
	function api:onDevChanged(fn)
		generation.devHandler = fn
	end
	-- Reload this server to its branch head: the owner only (checked by the kernel). Returns at once
	-- ({ok, queued}); the swap runs on a kernel thread, so it survives this generation's hard stop.
	function api:requestReload(player: Player)
		return services.requestReload(player)
	end

	-- Kernel 0.2.3+ (additive): A/B experiments.
	-- The running experiment pin ({ artifactId, assetId, by, since }) or nil. Its presence marks a 0.2.3 kernel.
	function api:experiment()
		return services.experiment()
	end
	-- Ends this server's experiment (back to the branch head). The owner on public servers, devs elsewhere.
	function api:unpin(player: Player)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return { ok = false, error = "bad player" }
		end
		return services.unpin(player)
	end

	-- Kernel 0.3+ (additive): signed prod deploys.
	-- The trust state, for devs only (the framework checks the asking player): { keyAssetId, loaded, mode = "key asset" |
	-- "fallback only" | "none", version, loadedAt, lastReadOk, lastError, lastErrorAt, reads, configError,
	-- publicKeys = { { key, fingerprint, revoked? } }, revokedKeys = { { key, fingerprint } }, trusted, invalid?,
	-- fallback = { key, fingerprint, revoked }?, lastHintAt, lastChange = { at, reason, hinted, version,
	-- previousVersion, added, removed, revokedAdded, revokedRemoved, before, after }?, changes, signedOnly,
	-- rejected = { total, byKind, last }, refusals }. Its presence marks a 0.3 kernel. Public keys aren't secret.
	function api:keys()
		return services.keys()
	end

	-- Kernel 0.3.2+ (additive): bad deploys are safe.
	-- The framework reports a failed lifecycle hook: { kind = "onStart" | "onPlayerAdded" | ..., module, message }. A
	-- failed onStart within the health window rolls this generation back; other kinds count as one error each. The
	-- kernel prints it (as an error line from its own thread). Returns whether it was taken (false once this
	-- generation is stopping). Its presence marks a 0.3.2 kernel.
	function api:reportError(info)
		return services.reportError(generation, info)
	end
	-- fn() runs from the kernel's BindToClose (server shutdown) while this generation is the running one, for at most
	-- CLOSE_DEADLINE seconds. One handler per generation; the framework installs it.
	function api:onClose(fn)
		generation.closeHandler = if typeof(fn) == "function" then fn else nil
	end
	-- This server's fleet status: { t, b, c?, a?, n, m, s, u, p, k?, x?, v, q, g, h, e?, sv = 2 } (plans/01 "Fleet
	-- status and deploy reports"). Cheap, no yield. The kernel writes it nowhere: the framework's analytics engine sends
	-- it as a heartbeat and Manage > Servers' roll call answers with it. `k` (a reserved server's access code) is
	-- server-only data: never send it to a client.
	function api:fleetStatus()
		return services.fleetStatus()
	end
	-- fn(report) once per deploy outcome on this server: { s, b, a, j, r, e?, d?, t, g, k, p }, r = "swapped" |
	-- "failed" | "rolled_back" | "skipped" | "booted". The last 20 are replayed to fn at once (oldest first), since a
	-- generation attaches after its own boot report. Each call runs on its own kernel thread; the listener is dropped
	-- when this generation stops. Returns a disconnect function.
	function api:onDeployReport(fn)
		return services.addReportListener(fn, generation)
	end
	-- The last 20 deploy reports, oldest first (copies).
	function api:deployReports()
		return services.deployReports()
	end
	-- A reserved server's own access code (stored in its private/<id> record by newServer or Migrate), or nil.
	-- Server-only data: never send it to a client.
	function api:accessCode()
		return services.accessCode()
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
