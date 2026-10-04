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

Contract with payloads: `Server.boot.boot(kernel)` / `Client.boot.boot(kernel)` return a stop function. The typed view
of `kernel` is `ServerKernel` / `ClientKernel` in `@typetorch/framework`. Design: `../plans/01-kernel.md`.
