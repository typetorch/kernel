# @typetorch/kernel

The small loader baked into the place. It is plain Luau (no compile step, no roblox-ts runtime), so it never
shares a RuntimeLib with the payloads it loads. Changing it needs a server restart (`typetorch kernel deploy`).

- `src/server/` → `ServerScriptService.TypeTorchKernel`: boot, branch choice, LoadAsset + side-by-side mounting,
  swaps with soft + hard stop, automatic rollback, registry (ConfigService + in-game DataStore), dev access,
  stable transport, logs, `/tt` chat commands.
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
  servers boot the head. In 0.2.x both topics are unsigned (see `../plans/12-audit.md`, S-C2).
- Signed prod deploys (0.3.0): prod servers (every public server, and private/reserved servers on a prod branch)
  take a deploy message, a stored head or a remote pin only with a valid Ed25519 signature (`sig` from a key in the
  group-owned key asset's `PublicKeys` minus `RevokedKeys`; `sigF` from the baked `FallbackPublicKey` until the key
  asset has loaded), the payload `Channel` attribute exactly `"prod"`, and a seq newer than the applied one.
  Payloads there may hold only Folders and ModuleScripts. The only unsigned head a prod server takes is the one in
  `BootstrapHeads` (exact branch, asset and seq). A re-signed head (`r = "resign"`, same asset) moves the head without
  a swap. Pins there must be signed too (dev menu pins are refused: use `typetorch pin`). Dev servers stay unsigned.
  `KeyAssetId`, `FallbackPublicKey` and `BootstrapHeads` are attributes on `ServerScriptService.TypeTorchKernel`,
  stamped by `typetorch kernel deploy` and read once at boot. `api:keys()` shows the trust state; `api:artifacts()`
  and `status()` carry `verified = {main, fallback}`. Format: `../plans/03-artifact.md` "Signed prod messages";
  rules: `../plans/01-kernel.md`.
- Tests (Lune): `lune run scripts/test-ed25519.luau` (RFC 8032 vectors, SHA-512/256, the signing rules) and
  `lune run scripts/smoke-kernel.luau` (boots the real server kernel with stubbed services; also `--fallback`,
  `--dev`, `--vip`, `--bootstrap`, `--bootstrap-only`, `--nothing`).
- `src/server/vendor/ed25519/`: Ed25519 verify and SHA-512/SHA-256 from
  [rbx-cryptography](https://github.com/daily3014/rbx-cryptography) 3.1.4 (MIT, daily3014), see its `LICENSE`.

Contract with payloads: `Server.boot.boot(kernel)` / `Client.boot.boot(kernel)` return a stop function (0.2.2 passes
it what replaces the generation). The typed view
of `kernel` is `ServerKernel` / `ClientKernel` in `@typetorch/framework`. Design: `../plans/01-kernel.md`.
