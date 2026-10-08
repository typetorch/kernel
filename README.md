# @typetorch/kernel

The small loader baked into the place. It is plain Luau (no compile step, no roblox-ts runtime), so it never
shares a RuntimeLib with the payloads it loads. Changing it needs a server restart (`typetorch kernel deploy`).

- `src/server/` → `ServerScriptService.TypeTorchKernel`: boot, branch choice, LoadAsset + side-by-side mounting,
  swaps with soft + hard stop, automatic rollback, registry (in-game DataStore heads + the signed settings), dev access,
  stable transport, logs, the fleet API sender (`Fleet`), the fallbacks (`Fallback`), `/tt` chat commands. A place
  project that maps these files one by one must map `Fleet` (0.3.2), `Fallback` (0.3.6), `Health` (0.3.7) and
  `Messaging` (0.3.8) too; without them the kernel boots without that part and says so.
- `src/shared/` → `ReplicatedStorage.TypeTorchKernelShared`: constants, client API, ClientEntry template.
- `src/client/` → `ReplicatedFirst.TypeTorchKernelClient`: follows `ActiveGeneration`, swaps client generations.
- `place.project.json`: the whole place (kernel + baseplate + spawn, HTTP on). `rojo build place.project.json -o
  build/place.rbxl`; the CLI publishes it.
- Syntax check (Lune, pinned in `rokit.toml`): `rokit install`, then `lune run scripts/check.luau` compiles every
  `.luau` file and exits non-zero on a parse error. Run it before every place publish.
- Deployment history and pins (0.2.0): every deploy message is recorded in the DataStore key `deployments`;
  `api:artifacts()` lists it, `api:pinArtifact(player, assetId)` holds a server on a known artifact until its branch
  gets a newer deploy, and `api:newServer(player, branch, assetId?)` opens a reserved server pinned to one.
- Hooks for game code (0.2.2), used by the framework's `TypeTorch` API: `api.start` (how the generation started:
  boot or swap, reason, previous artifact and branch, timings), stop info `{reason, branch, next}`, `api:onPending`
  (a swap is coming, with an ETA; also broadcast to clients), `api:onDevChanged`, `api:pinned()` and
  `api:requestReload(player)` (owners). Clients get the full artifact identity, the server type and their
  own `start`.
- A/B experiments and rollouts (0.2.3): `api:pinArtifact(player, assetId, { experiment = true })` lets an owner
  run ANY known artifact (dev channel too) on a public server, which stays "prod" (read-only devtools);
  it holds until the next deploy of the branch, `api:unpin(player)` / `/tt unpin`, or the server closing.
  `api:experiment()` and `status().experiment` report it. Remote pins arrive on topic `TypeTorch/pin` (`{j?, pct?,
  a, b, by, t, unpin?}`, by JobId list or by `jobBucket(JobId) < pct`), and deploy messages may carry `ro` (1-99):
  only servers whose bucket (djb2 of the JobId, mod 100) is below it swap; the others keep their artifact, and new
  servers boot the head. On dev servers both topics are unsigned; prod servers need them signed (below).
- Signed prod deploys (0.3.0): prod servers (every public server, and private/reserved servers on a prod branch)
  take a deploy message, a stored head or a remote pin only with a valid Ed25519 signature (`sig` from a key in the
  group-owned key asset's `PublicKeys` minus `RevokedKeys`; `sigF` from the baked `FallbackPublicKey` until the key
  asset has loaded), the payload `Channel` attribute exactly `"prod"`, and a seq newer than the applied one.
  Payloads there may hold only Folders and ModuleScripts. The only unsigned head a prod server takes is the one in
  `BootstrapHeads` (exact branch, asset and seq). A re-signed head (`r = "resign"`, same asset) moves the head without
  a swap. Pins there must be signed too (dev menu pins are refused: use `typetorch pin`); a signed experiment may run
  any channel. Boot fail-safe: when no verified or bootstrap head loads at boot, the server boots the newest stored
  head that passes the prod checks, flagged `status().unverified` (updates stay strictly verified). Dev servers stay
  unsigned.
  `KeyAssetId`, `FallbackPublicKey` and `BootstrapHeads` are attributes on `ServerScriptService.TypeTorchKernel`,
  stamped by `typetorch kernel deploy` and read once at boot. `api:keys()` shows the trust state; `api:artifacts()`
  and `status()` carry `verified = {main, fallback}`. Setup and rules: [Prod signing](https://github.com/typetorch/docs/blob/main/guides/prod-signing.md).
- Studio local payload (0.3.1): in Studio only, when `ServerStorage.TypeTorchDev.Payload` (a Model shaped like an
  uploaded payload: `Server`, `Shared`, `Client`, `include`) exists, the kernel mounts a fresh clone of it instead of
  calling LoadAsset, with the same mount checks (only Folders and ModuleScripts; dev channel). The artifact id is
  `local-<HHMMSS UTC>`, the branch is `TypeTorchDev.Branch` or `dev`, and `status().localPayload` is `true`. Such a
  session never follows the branch head (deploy messages, the poll); Reload remounts a fresh clone, and pins or branch
  switches still load uploaded artifacts. Outside Studio the folder is ignored. The template's `studio.project.json`
  syncs it with Rojo (see the template README, "Testing in Studio").
- Bad deploys are safe (0.3.2):
  - **Health window:** a failed `onStart` (the framework reports it with `api:reportError`) or 3 errors from the new
    generation's own scripts within 30 s of ready roll the server back. Errors from outside the generation never
    count. 0.3.7 (`src/server/Health.luau`): each build carries its own thresholds, typetorch.json `"health"` stamped
    by `typetorch build` on the payload root as `HealthErrors` (1-100), `HealthWindow` (5-300 s) and `HealthRollback`
    (false: count errors, never roll back; the server reports `degraded`). Missing or out-of-bounds values fall back to
    3 / 30 s / on (listed in `status().health.invalid`); `status().health` reports `limit`, `window`, `rollback` and
    `source`. A place project without the module boots with no health window and warns.
  - **Last known good:** this server's history, then the branch's deployments (prod: only verified ones, or heads
    this server already ran), skipping artifacts that failed here. Also at boot when the head fails to start.
  - **Fleet status and deploy reports:** `api:fleetStatus()` (this server's heartbeat), `api:onDeployReport(fn)` (one
    report per deploy outcome, the last 20 replayed) and `api:deployReports()`; the kernel writes nothing to
    MemoryStore for them. With the signed settings' `fleet` = `{url, token}` (0.3.8; the ConfigService key
    `TypeTorchFleet` before) the kernel also
    posts heartbeats (every 30 s and on changes), reports, alerts and a closing notice to that fleet API itself, live
    and also while the generation is broken (`src/server/Fleet.luau`; the token is never logged). 0.3.9: when the API
    can't be reached (a restarting or dead quick tunnel: `NetFail`; a stale trycloudflare URL: `DnsResolve` / 530)
    every retry is jittered (+-25%), and after a request's retries all failed the sender backs off (30 s doubling to
    300 s); a 401/403/404 holds it off about 5 minutes; one success resets it. One warning line a minute at most, with
    the reason, and one "heartbeats work again" line after an outage; `status().fleet` adds `failures` (failed
    requests in a row) and `retryIn`.
  - **Boot budget:** a new server runs a playable generation within 15 s of start in every path (about 2 s
    normally): the boot reads run in parallel behind one 3 s gate, the key asset gets 3 s, and boot attempts get short
    load and ready caps; a head that runs out of boot time is retried in the background and swapped to when it works.
  - Client generation reports with one retry, `api:onClose(fn)` from the kernel's BindToClose, and every swap game
    code starts runs on a kernel thread. `status()` adds `health`, `failed`, `reports`, `fleet` and `clients`.
  - Messages across a swap: with a `ProtocolHash` attribute on the payload, client events of the previous artifact
    of the same hash reach the new generation; the resync names the dropped artifact and reaches only that client
    generation (`onResync`).
- Owners and owner switches (0.3.4; replaces the 0.3.3 owner override): two roles, owner (the experience creator, the
  owning group's owner, members with role "owner") and dev; a member with the old role "admin" is a dev, with a warning
  once per server. Owner-only: A/B pins, pins and unpins on public servers, rollbacks on servers with prod rules (see
  "Channel and rules" below), `requestReload`.
  The dev menu's Switch and Load here are ordinary switches and pins on every server: an owner switches a public server
  to any branch for its lifetime (never stored, so new servers still boot the signed prod head; a dev branch follows dev
  rules there; back to prod = Switch on the prod row, its verified head) and pins any known build on public and prod
  servers (the owner's own pin: any channel, modules only). Only from the owner's own client (kernel transport
  `__tt/switch`, `ClientApi:requestSwitch({branch | assetId})`, one request per player per 2 s) or `/tt branch` /
  `/tt pin`; the server API has no owner path. Private and reserved servers keep the stored switch for devs. Reload and
  Rollback always work. `status().switched = {by, name, at, branch, artifact?}`, the fleet heartbeat's `b` is the
  branch, and each switch or load posts an info alert (`branch_switch`, `build_load`) and is printed and logged.
- Channel and rules (0.3.9): two separate things. The CHANNEL is what the branch is: `prod` for the signed settings'
  `defaultBranch` or a branch the settings' `channels` configure prod, `dev` for every other branch. It is what a server
  reports: `status().channel`, `/tt status`, the fleet heartbeat `c`, game message tags, the dev menu. The RULES are
  what it enforces, exactly as before 0.3.9 (where they were reported as the "effective channel"): `prod` on every public
  server and on a server whose branch or running build is prod-channel by trusted sources: read-only devtools for
  non-owners, owner-only rollbacks (signatures stay `requiresSignatures`: public servers and trusted-prod branches).
  `status().rules`; `/tt status` says `branch dev (dev, prod rules)` for a dev branch on a public server. The payload
  API keeps `channel` = the rules (older frameworks gate their devtools on it, and games split data store names by
  `TypeTorch.channel`) and adds `rules` and `branchChannel`; `ReplicatedStorage.TypeTorch` has `Channel` (the rules) and
  `BranchChannel`.
- `/tt rollback` (0.3.9) on a server with no earlier generation (a fresh server that booted straight into a bad build)
  takes the branch's previous head: `heads.<branch>.prev` in the DataStore copy (the last 3 heads, newest first, kept by
  the CLI 0.8.1+ and by the kernel's own durable writes; MemoryStore never carries it), then the branch's deployment
  history (records written before 0.3.9 have no `prev`). A server that requires signatures takes only one that verifies
  like a current head (signed for prod, or the exact BootstrapHeads match; Channel "prod" at mount). Still a
  server-local swap (`server_rollback`, logged with `source = "branch"`, appliedSeq stays: it holds until the branch's
  next deploy). Nothing found: "no earlier build on this server or in prod's previous heads ... To roll the whole branch
  back: typetorch rollback prod".
- Durable heads (0.3.5): the CLI writes the DataStore `TypeTorch` key `heads` (and `deployments`) after every deploy
  message, so a deploy made while no server of that branch ran is no longer lost. The boot waits for the DataStore copy
  as well as MemoryStore (inside the 3 s boot gate) and boots the newer head; running servers read that copy about once
  a minute (`HEADS_DURABLE_SECONDS` = 55, one GetAsync per server per 60 s sync tick, out of a server's 60 + 10 x
  players DataStore reads a minute) and follow a newer head like a polled one (prod: the same signature rules). When
  the DataStore copy is ahead of MemoryStore, the server writes MemoryStore back (one UpdateAsync with the same
  `replaces` rule, so only the first server's write changes anything). Smoke: `--durable`.
- Never an empty server (0.3.6; the user: "IN NO POSSIBLE WAY players should load into an empty baseplate";
  `src/server/Fallback.luau`):
  - **Hold:** from the kernel's first line until a generation is ready, characters don't spawn
    (`Players.CharacterAutoLoads` off; on release it is back on and waiting players get `LoadCharacter`), and the kernel
    client covers the place with its own holding screen (opaque, "Starting...", a progress bar, a UIScale pop, no
    emojis), built from the `Hold` attribute on `ReplicatedFirst.TypeTorchKernelClient` before anything else waits.
    Measured: the server holds 2 ms after the kernel starts (before any player can join); the client's screen is up
    0 ms after its script starts. A swap of a running generation never holds. Games that spawn characters themselves
    set the `Players` attribute `TypeTorchHoldCharacters = false` (or keep `CharacterAutoLoads` off in the place): the
    kernel then never touches characters (the screen still shows while nothing runs).
  - **0.3.9, "Starting..." stayed up while the game ran:** ReplicatedFirst is replicated once, when a player joins, so
    the script's `Hold` is only the join snapshot; the 0.3.6-0.3.8 client read it first and kept "Starting..." for good
    when the player joined during the boot hold (on a test place the first player always does: their join starts the
    server). The client now follows `ReplicatedStorage.TypeTorch`'s `Hold` / `HoldReason` (live; set before that folder
    is parented) once it has it. The hold ends the moment a generation runs (before the dev checks, which yield on web
    calls); the watchdog releases a "start" hold it still finds on while a generation runs (3 s, warned); the dead man's
    moves stop once the kernel's own watchdog runs. Diagnostics: one line per hold change in the kernel's log ring (the
    dev menu's Logs, Logs > Upload), `[TypeTorch] hold start: <reason>` / `hold released: generation X running`, and on
    the client `[TypeTorch] screen up (Starting...): server hold start: <reason>` / `screen down: generation X running`;
    `HoldReason` next to `Hold` (server) and next to `Holding` (client). Fail-safe: when the client's own generation
    runs, the server has an `ActiveGeneration` and the hold still says "start" after 5 s, the client drops the screen
    and warns with the state it saw ("move" holds are never dropped). The screen's DisplayOrder is 2147483000
    (`HOLD_DISPLAY_ORDER`): above every game UI, under the framework's dev menu (+100).
  - **Fallbacks** when the head and the last-known-good chain ran nothing, in this order: (4) a build the branch's
    other servers run healthy for 30 s+ (a kernel roll call: an ask `{rc = 1}` on `TypeTorch/deploy`, so no extra
    permanent subscription; replies on `TypeTorch/peers/<JobId>`; the most common build wins; prod servers take it only
    when this kernel trusts it: a valid signature, a deployment entry that verifies, or `BootstrapHeads`); (3) the backup
    build `typetorch kernel deploy` bakes into the place, `ServerStorage.TypeTorchBackup`, mounted as a fresh clone with
    the payload checks (Channel `prod`, modules only), flagged `status().backup`, fleet `backup = true` and
    `h = "backup"`, alert `backup_build`; (5) background retries of the head, the last known good and peers (15 s,
    30 s, then every 60 s) until the head runs, each a normal swap; (2) at the boot budget, players (and new joiners)
    move to a healthy server of the branch (roll call), else a fresh one (private/reserved: a new reserved server on the
    branch), with a bounce count in the teleport data; the 3rd bounce is kicked ("Servers are restarting. Please rejoin
    in a minute."), logged and alerted (`bounce_kick`); alert `boot_failed_teleport`. Boot timings (simulated): peers
    5.0 s, asset outage to the backup 4.6 s (10.0 s when every LoadAsset hangs), moves at 15.1 s.
  - **Mid-swap failure:** when a swap stopped the old generation and nothing replaced it, `ActiveGeneration` is cleared
    (clients stop the dead client code) and the hold arms again until the chain above runs something. BindToClose in
    the middle of a swap runs the starting (else the stopped) generation's `onClose`. If the kernel itself errors before
    its boot finishes, the held players are still moved 5 s past the budget.
  - **Clients:** a client generation that failed after its own retry gets its client tree re-sent once
    (`PlayerGui.TypeTorchResend`, `__tt/resend`); if that fails too, the player moves to a healthy server of the branch
    (or rejoins). `status().clients` and the fleet status `clients` count `resent` and `moved`.
  - `status().fallback` = `{hold, backup, peers, chain, recovery, moving, clients}`.
- Security audit follow-ups (0.3.6, plans/18): the dev lists come from `typetorch access push` (0.3.8: the signed
  settings' `access`; 0.3.6-0.3.7: the ConfigService key `TypeTorchAccess`); the stored `heads`
  key holds at most 32 branches, and prod servers record another branch's deploy only when they know the branch or the
  message is signed; `place.project.json` sets `LoadStringEnabled` false (`kernel deploy --loadstring` turns it on for
  a test place).
- The signed settings record (0.3.8, `src/server/Settings.luau`; plans/20): ONE DataStore entry, `TypeTorch` /
  `settings` = `{ v = 1, seq, at, body, sig, sigF }`, replaces every ConfigService key. `body` is JSON text
  (`defaultBranch`, `channels`, `access`, `fleet`, `analytics`, `game`); `sig` / `sigF` are both prod keys' Ed25519
  signatures of `tt1settings \n seq \n at \n body` (Signing.settingsCanonical; the strict rule of signed deploys).
  Read at boot (inside the 3 s gate), every 55 s from the sync tick and right after a ping (`{"k":"settings","s":seq}` on
  `TypeTorch/deploy`); taken only when it verifies and its seq is newer; a missing, unsigned, invalid or older copy keeps
  the last good one. `api:settings()` (a copy, server only: it holds tokens), `api:onSettingsChanged(fn)`,
  `status().settings` (state, seq, age, verifiedBy, fields, refused). Written only by the CLI (`typetorch settings`,
  `fleet setup`, `access push`). The Studio `Registry` / `BootAssetId` overrides and the ConfigService log quieting are
  gone.
- Game messaging (0.3.8, `src/server/Messaging.luau`; plans/19 item 4): game topics ride ONE MessagingService topic,
  `TypeTorch/game`, subscribed on the first listener and held for the server's life (a swap never subscribes again).
  `api:messagingSubscribe(topic, fn)` (fn(data, meta), dropped with the generation), `api:messagingPublish(topic, data,
  {to})` (checks topic, JSON data and the 1 KiB limit counted on the JSON-escaped envelope at once, then queues: a
  per-server bucket of 150 + 60 x players a minute, the universe's rate on the topic (every server sees every message;
  at 60 a minute publishes wait), retries after 1, 3, 9 s), `api:messagingStatus()`, `status().messaging`. Envelopes
  carry the sender's JobId, branch, channel (0.3.9: what its branch is; before, the rules), server type and place
  version; `to = "prod" | "branch"` is
  filtered by the receivers. A message that arrives mid-swap is replayed to the next generation's first listener of its
  topic. Studio loops back and never touches MessagingService. `api:onRollCall(fn)` holds the framework's roll call ask
  topic `TypeTorch/rollcall` for the running generation (same protocol as before). Subscriptions: deploy, pin, rekey,
  plus game and roll call once used (Roblox allows 20 + 8 x players per server).
- Loading screens (0.3.8, plans/19 item 13): the kernel client sets `ClientReady = true` (the first client generation
  runs), `ClientGeneration` and `Holding` (the holding screen's mode) on `ReplicatedFirst.TypeTorchKernelClient`. The
  game's `ReplicatedFirst` attributes `TypeTorchBootScreen = "<ScreenGui name>"` (cloned at once, removed when the
  first client generation runs and the hold ends, at most 60 s) and `TypeTorchKernelScreen = false` (the game draws its
  own) are copied onto that script by the server before anyone joins; until then the kernel's "Starting..." stays off.
  Moves ("Reconnecting...") and later holds always show the kernel's screen.
- Detached jobs (0.3.8): `api:runDetached(fn, done?)` runs `fn()` on a kernel thread, so a generation's stop (and its
  hard stop) never cuts it off: for library calls that must not stop halfway (a ProfileStore load, save or release).
  `done(ok, result)` runs only while the calling generation still runs (a stopped generation's result is dropped: the
  job writes what must survive into `persist`). At most `DETACHED_MAX` (256) run at once (then it errors); one running
  past `DETACHED_SLOW` (60 s) is logged once; errors go to the log with the generation's name and never count toward
  its health window; `status().detached` = `{ running, started, finished, failed, slow, max, oldest?, lastError? }`. A
  job keeps the old generation's closures (and what they reference) alive until it ends.
- Tests (Lune): `lune run scripts/test-ed25519.luau` (RFC 8032 vectors, SHA-512/256, the signing rules),
  `lune run scripts/test-access.luau`, `lune run scripts/test-fleet.luau` (0.3.9: the fleet sender's backoff, hold and
  log lines on a fake clock) and
  `lune run scripts/smoke-kernel.luau` (boots the real server kernel with stubbed services; also `--fallback`,
  `--dev`, `--vip`, `--bootstrap`, `--bootstrap-only`, `--blind`, `--empty`, `--studio-local`, `--health`,
  `--health-prod`, `--lkg-boot`, `--client`, `--fleet`, `--switch`, `--durable`, 0.3.6's `--hold`, `--hold-optout`,
  `--peers`, `--peers-untrusted`, `--backup`, `--recover`, `--teleport`, `--bounce`, `--mid-swap`, `--client-fail`,
  `--kernel-crash`, `--heads-cap`, `--access`, 0.3.7's `--health-config` and `--health-missing`, 0.3.8's
  `--messaging`, `--messaging-studio`, `--messaging-missing`, `--client-boot`, `--client-own`, `--settings`,
  `--settings-missing` and `--detached`, 0.3.9's `--rollback-prev`, and `--boot-budget`, which runs 25 boot scenarios
  with simulated slow or failing dependencies and
  checks each one runs a generation within 15 s, or moves the waiting player at the budget when nothing can run).
- `src/server/vendor/ed25519/`: Ed25519 verify and SHA-512/SHA-256 from
  [rbx-cryptography](https://github.com/daily3014/rbx-cryptography) 3.1.4 (MIT, daily3014), see its `LICENSE`.

Contract with payloads: `Server.boot.boot(kernel)` / `Client.boot.boot(kernel)` return a stop function (0.2.2 passes
it what replaces the generation). The typed view
of `kernel` is `ServerKernel` / `ClientKernel` in `@typetorch/framework`. Guides: [typetorch/docs](https://github.com/typetorch/docs).
