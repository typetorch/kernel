--!strict
-- Kernel constants shared by the server and client halves. See ../../../plans/01-kernel.md.

return {
	-- Bump only when the kernel <-> framework contract changes (artifacts declare the API they need).
	KERNEL_API = 1,
	-- The single version source: package.json "version" must match (typetorch kernel deploy checks). The build (git
	-- commit) and content hash are stamped by kernel deploy as attributes on ServerScriptService.TypeTorchKernel
	-- (KernelCommit, KernelHash); see status().kernelBuild.
	KERNEL_VERSION = "0.3.2",

	-- Interim registry (until the backend exists): a DataStore written by the CLI through Open Cloud.
	DATASTORE = "TypeTorch",
	-- Fast path for deploys; the poll below is the backup (MessagingService delivery is best-effort).
	DEPLOY_TOPIC = "TypeTorch/deploy",
	-- 0.2.3: remote experiment pins (A/B) from Admin > Servers: { j?, pct?, a?, b, by, t, unpin? }.
	PIN_TOPIC = "TypeTorch/pin",
	-- A pin message older (or newer) than this many seconds by its `t` is ignored.
	PIN_MAX_AGE = 120,
	-- 0.3: a hint to re-read the key asset (signing keys) now; content ignored, rate-limited (plans/03).
	REKEY_TOPIC = "TypeTorch/rekey",
	-- 0.3: the key asset is re-read about this often anyway.
	KEYS_REFRESH_SECONDS = 600,
	-- 0.3: at boot, a prod server waits at most this long for the first key asset read before it checks signatures
	-- (after that, the fallback key decides until the key asset loads).
	KEYS_BOOT_WAIT = 10,
	-- 0.3 (P-K5): boot waits at most this long for ConfigService; it keeps retrying in the background.
	CONFIG_BOOT_WAIT = 3,
	-- 0.3 (P-K4): a generation's stop function gets this many seconds, then the hard stop runs anyway.
	STOP_DEADLINE = 5,
	-- 0.3 (P-K2): a deploy whose payload failed to LOAD is retried after these delays (seconds), then reported.
	LOAD_RETRY_DELAYS = { 5, 15, 60, 60, 60 },
	POLL_SECONDS = 60,
	-- Deployment history entries kept in the in-game DataStore key "deployments" (dev menu artifact picker).
	DEPLOYMENTS_KEPT = 100,

	-- A generation must call ready() within this long or the kernel rolls back.
	READY_TIMEOUT = 20,
	-- 0.3.2 (audit P-F1): the health window. A generation whose onStart failed (reported by the framework), or whose
	-- own scripts raised HEALTH_ERRORS errors, within HEALTH_WINDOW seconds of ready is rolled back to the last known
	-- good artifact, which is then marked failed on this server.
	HEALTH_WINDOW = 30,
	HEALTH_ERRORS = 3,
	-- 0.3.2 (audit P-K3): at most this many last-known-good candidates are tried after one failure.
	LKG_MAX_TRIES = 5,
	-- 0.3.2: BindToClose gives the running generation's onClose handler at most this long (Roblox allows 30 s).
	CLOSE_DEADLINE = 20,
	-- 0.3.2 (audit P-K8): MessagingService subscriptions that fail are retried after these delays (seconds), then
	-- every last delay for as long as the server runs.
	SUBSCRIBE_RETRY_DELAYS = { 5, 15, 30, 60 },
	-- 0.3.2 (audit P-K8): a private/reserved server's stored branch is read at boot with these retry delays; after
	-- that the sync loop keeps trying and applies the branch late.
	PRIVATE_READ_RETRY_DELAYS = { 1, 2, 4 },
	-- 0.3.2 (audit P-K9): a failed badge, group rank or group list web call counts as "no" for this long before the
	-- next call (a Roblox outage must not turn every dev check into a web call).
	ACCESS_FAILURE_CACHE = 30,

	-- 0.3.2 (audit P-O1): the kernel writes nothing itself. api:fleetStatus() gives this server's heartbeat table and
	-- api:onDeployReport(fn) one report per deploy outcome (the framework's analytics engine forwards them); the last
	-- REPORTS_KEPT reports are kept and replayed to each new listener (api:deployReports()).
	REPORTS_KEPT = 20,
	-- Old client trees stay this long after a swap so clients can stop their old generation first.
	CLIENT_TREE_GRACE = 30,
	-- Random delay before a public server fetches a new deploy, so all servers don't hit LoadAsset at once.
	PUBLIC_JITTER_SECONDS = 10,

	-- Kernel-internal transport channels (game channels never start with "__tt/").
	CHANNEL_RESYNC = "__tt/resync",
	CHANNEL_NOTICE = "__tt/notice",
	CHANNEL_DEV = "__tt/dev",
	CHANNEL_EVENT = "__tt/event",
	-- 0.2.2: a swap is coming ({reason, branch, artifactId, commit, eta}) or was called off ({cancelled = true}).
	CHANNEL_PENDING = "__tt/pending",
	-- 0.3.2 (audit P-K7): client -> server, tagged "*": how this client's generation start went
	-- ({g = generation name, ok, e = error?, ms, retried?}).
	CHANNEL_CLIENT = "__tt/client",
	-- 0.3.2 (P-K7): a client generation that failed to start is tried once more after this many seconds.
	CLIENT_RETRY_SECONDS = 2,
}
