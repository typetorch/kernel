--!strict
-- Kernel constants shared by the server and client halves. See ../../../plans/01-kernel.md.

return {
	-- Bump only when the kernel <-> framework contract changes (artifacts declare the API they need).
	KERNEL_API = 1,
	-- The single version source: package.json "version" must match (typetorch kernel deploy checks). The build (git
	-- commit) and content hash are stamped by kernel deploy as attributes on ServerScriptService.TypeTorchKernel
	-- (KernelCommit, KernelHash); see status().kernelBuild.
	KERNEL_VERSION = "0.3.3",

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
	-- 0.3.2 BOOT BUDGET (user requirement): a new server runs a playable generation within BOOT_BUDGET seconds of the
	-- kernel starting, in every path (plans/01 "Boot budget"). The boot reads (key asset, ConfigService, both copies of
	-- the heads, the private record, the deployment list) all start at once; boot waits for them at most BOOT_READS_WAIT
	-- seconds from the kernel start (a read that already failed isn't waited for; slow ones land later).
	BOOT_BUDGET = 15,
	BOOT_READS_WAIT = 3,
	-- A prod server waits at most this long (from the kernel start) for the key asset before it checks signatures;
	-- after that the fallback key decides until the key asset loads (the strict rule, unchanged). 0.3.0: 10.
	KEYS_BOOT_WAIT = 3,
	-- A player-owned private server's owner dev check (web calls) at boot; slower: the default branch, then re-checked.
	BOOT_OWNER_CHECK = 2,
	-- Boot attempts (while nothing has run yet, within BOOT_BUDGET): LoadAsset at most BOOT_LOAD_TIMEOUT and ready() at
	-- most BOOT_READY_TIMEOUT seconds, both cut to the time left before BOOT_DEADLINE, but never below BOOT_LATE_LOAD /
	-- BOOT_LATE_READY. A head that ran out of time is retried in the background (normal timeouts) and swapped to when it
	-- works; the next candidate boots meanwhile.
	BOOT_DEADLINE = 12,
	BOOT_LOAD_TIMEOUT = 4,
	BOOT_READY_TIMEOUT = 6,
	BOOT_LATE_LOAD = 2,
	BOOT_LATE_READY = 3,
	-- 0.3 (P-K4): a generation's stop function gets this many seconds, then the hard stop runs anyway.
	STOP_DEADLINE = 5,
	-- 0.3 (P-K2): a deploy whose payload failed to LOAD is retried after these delays (seconds), then reported.
	LOAD_RETRY_DELAYS = { 5, 15, 60, 60, 60 },
	POLL_SECONDS = 60,
	-- Deployment history entries kept in the in-game DataStore key "deployments" (dev menu artifact picker).
	DEPLOYMENTS_KEPT = 100,

	-- A generation must call ready() within this long or the kernel rolls back (swaps; boot: BOOT_READY_TIMEOUT).
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
	-- 0.3.2 (audit P-K8): a private/reserved server's stored branch is read at boot with these retry delays (in the
	-- background: boot waits BOOT_READS_WAIT at most, then a late answer is applied with a swap).
	PRIVATE_READ_RETRY_DELAYS = { 1, 2, 4 },
	-- 0.3.2 (audit P-K9): a failed badge, group rank or group list web call counts as "no" for this long before the
	-- next call (a Roblox outage must not turn every dev check into a web call).
	ACCESS_FAILURE_CACHE = 30,

	-- 0.3.2 (audit P-O1): the kernel writes nothing itself. api:fleetStatus() gives this server's heartbeat table and
	-- api:onDeployReport(fn) one report per deploy outcome (the framework's analytics engine forwards them); the last
	-- REPORTS_KEPT reports are kept and replayed to each new listener (api:deployReports()).
	REPORTS_KEPT = 20,
	-- 0.3.2 (user decision): the kernel also sends its fleet data itself, live and whatever the generation does, to the
	-- dev's fleet API, when the server-only ConfigService key FLEET_KEY = { url, token } exists (Fleet.luau).
	FLEET_KEY = "TypeTorchFleet",
	-- The settings are read at boot and every this many seconds.
	FLEET_SETTINGS_SECONDS = 300,
	-- A heartbeat (the fleet status) at least this often, and right after a swap, a health change or (at most once per
	-- FLEET_PLAYERS_GAP s) a player count change.
	FLEET_HEARTBEAT_SECONDS = 30,
	FLEET_PLAYERS_GAP = 5,
	-- Health and trusted-head changes are looked at this often (they send a heartbeat and maybe an alert).
	FLEET_WATCH_SECONDS = 5,
	-- A failed request (no answer, HTTP 429 or 5xx) is retried after these delays, then dropped; other 4xx: dropped.
	FLEET_RETRY_DELAYS = { 1, 3, 9 },
	-- Reports, alerts and closing requests waiting at most (the oldest go first when it is full).
	FLEET_QUEUE_MAX = 100,
	-- At most this many requests per minute (burst 10), whatever happens: HttpService's 500/min is the game's too.
	FLEET_RATE_PER_MINUTE = 30,
	-- One alert per code per this many seconds (an error spike: 5 minutes).
	FLEET_ALERT_GAP = 60,
	FLEET_SPIKE_GAP = 300,
	-- An error spike: this many errors from the running generation's scripts within 60 s.
	FLEET_ERROR_SPIKE = 20,
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
	-- 0.3.3 (owner override): client -> server, tagged "*": { id, branch? | assetId? | back? } asks to switch THIS server in
	-- place; server -> client: { id, ok, error?, generation? }. One request per player per OVERRIDE_GAP seconds.
	CHANNEL_OVERRIDE = "__tt/override",
	OVERRIDE_GAP = 5,
}
