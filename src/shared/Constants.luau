--!strict
-- Kernel constants shared by the server and client halves. See ../../../plans/01-kernel.md.

return {
	-- Bump only when the kernel <-> framework contract changes (artifacts declare the API they need).
	KERNEL_API = 1,
	-- The single version source: package.json "version" must match (typetorch kernel deploy checks). The build (git
	-- commit) and content hash are stamped by kernel deploy as attributes on ServerScriptService.TypeTorchKernel
	-- (KernelCommit, KernelHash); see status().kernelBuild.
	KERNEL_VERSION = "0.5.1",

	-- The kernel's DataStore: durable heads, deployments, private records, events, and (0.3.8) the signed settings.
	DATASTORE = "TypeTorch",
	-- 0.3.8 (plans/20): THE SIGNED SETTINGS RECORD, key SETTINGS_KEY in DATASTORE, written only by the CLI and signed
	-- with both prod keys (Settings.luau). It replaces every ConfigService key (TypeTorch, TypeTorchFleet,
	-- TypeTorchAccess, TypeTorchAnalytics). Read at boot, at most every SETTINGS_REFRESH_SECONDS from the sync tick, and
	-- after a ping ({ k = "settings", s = seq } on DEPLOY_TOPIC) at most every SETTINGS_PING_GAP seconds. The body is
	-- at most SETTINGS_BODY_MAX bytes, its `game` field at most SETTINGS_GAME_MAX.
	SETTINGS_KEY = "settings",
	SETTINGS_REFRESH_SECONDS = 55,
	SETTINGS_PING_GAP = 5,
	SETTINGS_BODY_MAX = 32768,
	SETTINGS_GAME_MAX = 16384,
	-- 0.3.8: DETACHED JOBS (api:runDetached, Api.luau): game code run on a kernel thread, so a generation's hard stop
	-- can't cut it off (a ProfileStore load, save or release). At most DETACHED_MAX run at once per server; one that
	-- runs longer than DETACHED_SLOW seconds is logged once.
	DETACHED_MAX = 256,
	DETACHED_SLOW = 60,
	-- Fast path for deploys; the poll below is the backup (MessagingService delivery is best-effort). The kernel's one
	-- control topic: it also carries the settings ping ({ k = "settings", s }, 0.3.8), the peers' roll call ask
	-- ({ rc = 1, ... }, 0.3.6) and the remote debug wake ({ k = "rd", j = JobId }, 0.5.1, RD_WAKE_GAP), none a deploy.
	DEPLOY_TOPIC = "TypeTorch/deploy",
	-- 0.2.3: remote experiment pins (A/B) from Manage > Servers: { j?, pct?, a?, b, by, t, unpin? }.
	PIN_TOPIC = "TypeTorch/pin",
	-- A pin message older (or newer) than this many seconds by its `t` is ignored.
	PIN_MAX_AGE = 120,
	-- 0.3: a hint to re-read the key asset (signing keys) now; content ignored, rate-limited (plans/03).
	REKEY_TOPIC = "TypeTorch/rekey",
	-- 0.3: the key asset is re-read about this often anyway.
	KEYS_REFRESH_SECONDS = 600,
	-- 0.3.2 BOOT BUDGET (user requirement): a new server runs a playable generation within BOOT_BUDGET seconds of the
	-- kernel starting, in every path (plans/01 "Boot budget"). The boot reads (key asset, the settings, both copies of
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
	-- 0.3.5 (durable heads): the DataStore copy of the heads is read at most this often by the sync loop (the CLI writes
	-- that copy after every deploy, so a deploy no running server heard is found). One GetAsync per server per minute.
	HEADS_DURABLE_SECONDS = 55,
	-- Deployment history entries kept in the in-game DataStore key "deployments" (dev menu artifact picker).
	DEPLOYMENTS_KEPT = 100,

	-- A generation must call ready() within this long or the kernel rolls back (swaps; boot: BOOT_READY_TIMEOUT).
	READY_TIMEOUT = 20,
	-- 0.3.2 (audit P-F1): the health window. A generation whose onStart failed (reported by the framework), or whose
	-- own scripts raised HEALTH_ERRORS errors, within HEALTH_WINDOW seconds of ready is rolled back to the last known
	-- good artifact, which is then marked failed on this server.
	-- 0.3.7: these are the defaults. A build carries its own (typetorch.json "health", stamped by `typetorch build` on
	-- the payload root as HealthErrors, HealthWindow and HealthRollback); a value outside the bounds below falls back to
	-- the default (Health.luau). The CLI checks the same bounds.
	HEALTH_WINDOW = 30,
	HEALTH_ERRORS = 3,
	HEALTH_ERRORS_MIN = 1,
	HEALTH_ERRORS_MAX = 100,
	HEALTH_WINDOW_MIN = 5,
	HEALTH_WINDOW_MAX = 300,
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
	-- dev's fleet API, when the signed settings hold `fleet` = { url, token } (Fleet.luau; 0.3.2-0.3.7: the ConfigService
	-- key TypeTorchFleet).
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
	-- 0.3.9 (NetFail errors from a dead quick tunnel, every server in lockstep): every wait gets +-FLEET_JITTER. A request
	-- whose retries all failed is a failed cycle: the sender then waits FLEET_HEARTBEAT_SECONDS x 2^(n-1) for the n-th
	-- failed cycle in a row, at most FLEET_BACKOFF_MAX s; a 401, 403 or 404 holds it off FLEET_AUTH_HOLD s (a wrong
	-- token or URL won't fix itself). One success resets both. At most one "unreachable" line (with the reason) per
	-- FLEET_LOG_GAP s, and one "work again" line after an outage.
	FLEET_JITTER = 0.25,
	FLEET_BACKOFF_MAX = 300,
	FLEET_AUTH_HOLD = 300,
	FLEET_LOG_GAP = 60,
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
	-- 0.3.4 (owner switch): client -> server, tagged "*": { id, branch? | assetId? } asks the kernel to switch THIS server
	-- to a branch or load a build here, for the requesting player; server -> client: { id, ok, error?, generation?,
	-- queued? }. One request per player per SWITCH_GAP seconds (2 s, like the dev menu's swaps).
	CHANNEL_SWITCH = "__tt/switch",
	SWITCH_GAP = 2,

	-- 0.3.6 NEVER AN EMPTY SERVER (user requirement: "IN NO POSSIBLE WAY players should load into an empty baseplate";
	-- plans/01 "Never an empty server", src/server/Fallback.luau).
	-- Hold: until the first generation is ready, characters don't spawn (Players.CharacterAutoLoads off) and the kernel
	-- client shows its holding screen. A Players attribute HOLD_ATTRIBUTE = false opts a game out of the character part
	-- (games that spawn characters themselves); default on.
	HOLD_ATTRIBUTE = "TypeTorchHoldCharacters",
	-- server -> client, tagged "*": "move" (this player is being moved to another server) or "load" (client code re-sent).
	CHANNEL_HOLD = "__tt/hold",
	-- The backup payload `typetorch kernel deploy` bakes into the place (the prod head's payload, modules only):
	-- ServerStorage.<BACKUP_NAME>, attributes BackupArtifactId, BackupSeq, BackupBranch, BackupChannel, BackupAt.
	BACKUP_NAME = "TypeTorchBackup",
	-- When a fallback is ready (a peer build or the backup), no new boot candidate starts after this many seconds from
	-- the kernel start; the rest are retried in the background. Keeps the backup inside the boot budget.
	FALLBACK_AT = 9,
	-- Peers (a kernel roll call): an ask { rc = 1, q, j, b, t } rides DEPLOY_TOPIC (every kernel subscribes to it, so
	-- no new permanent subscription); kernels on branch `b` that run a healthy generation for PEER_MIN_UPTIME seconds
	-- answer on "<PEER_TOPIC>/<asker JobId>" after up to PEER_REPLY_JITTER s (at most PEER_REPLIES_PER_MINUTE a minute,
	-- one per asker per PEER_REPLY_GAP s, never to an ask older than PEER_ASK_MAX_AGE s). The asker collects for
	-- PEER_COLLECT s (less once PEER_ENOUGH replied) and keeps the list PEER_CACHE s.
	PEER_TOPIC = "TypeTorch/peers",
	PEER_COLLECT = 2,
	PEER_ENOUGH = 6,
	PEER_MIN_UPTIME = 30,
	PEER_REPLY_JITTER = 0.5,
	PEER_REPLIES_PER_MINUTE = 12,
	PEER_REPLY_GAP = 5,
	PEER_ASK_MAX_AGE = 30,
	PEER_CACHE = 15,
	-- Recovery: while the backup (or nothing) runs, the head, the last known good and peers are retried after these
	-- delays (then every last delay) until the head runs.
	RECOVER_DELAYS = { 15, 30, 60 },
	-- Nothing runs after BOOT_BUDGET (or for TELEPORT_GRACE s later in the server's life): players are moved to another
	-- server of the branch. A player still here TELEPORT_RETRY s after a teleport is tried again, at most TELEPORT_TRIES
	-- times; one who arrives with a bounce count of BOUNCE_MAX is kicked with KICK_MESSAGE instead.
	TELEPORT_GRACE = 5,
	TELEPORT_RETRY = 10,
	TELEPORT_TRIES = 3,
	BOUNCE_MAX = 3,
	KICK_MESSAGE = "Servers are restarting. Please rejoin in a minute.",
	CLIENT_KICK_MESSAGE = "The game didn't load. Please rejoin.",
	-- (0.3.6-0.3.7 read the dev lists from the ConfigService key TypeTorchAccess; 0.3.8: the signed settings' `access`.)
	-- 0.3.6 (plans/18): the stored `heads` key holds at most this many branches; a deploy message for a NEW branch
	-- beyond it isn't recorded (the CLI's durable copy still has it). Prod servers also ignore messages for branches they
	-- don't know (not in the settings' `channels`, not in the stored heads) unless the message is signed.
	HEADS_MAX_BRANCHES = 32,
	-- server -> client, tagged "*": { g } the client tree of generation g was re-sent to PlayerGui.TypeTorchResend (once,
	-- after the client's own retry failed); the client waits at most CLIENT_RESEND_WAIT s for it.
	CHANNEL_RESEND = "__tt/resend",
	CLIENT_RESEND_WAIT = 15,

	-- 0.3.8 GAME MESSAGING (plans/19 item 4; src/server/Messaging.luau; plans/01 "Game messaging"). Roblox's
	-- MessagingService limits (create.roblox.com MessagingService "Limitations", checked 2026-10-06): a message is at most
	-- 1 KiB; a game server sends at most 600 + 240 x players messages a minute; a topic receives at most 40 + 80 x servers
	-- messages a minute (every subscribed server receiving a message counts, so about 80 messages a minute on one topic
	-- for the whole universe); the whole game receives 400 + 200 x servers a minute; a server holds at most 20 + 8 x
	-- players subscriptions and makes at most 240 subscribe requests a minute.
	-- Game topics ("anticheat", "announce", ...) ride ONE kernel-held topic, subscribed on first use and held for the
	-- server's life (a swap never subscribes again); listeners belong to their generation.
	GAME_TOPIC = "TypeTorch/game",
	-- The framework's roll call asks (Manage > Servers, TypeTorch.servers()) arrive on this topic; 0.3.8 holds it for the
	-- running generation (api:onRollCall) instead of every generation subscribing again. Same protocol as before.
	ROLLCALL_TOPIC = "TypeTorch/rollcall",
	-- The envelope as published, counted JSON-escaped (the worst case of how Roblox may count it), must fit this.
	MESSAGE_MAX_BYTES = 1000,
	-- A game topic name: 1-64 characters of [%w_%-.:/], not starting with "__" (reserved).
	MESSAGING_TOPIC_MAX = 64,
	-- Data: JSON-compatible values only, nested at most this deep.
	MESSAGING_DEPTH_MAX = 16,
	-- This server publishes game messages at most MESSAGING_PUBLISH_BASE + MESSAGING_PUBLISH_PER_PLAYER x players a minute
	-- (a quarter of Roblox's per-server send limit; the kernel, the roll call and the game's own MessagingService use share
	-- the rest), bursts of MESSAGING_BURST.
	MESSAGING_PUBLISH_BASE = 150,
	MESSAGING_PUBLISH_PER_PLAYER = 60,
	MESSAGING_BURST = 20,
	-- Every server sees every game message, so each one knows the universe's rate on the game topic. At this many messages
	-- in the last 60 s, publishes wait (with jitter) until the rate drops: the universe stays under Roblox's per-topic
	-- receive limit (about 80 a minute) cooperatively.
	MESSAGING_TOPIC_SOFT = 60,
	-- Queued publishes wait at most MESSAGING_MAX_DELAY s (then dropped, counted, warned); at most MESSAGING_QUEUE_MAX wait.
	MESSAGING_QUEUE_MAX = 100,
	MESSAGING_MAX_DELAY = 30,
	-- A failed PublishAsync is retried after these delays (seconds), then the message is dropped.
	MESSAGING_RETRY_DELAYS = { 1, 3, 9 },
	-- Messages that arrive while a swap runs (no listener for their topic yet) are kept this long, at most
	-- MESSAGING_REPLAY_MAX, and replayed to the next generation's first listener of their topic.
	MESSAGING_REPLAY_SECONDS = 10,
	MESSAGING_REPLAY_MAX = 50,
	-- One "messaging" warning line (throttled, dropped, failing) per this many seconds at most.
	MESSAGING_WARN_GAP = 60,

	-- 0.3.8 LOADING SCREENS (plans/19 item 13). The kernel client sets, on its own script (client-side attributes):
	-- ClientReady = true once this player's first client generation runs, ClientGeneration = the running one's name, and
	-- Holding = the holding screen's mode ("start" | "load" | "move") while the kernel would show it. The game configures
	-- its screen with attributes on ReplicatedFirst (or, stamped by `kernel deploy`, on ServerScriptService.TypeTorchKernel
	-- as BootScreen / KernelScreen, which win); the server kernel copies them onto the kernel client script at once:
	--   TypeTorchBootScreen = "<name>": the kernel clones ReplicatedFirst.<name> (a ScreenGui) into PlayerGui at once and
	--     removes it when the first client generation runs (at most BOOT_SCREEN_TIMEOUT s);
	--   TypeTorchKernelScreen = false: the game shows its own loading screen; the kernel's "Starting..." screen stays off
	--     until the first client generation ran (moves always show it).
	BOOT_SCREEN_ATTRIBUTE = "TypeTorchBootScreen",
	KERNEL_SCREEN_ATTRIBUTE = "TypeTorchKernelScreen",
	BOOT_SCREEN_WAIT = 5,
	BOOT_SCREEN_TIMEOUT = 60,

	-- 0.3.9 THE HOLD, AFTER "Starting..." STAYED UP ON A RUNNING SERVER. ReplicatedFirst is replicated once, when a player
	-- joins (later server changes there don't reach that client), so the `Hold` attribute on the kernel client script is
	-- only the join snapshot; ReplicatedStorage.TypeTorch's `Hold` (with `HoldReason`) is the live value clients follow.
	-- The server releases a "start" hold the watchdog still finds on while a generation runs, after HOLD_STUCK_RELEASE s
	-- (a bookkeeping bug: warned). The client drops its "Starting..." screen by itself when its own generation runs, the
	-- server has an ActiveGeneration, and the hold still says "start" after CLIENT_HOLD_FAILSAFE s (warned with the state
	-- it saw; "move" holds are real and never dropped). KernelClient hard-codes the client value (it runs before this
	-- module can be required).
	HOLD_STUCK_RELEASE = 3,
	CLIENT_HOLD_FAILSAFE = 5,
	-- ScreenGui DisplayOrders: the holding screen covers every game UI; the framework's dev menu (and its button) sits
	-- above it (HOLD_DISPLAY_ORDER + 100), so a dev can open it while the screen is up.
	HOLD_DISPLAY_ORDER = 2147483000,
	-- 0.3.9 /tt rollback on a server with no earlier generation: the branch's previous heads. The CLI (and the kernel's own
	-- durable writes) keep the last PREV_HEADS_KEPT heads of a branch as `prev` (newest first) on heads.<branch> in the
	-- DataStore copy only (MemoryStore copies never carry it: a hash map item is at most 32 KB).
	PREV_HEADS_KEPT = 3,

	-- 0.4.0 (plans/21 C): ONE BACKEND. The signed settings' `backend` = { url, key, analytics? } replaces `fleet` (and
	-- the framework's `analytics`); both old fields are still read when `backend` is missing. One URL and one key:
	-- heartbeats to <url>/v1/fleet/*, events to <url>/v1/ingest (the framework), error reports to <url>/v1/errors.
	ERRORS_PATH = "/v1/errors",

	-- 0.4.0 ERROR REPORTS (problem 19; src/server/Errors.luau). Server errors (ScriptContext.Error, LogService error lines)
	-- and client errors (the kernel client forwards its own on CHANNEL_ERRORS) are templated (players' names, display
	-- names and UserIds become <player.name>, <player.display_name>, <player.user_id>), fingerprinted (template + top
	-- stack line), counted per minute with the analytics ids (pids) of the players affected, and posted to the backend
	-- in batches. The backend's limits (POST /v1/errors): <= 200 items, 512 KB (2 MB inflated), 30 requests a minute per
	-- JobId; template <= 1000 characters, stack <= 4000, count 1..1e6, pids <= 50 (10 on the hardened backend: the cap here), lastAt - firstAt <= 10 minutes (items are per minute), times within the last 7 days.
	-- client -> server, tagged "*": { e = { { m = message, s = stack?, n = count, g = generation? }, ... }, d = dropped }.
	CHANNEL_ERRORS = "__tt/errors",
	-- A batch goes out at most this often while errors wait (jittered), and at most ERRORS_RATE_PER_MINUTE requests a
	-- minute (burst 2) whatever happens.
	ERRORS_FLUSH_SECONDS = 15,
	ERRORS_RATE_PER_MINUTE = 6,
	-- Bounded memory: error kinds held (template + one stack each), per-minute items waiting, items per request, the raw
	-- JSON per request (gzip makes it far smaller than the backend's 512 KB).
	ERRORS_KINDS_MAX = 200,
	ERRORS_ITEMS_MAX = 600,
	ERRORS_BATCH_MAX = 200,
	ERRORS_BATCH_BYTES = 400000,
	ERRORS_TEMPLATE_MAX = 1000,
	ERRORS_STACK_MAX = 4000,
	ERRORS_PIDS_MAX = 10,
	ERRORS_COUNT_MAX = 1000000,
	-- Items older than this (seconds) are dropped unsent (the backend refuses anything older than 7 days).
	ERRORS_MAX_AGE = 6 * 86400,
	-- At most this many errors are looked at per second (templated or counted); the rest are only counted as dropped.
	ERRORS_RECORD_PER_SECOND = 500,
	-- A player who left is still templated (and their pid kept) this many seconds.
	ERRORS_LEFT_SECONDS = 120,
	-- Clients: one batch per ERRORS_CLIENT_GAP s at most, ERRORS_CLIENT_BATCH entries each (the server takes one per
	-- ERRORS_CLIENT_SERVER_GAP s per player and drops the rest, counted); a client's count per entry is capped.
	ERRORS_CLIENT_GAP = 10,
	ERRORS_CLIENT_SERVER_GAP = 5,
	ERRORS_CLIENT_BATCH = 10,
	ERRORS_CLIENT_COUNT_MAX = 1000,
	ERRORS_CLIENT_MESSAGE_MAX = 1000,
	ERRORS_CLIENT_STACK_MAX = 2000,

	-- 0.4.0 THE BUDGET VIEW (problem 25; src/server/Budget.luau): every DataStore, MemoryStore, HTTP and MessagingService
	-- request TypeTorch makes, per minute and per caller, next to Roblox's limits for the current player count (the
	-- formulas and their sources are in Budget.luau). At most BUDGET_KEYS_MAX (caller, kind, op) counters.
	BUDGET_KEYS_MAX = 96,

	-- 0.5.0 REMOTE DEBUG (plans/25; src/server/RemoteDebug.luau). The explorer's /servers/<JobId> page asks the backend to
	-- watch this server; the heartbeat reply then carries `rd = 1` and this server long-polls the backend for commands
	-- (RD_COMMANDS_PATH, held up to RD_POLL_WAIT s), runs each read-only op on a kernel thread and posts the answers
	-- (RD_RESULTS_PATH). It polls while the backend says it is watched and RD_IDLE_SECONDS after the last command or
	-- watch signal, never otherwise. Only ops in RD_OPS run; at most RD_COMMANDS_PER_MINUTE (burst RD_COMMANDS_BURST);
	-- each gets RD_OP_TIMEOUT s; an answer over RD_RESULT_MAX bytes of JSON is refused. Callers must be owners.
	RD_COMMANDS_PATH = "/v1/fleet/commands",
	RD_RESULTS_PATH = "/v1/fleet/results",
	RD_POLL_WAIT = 8,
	-- At least this long between two polls that brought nothing (a backend that answers at once can't make a tight loop).
	RD_POLL_GAP = 2,
	RD_IDLE_SECONDS = 60,
	RD_COMMANDS_PER_MINUTE = 30,
	RD_COMMANDS_BURST = 10,
	RD_OP_TIMEOUT = 10,
	RD_RESULT_MAX = 200000,
	-- Failed polls in a row before the session ends (the next watched heartbeat starts a new one); a 401/403/404 holds
	-- new sessions off RD_AUTH_HOLD s.
	RD_FAILURES_MAX = 3,
	RD_RETRY_SECONDS = 5,
	RD_AUTH_HOLD = 300,
	-- 0.5.1 INSTANT WAKE (plans/25 "Instant wake"): when the explorer starts watching a server that isn't polling, the
	-- backend publishes { k = "rd", j = JobId } on DEPLOY_TOPIC (Open Cloud Messaging; unsigned). The server with that
	-- JobId starts its session at once, as if a heartbeat reply said rd = 1; its first poll asks the backend whether it is
	-- really watched, so a forged wake costs one poll. Other JobIds and malformed wakes are ignored; at most one wake per
	-- RD_WAKE_GAP s is acted on.
	RD_WAKE_GAP = 10,
	-- The read-only ops (v1): the kernel's own, and the ones the running generation answers through api:onRemoteDebug.
	RD_KERNEL_OPS = { "status", "builds", "budget", "logs", "players", "player.logs", "errors" },
	RD_FRAMEWORK_OPS = { "modules", "state", "assets", "network", "dex.children", "dex.props" },
	-- server -> client, tagged "*": { id, since } asks this client for its log ring; client -> server, tagged "*":
	-- { id, logs } (the asked player only, once, within RD_CLIENT_LOGS_TIMEOUT s; at most RD_CLIENT_LOGS_MAX entries
	-- and RD_CLIENT_LOGS_BYTES bytes are kept).
	CHANNEL_RDLOGS = "__tt/rdlogs",
	RD_CLIENT_LOGS_TIMEOUT = 5,
	RD_CLIENT_LOGS_MAX = 200,
	RD_CLIENT_LOGS_BYTES = 64000,

}
