--!strict
-- Kernel constants shared by the server and client halves. See ../../../plans/01-kernel.md.

return {
	-- Bump only when the kernel <-> framework contract changes (artifacts declare the API they need).
	KERNEL_API = 1,
	-- The single version source: package.json "version" must match (typetorch kernel deploy checks). The build (git
	-- commit) and content hash are stamped by kernel deploy as attributes on ServerScriptService.TypeTorchKernel
	-- (KernelCommit, KernelHash); see status().kernelBuild.
	KERNEL_VERSION = "0.3.8",

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
	-- Fast path for deploys; the poll below is the backup (MessagingService delivery is best-effort).
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
}
