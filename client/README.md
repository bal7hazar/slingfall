# Slingfall client

Vite + TypeScript + PixiJS v8 client of Slingfall. Live mode (lot G6b, docs/DESIGN.md D8): the
page loads a level, runs the Cairo replay itself (`init`, then `step_chunk` chunks per shot) in
the cairo-vm wasm worker of lot G1c, streams each shot's frames and events to the renderer while
the VM runs, and shows the level's D4 outputs at its end. Without the wasm it plays the recorded
`public/traces/pile10.json` (lot G6). Scalars stay raw Q32.32 integers (decimal strings) and
become `number` only for drawing.

## Run

Node 24. From this directory:

```sh
nice -n 10 npm ci     # install exactly package-lock.json
npm run dev           # dev server on http://localhost:5173
npm run lint          # ESLint + tsc --noEmit
npm test              # Vitest, once
npm run build         # type-check and bundle into dist/, with dist/vm/ (below)
npm run dev:sepolia   # dev server against the Sepolia deployment (.env.sepolia, docs/testers.md)
npm run build:sepolia # the same build for Sepolia; `npm run smoke:sepolia` checks its entry script
```

`VITE_BASE=/sub/path/` serves the built app from a sub-path (GitHub Pages: `/slingfall/`); every
fetched URL goes through Vite's `base` (`import.meta.env.BASE_URL`).

Live mode needs the wasm runner: `vm/scripts/build.sh` once (Rust, ~2 min; `vm/README.md`). The
replay executables are committed (`vm/fixtures/replay/`, `vm/scripts/fetch-executables.sh`).
`npm run dev` serves both from the client root at `/vm/...`; `npm run build` copies them into
`dist/vm/` (`vite.config.ts`), and without `vm/pkg/` the build still succeeds (a warning) and the
page says "VM not built" and plays the recorded trace.

The page (`?level=pile10|cores3|one_block`, default pile10): press within 1.5 m of the sling
anchor and drag to aim (an integer pull in `[-1024, 1024]²` clamped to the disk `pull_radius`;
the dotted arc is the exact flight of the pebble, up to the first tick inside a body's box: a display cut, not physics); releasing runs that shot in the worker, from
the previous shot's state, with the inputs so far. Frames play at 60 Hz as they arrive
(interpolated for display only); when they lag real time (the impact: 3x the Cairo steps per
tick of the flight) the playback slows to their arrival rate and the HUD says "simulating…"
(**slow-motion impact**, `src/render/live.ts`). Damaged bodies flash, destroyed ones fade out at
their last pose (`src/render/effects.ts`); the HUD shows score, shots left and tick. At the
level's end a panel shows won / lost, the score, and the 10 output felts a proof of the level will
carry (`inputs_hash` and `final_state_hash` highlighted), computed by the `outputs` executable in
the worker; **Copy inputs** copies the shots as JSON (`{player, shots: [{pull_x, pull_y,
delay}]}`); **Retry** restarts the level from the state `init` returned (no new `init`).
With a deployed contract configured (`VITE_SLINGFALL_ADDRESS`, `VITE_RPC_URL`, `VITE_ATTEST_URL`,
from `deploy/devnet.env`; lot G9, [`docs/e2e.md`](../docs/e2e.md)) the panel adds **Submit on
Starknet**: connect a wallet (Cartridge Controller, a get-starknet browser wallet, or on a devnet
its prefunded account), give the proof path if the local prover made one, and submit: the page
recomputes the outputs for the wallet's address, gets `[r, s]` from the attestation service,
sends `submit(outputs, [r, s])` through the wallet and shows the transaction hash, its gas, the
player's best and the leaderboard. Without the variables the section (and starknet.js) is left out.
`VITE_NETWORK=sepolia` (`.env.sepolia`, lot C1) hides the devnet account, defaults the RPC to the public
Sepolia node (`VITE_STARKNET_RPC_URL`, else `VITE_RPC_URL`), links the contract and the player's
`LevelValidated` transactions on Voyager Sepolia and shows the on-chain level hash; when the contract's
`verifier()` is `Satellite` the button is **Prove (settled)** (proof, then **Settle**) instead of the attested
**Submit**.
**Play/Pause** (or Space) and the slider scrub the level so far. `?autoshot=px,py;px,py` releases
those pulls by itself (headless checks). The console logs each shot's figures (release to first
frame, ticks, steps, seconds, chunks, wasm) and the outputs.

## Layout

| path | role |
|---|---|
| `src/trace/types.ts` | trace format v1 types, `fixedToNumber` |
| `src/trace/source.ts` | `TraceSource` interface, `RecordedTraceSource`, `parseTrace` (validating) |
| `src/trace/lines.ts` | the replay's trace lines v1 (`parseTraceLine`, `LevelHeader`, `linesToTrace` = `tracec.py trace`); the spike's `tick <i> y <raw>` parser |
| `src/trace/synth.ts` | deterministic generator of the hand-made `pile10` trace (`BigInt`, no floats in the state) |
| `src/aim/fixed.ts` | Q32.32 `mulFloor`, `isqrtCeil` |
| `src/aim/pull.ts` | `clampPull` (D3 integer clamp), drag to pull mapping |
| `src/aim/arc.ts` | `flightArc`: the exact arc, rapier's substepped free flight (`SUBSTEPS = 4` Euler steps of `dt // 4` per tick, mirrors `SOLVER_ITERATIONS`); the formula is documented at the top of the file |
| `src/aim/contact.ts` | body AABBs at the settled poses: where the preview stops (display only) |
| `src/aim/controller.ts` | pointer handling and the overlay drawing |
| `src/render/` | `buffer` (frames as `f64` columns), `scene` (PixiJS bodies), `camera`, `playback`, `hud`, `live` (arrival rate, slow-motion speed), `effects` (flashes, fade-outs) |
| `src/game/session.ts` | `LevelSession`: the shot loop without DOM (`init` once, a shot per release from the previous state, the inputs kept, level over from the state header, outputs, retry) |
| `src/game/stage.ts` | what one level draws: buffer, scene, effects, camera, aim |
| `src/chain/` | the Submit step (lot G9): `slingfall` (calldata, reads, `LevelValidated`, gas), `attest` (the attestation client), `submission` (the flow, DOM-free), `wallet` (Cartridge / get-starknet / devnet account), `config` (`VITE_*`), `panel` (DOM) |
| `src/main.ts` | wiring: level choice, live playback, HUD, end-of-level panel, recorded fallback |
| `src/vm/` | the cairo-vm worker: programs (`slingfallProgram`, `ballDropProgram`), chunk sizing rule, chunk loop, worker, `VmClient`, `WorkerTraceSource` |
| `public/levels/` | copies of `fixtures/levels/*.json` and `*.felts.json` (checked by `src/game/levels.test.ts`) |
| `vm/` | the Rust runner compiled to wasm, the replay executables, scripts and fixtures ([`vm/README.md`](vm/README.md)) |

## Trace format v1

```
{ "version": 1,
  "level":  { "bounds": {min_x, min_y, max_x, max_y}, "sling_anchor": {x, y},
              "gravity_y", "launch_scale", "pull_radius": 1024, "shots": 3,
              "bodies": [{ "handle", "kind": "static|block|core", "material",
                           "shape": {"type": "ball", radius} | {"type": "cuboid", hx, hy}
                                  | {"type": "polygon", vertices: [{x, y}]}
                                  | {"type": "halfspace", normal: {x, y}},
                           "pose": {x, y, re, im} }] },
  "frames": [{ "tick", "bodies": [{ "handle", x, y, re, im, "asleep" }] }],
  "events": [{ "tick", "kind": "damage", handle, hp } | { "kind": "destroyed", handle }
           | { "kind": "score", points, total } | { "kind": "shot_end", shot }] }
```

Every scalar named above without a type is a raw Q32.32 `i64` as a decimal string; `tick`,
`handle`, `hp`, `points`, `total`, `shot`, `pull_radius` and `shots` are plain integers. A frame
lists the bodies that exist at that tick: a dynamic body absent from a frame is not there (not yet
spawned, or removed); a static body absent from a frame keeps its level pose. A handle that is in
no `level.bodies` entry is a pebble (ball, r = 0.25 m, D12).

## Regenerating the `pile10` fixture

`fixtures/traces/pile10.json` (canonical) and `public/traces/pile10.json` (the copy Vite serves)
are generated by `src/trace/synth.ts`, and `synth.test.ts` fails when they differ from its
output. To regenerate: delete both files, run `npm test` twice (the first run writes them, and
may fail other suites that raced with the write). CI never regenerates.

## Cairo VM worker (`vm/`, `src/vm/`)

The replay runs in the browser on cairo-vm compiled to wasm, in chunks, inside one persistent
Web Worker (lot G1c; details, measured figures and the chunk sizing rule in
[`vm/README.md`](vm/README.md)). The wasm is built locally and is not committed:

```sh
vm/scripts/build.sh   # Rust via rustup: vendors cairo-vm @ f7ac327f, builds vm/pkg/ and vm/pkg-node/
npm test              # now also runs src/vm/vm.test.ts on the wasm (skipped without vm/pkg-node/)
```

`WorkerTraceSource` (`src/vm/index.ts`, re-exported by `src/trace/source.ts`) streams a shot's
frames and events from the worker, parsed from the trace lines v1 (`src/trace/lines.ts`); the
caller passes the `TraceLevel`. The app build never needs the wasm: the worker imports it at run
time.

## Not verified in a browser

The page has been type-checked, linted, tested and built. The sandboxes of G6 and G6b could not
launch a browser (G6b: Firefox is installed, its launch was refused), so the visual result is
unchecked. G6b measured the same code paths in Node instead: `vm/scripts/worker-check.mjs` runs
the page side (`VmClient`, `LevelSession`) on the main thread and the worker (`serveVm`) in a
`worker_threads` Worker (figures in `vm/README.md`). `vm/scripts/browser-check.py` is the
headless-Firefox check (console output with timestamps and a screenshot after an automatic shot);
it has not been run.
