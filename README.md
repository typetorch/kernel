# @typetorch/kernel

The small loader baked into the place. It is plain Luau (no compile step, no roblox-ts runtime), so it never
shares a RuntimeLib with the payloads it loads. Changing it needs a server restart (`typetorch kernel deploy`).

- `src/server/` → `ServerScriptService.TypeTorchKernel`: boot, branch choice, LoadAsset + side-by-side mounting,
  swaps with soft + hard stop, automatic rollback, registry (ConfigService + in-game DataStore), dev access,
  stable transport, logs, heartbeat and deploy reports (`Reports`), `/tt` chat commands. A place project that maps
  these files one by one must map `Reports` too (0.3.2; without it the kernel boots without reports).
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
  `api:requestReload(player)` (owner and admins). Clients get the full artifact identity, the server type and their
  own `start`.
- A/B experiments and rollouts (0.2.3): `api:pinArtifact(player, assetId, { experiment = true })` lets the owner or
  an admin run ANY known artifact (dev channel too) on a public server, which stays "prod" (read-only devtools);
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
  - **Heartbeat and reports:** the kernel writes the server list (MemoryStore SortedMap `TypeTorchServers`, every
    60 s, also when the game is broken) and one report per deploy outcome (`TypeTorchReports`, key
    `<seq, 10 digits>/<JobId>`), so `typetorch servers` and `deploy --wait` work. The contract is in
    `src/server/Reports.luau`.
  - Client generation reports with one retry, `api:onClose(fn)` from the kernel's BindToClose, and every swap game
    code starts runs on a kernel thread. `status()` adds `health`, `failed`, `heartbeat` and `clients`.
- Tests (Lune): `lune run scripts/test-ed25519.luau` (RFC 8032 vectors, SHA-512/256, the signing rules) and
  `lune run scripts/smoke-kernel.luau` (boots the real server kernel with stubbed services; also `--fallback`,
  `--dev`, `--vip`, `--bootstrap`, `--bootstrap-only`, `--blind`, `--empty`, `--studio-local`, `--health`,
  `--health-prod`, `--lkg-boot`, `--client`).
- `src/server/vendor/ed25519/`: Ed25519 verify and SHA-512/SHA-256 from
  [rbx-cryptography](https://github.com/daily3014/rbx-cryptography) 3.1.4 (MIT, daily3014), see its `LICENSE`.

Contract with payloads: `Server.boot.boot(kernel)` / `Client.boot.boot(kernel)` return a stop function (0.2.2 passes
it what replaces the generation). The typed view
of `kernel` is `ServerKernel` / `ClientKernel` in `@typetorch/framework`. Guides: [typetorch/docs](https://github.com/typetorch/docs).
