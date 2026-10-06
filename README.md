# @typetorch/kernel

The small loader baked into the place. It is plain Luau (no compile step, no roblox-ts runtime), so it never
shares a RuntimeLib with the payloads it loads. Changing it needs a server restart (`typetorch kernel deploy`).

- `src/server/` → `ServerScriptService.TypeTorchKernel`: boot, branch choice, LoadAsset + side-by-side mounting,
  swaps with soft + hard stop, automatic rollback, registry (ConfigService + in-game DataStore), dev access,
  stable transport, logs, the fleet API sender (`Fleet`), the fallbacks (`Fallback`), `/tt` chat commands. A place
  project that maps these files one by one must map `Fleet` (0.3.2) and `Fallback` (0.3.6) too; without them the kernel
  boots without the fleet API, or without the hold, peers, backup and moves, and says so.
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
    count.
  - **Last known good:** this server's history, then the branch's deployments (prod: only verified ones, or heads
    this server already ran), skipping artifacts that failed here. Also at boot when the head fails to start.
  - **Fleet status and deploy reports:** `api:fleetStatus()` (this server's heartbeat), `api:onDeployReport(fn)` (one
    report per deploy outcome, the last 20 replayed) and `api:deployReports()`; the kernel writes nothing to
    MemoryStore for them. With the server-only ConfigService key `TypeTorchFleet` = `{url, token}` the kernel also
    posts heartbeats (every 30 s and on changes), reports, alerts and a closing notice to that fleet API itself, live
    and also while the generation is broken (`src/server/Fleet.luau`; the token is never logged).
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
  once per server. Owner-only: A/B pins, pins and unpins on public servers, prod-channel rollbacks, `requestReload`.
  The dev menu's Switch and Load here are ordinary switches and pins on every server: an owner switches a public server
  to any branch for its lifetime (never stored, so new servers still boot the signed prod head; a dev branch follows dev
  rules there; back to prod = Switch on the prod row, its verified head) and pins any known build on public and prod
  servers (the owner's own pin: any channel, modules only). Only from the owner's own client (kernel transport
  `__tt/switch`, `ClientApi:requestSwitch({branch | assetId})`, one request per player per 2 s) or `/tt branch` /
  `/tt pin`; the server API has no owner path. Private and reserved servers keep the stored switch for devs. Reload and
  Rollback always work. `status().switched = {by, name, at, branch, artifact?}`, the fleet heartbeat's `b` is the
  branch, and each switch or load posts an info alert (`branch_switch`, `build_load`) and is printed and logged.
- Durable heads (0.3.5): the CLI writes the DataStore `TypeTorch` key `heads` (and `deployments`) after every deploy
  message, so a deploy made while no server of that branch ran is no longer lost. The boot waits for the DataStore copy
  as well as MemoryStore (inside the 3 s boot gate) and boots the newer head; running servers read that copy about once
  a minute (`HEADS_DURABLE_SECONDS` = 55, one GetAsync per server per 60 s sync tick, out of a server's 60 + 10 x
  players DataStore reads a minute) and follow a newer head like a polled one (prod: the same signature rules). When
  the DataStore copy is ahead of MemoryStore, the server writes MemoryStore back (one UpdateAsync with the same
  `replaces` rule, so only the first server's write changes anything). Smoke: `--durable`.
- Log noise (0.3.5): the engine's orange `ConfigService: Config value not found for key "TypeTorch".` (the registry is
  optional and never written with an API key) is one info line in the kernel's log ring, `[TypeTorch] no ConfigService
  registry (optional)` (the dev menu shows it dim); repeats are dropped, and `TypeTorchFleet` / `TypeTorchAnalytics`
  get the same treatment. The game's own missing keys stay warnings. Roblox's own console still shows the engine's
  line.
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
- Security audit follow-ups (0.3.6, plans/18): the dev lists come from the server-only ConfigService key
  `TypeTorchAccess` (`typetorch access push`) when it exists, re-read on every ConfigService update; the stored `heads`
  key holds at most 32 branches, and prod servers record another branch's deploy only when they know the branch or the
  message is signed; `place.project.json` sets `LoadStringEnabled` false (`kernel deploy --loadstring` turns it on for
  a test place).
- Tests (Lune): `lune run scripts/test-ed25519.luau` (RFC 8032 vectors, SHA-512/256, the signing rules) and
  `lune run scripts/smoke-kernel.luau` (boots the real server kernel with stubbed services; also `--fallback`,
  `--dev`, `--vip`, `--bootstrap`, `--bootstrap-only`, `--blind`, `--empty`, `--studio-local`, `--health`,
  `--health-prod`, `--lkg-boot`, `--client`, `--fleet`, `--switch`, `--durable`, 0.3.6's `--hold`, `--hold-optout`,
  `--peers`, `--peers-untrusted`, `--backup`, `--recover`, `--teleport`, `--bounce`, `--mid-swap`, `--client-fail`,
  `--kernel-crash`, `--heads-cap`, `--access`, and `--boot-budget`, which runs 25 boot scenarios with simulated slow or failing dependencies and
  checks each one runs a generation within 15 s, or moves the waiting player at the budget when nothing can run).
- `src/server/vendor/ed25519/`: Ed25519 verify and SHA-512/SHA-256 from
  [rbx-cryptography](https://github.com/daily3014/rbx-cryptography) 3.1.4 (MIT, daily3014), see its `LICENSE`.

Contract with payloads: `Server.boot.boot(kernel)` / `Client.boot.boot(kernel)` return a stop function (0.2.2 passes
it what replaces the generation). The typed view
of `kernel` is `ServerKernel` / `ClientKernel` in `@typetorch/framework`. Guides: [typetorch/docs](https://github.com/typetorch/docs).
