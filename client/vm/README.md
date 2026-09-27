# `client/vm/`: the Cairo replay on cairo-vm, in wasm, in a Web Worker

The client runs the replay executable itself (docs/DESIGN.md D1, D8): scarb's `executable.json`
on lambdaclass cairo-vm 3.2 compiled to `wasm32-unknown-unknown`, **chunked** (`init(level) ->
state`, then `step_chunk(state, inputs, k) -> state'` until the shot ends), each chunk a fresh
VM run in one persistent worker, `println!` ticks streamed to the page while the VM runs.
Promoted from the spike `pm/spikes/wasm-vm` (docs/research/03 and 04).

| path | what |
|---|---|
| `runner/` | Rust crate `slingfall-vm-runner`: executable loader + hint processor (wasm-bindgen API below) and the native binary `slingfall-run` |
| `runner/cairo-vm-reserve.patch` | +16 lines to cairo-vm: `Memory::reserve_segment`, `Memory::segment_capacities` |
| `scripts/vendor.sh` | clones cairo-vm @ `f7ac327f` into `vendor/cairo-vm` and applies the patch |
| `scripts/build.sh` | wasm32 build + `wasm-bindgen` into `pkg/` (web) and `pkg-node/` (Node) |
| `scripts/bench.mjs` | the Node figures below |
| `scripts/fetch-executables.sh` | copies the replay executables into `fixtures/replay/` (`--build` builds them first) |
| `scripts/worker-check.mjs` | lot G6b: page side + `worker_threads` worker on pile10, the page's figures in Node |
| `scripts/browser-check.py` | lot G6b, H1: headless Firefox on `dist/` (console + screenshot); `--firefox <path>`, `--timeout`; never run (below) |
| `fixtures/replay/` | the executables the client runs: `init`, `step_chunk`, `outputs` and `main_trace` (tests), all four built from `crates/slingfall_replay` (lots G4, G4c) |
| `fixtures/pile10-reference.main_trace.txt` | `scarb execute` of `main_trace` on pile10, reference shot (the lines and outputs the tests compare with) |
| `fixtures/pile10-*.args.json` | `tools/tracec/tracec.py args` on pile10 (the argument-encoding tests) |
| `fixtures/ball_drop/` | the G1c stand-in executable's source (spike G1b copy, registry `rapier2d` `=0.1.0-alpha.2`, lot H1) |
| `fixtures/ball_drop.executable.json` | its build (the runner's bit-exactness tests and `bench.mjs` load it) |
| `fixtures/pile12-mode3-120.state.txt` | golden: pile12's state after 120 uninterrupted ticks (`mode 3`, native) |
| `../src/vm/` | TypeScript: sizing rule, chunk loop, worker, `WorkerTraceSource` |

`vendor/`, `pkg/`, `pkg-node/`, `tools/` and the `target/` directories are git-ignored.

## Build

Rust through rustup (the toolchain 1.89.0 and the wasm32 target come from
`runner/rust-toolchain.toml`), git, curl. From the repository root:

```sh
client/vm/scripts/build.sh            # vendor.sh, then pkg/ and pkg-node/ (~2 min cold, -j 4, nice 10)
client/vm/scripts/build.sh --native   # also runner/target/release/slingfall-run
(cd client/vm/runner && nice -n 10 cargo test -j 4 --lib)   # runner unit tests
(cd client && npm test)               # includes src/vm/vm.test.ts once pkg-node/ exists (~1 min)
```

`build.sh` fetches `wasm-bindgen` 0.2.100 (it must equal the crate's pinned version) into `tools/`
unless `$WASM_BINDGEN` or `PATH` has it; `--wasm-opt` runs binaryen's `wasm-opt -O3` (no speed gain
measured in the spike, only a smaller `.wasm`). The `.wasm` is 1.5 MB.

**cairo-vm without a fork.** `runner/Cargo.toml` depends on cairo-vm as a git dependency pinned to
`f7ac327f8f21abd05dd6e808e513010443d9742e` (workspace version 3.2.0, the cairo-vm of cairo-lang
2.19.4) and redirects it with `[patch."https://github.com/lambdaclass/cairo-vm"]` to
`../vendor/cairo-vm/vm`, which `vendor.sh` creates (depth-1 fetch of that commit, `git apply` of
the patch; idempotent; `CAIRO_VM_URL` overrides the remote). The patch pre-sizes the execution
segment (`Vec::try_reserve_exact`) so that it grows without doubling copies: +13 % steps/s and
710 -> 320 MB per 10-tick chunk in the spike. `runner/Cargo.lock` started from cairo-vm's own lock
at that commit: a fresh resolution picks `cairo-lang-*` 2.12.4, which does not compile against
cairo-vm's `cairo-lang-casm` 2.12.0-dev.0.

**Native.** `runner/target/release/slingfall-run <executable.json> "<args>" [--reserve=CELLS]
[--quiet-prints]` prints the ticks, `returned: <felts>` and a summary on stderr. The golden state
was produced with `slingfall-run client/vm/fixtures/ball_drop.executable.json "3 3 120 0 0"` (lot H1 regenerated it
with `scarb --manifest-path client/vm/fixtures/ball_drop/Scarb.toml execute --arguments 3,3,120,0,0
--print-program-output`: drop the first printed felt, the array length, and write negatives as `P - x`).

**Replay executables.** `client/vm/scripts/fetch-executables.sh --build` builds
`crates/slingfall_replay`, then copies `init`, `step_chunk`, `main_trace` and `outputs` into
`fixtures/replay/` (committed: 28 MB of JSON, the app serves `init`, `step_chunk` and `outputs`).
Rebuild them whenever the replay or its dependencies change: the `vm` CI job rebuilds them and
fails on `git diff --exit-code client/vm/fixtures/replay/` (lot G4c), and the
tests compare them with `fixtures/pile10-reference.main_trace.txt`, recorded with
`scarb execute --executable-name main_trace --arguments-file client/vm/fixtures/pile10-reference.args.json
--print-program-output` (the args from `tracec.py args fixtures/levels/pile10.felts.json
--shot=-600,-392`).

**Fixture.** `scarb --manifest-path client/vm/fixtures/ball_drop/Scarb.toml build`, then copy
`fixtures/ball_drop/target/dev/ball_drop.executable.json` to `fixtures/`, rerun `slingfall-run`
for the golden state. Arguments: `mode scene steps trace <len> <state felts..>`; mode 1 =
`init(scene)`, 2 = `step_chunk(state, steps)`, 3 = build + `steps` ticks + save (the
bit-exactness reference); scene 0 = ball_drop, 3 = pile12 (12 boxes hit by a ball). With
`trace = 1` every tick prints `tick <i> y <raw>` (y of the ball).

**Browser check.** `client/vm/scripts/browser-check.py` serves `client/dist/` (after `build.sh` and
`npm run build`) and shoots it with `firefox --headless --screenshot`, printing the page's console:

```sh
python3 client/vm/scripts/browser-check.py --firefox /path/to/firefox --timeout 180 --out shot.png
```

`--firefox` defaults to `$FIREFOX`, then `firefox` on `PATH`; Firefox is killed `--timeout` seconds
after `--hold`. Neither G6b nor H1 could run it: their sandboxes refused to launch Firefox (and H1's
could not fetch cairo-vm to build `pkg/`). Run it where Firefox launches.

## JS API (wasm-bindgen, `pkg/` and `pkg-node/`)

```ts
const runner = new Runner(executableJsonText);           // parse once per worker (~0.4 s)
const r = runner.run('2 3 10 1 2050 …', {                // decimal felts, `-x` = P - x
  reserveCells: 4_000_000,                               // pre-size the execution segment
  onPrint: (text) => …,                                  // every println!, synchronously
});
// r = { steps, memoryCells, execCells, execCapacity, returned: string[] }  (returned = main's Array<felt252>)
wasmMemoryBytes();                                       // linear memory size (it only grows)
```

A Cairo panic or VM error throws (`Error` with the VM message and the panic data).

## TypeScript (`client/src/vm/`)

- `sizing.ts`, the **chunk sizing rule**: the first stepping chunk has `firstTicks` = 5 ticks;
  after that, K = floor(`targetSteps` / previous chunk's steps per tick), clamped to [1, 20]
  and to the ticks left; `targetSteps` = 3.5M (D8: 2-5M). The execution segment is reserved at
  `reserveFactor` x the previous chunk's execution-segment cells per tick x K (1.25; the first
  chunk assumes 700k cells per tick), between a floor and a ceiling of 5M cells (K is lowered
  until the reserve fits the ceiling). D8 says 1.1. Measured, 1.1 is overrun when steps per tick
  rise by more than 10 % from one chunk to the next, and the segment then doubles (556 MB instead
  of 330 MB). `ContactCut` (lot Q2, below) ends the flight chunk just before the predicted
  contact tick.
- `cut.ts` (lot Q2): the predicted contact tick of a shot, from the aim arc (`src/aim/arc.ts`) and
  the level felts; loaded by the worker only (its `aim/` imports have no `.ts` extension, so plain
  Node cannot load it; `serve.ts` and `shot.ts` take a predictor).
- `program.ts`: the `ChunkProgram` interface (`init` / `step_chunk` / `outputs` arguments, ticks
  left of a shot, the line parser) and two programs: `slingfallProgram` (lot G6b: the replay's
  argument layouts, `ChunkState` header, trace lines v1, `Outputs` decoding) and
  `ballDropProgram` (the G1c stand-in).
- `shot.ts`: `runInit`, `runShot(engine, program, level, inputs, { shot, state, ... })` (the chunk
  loop, from a given state) and `runOutputs` (pure, used by the worker, the tests and
  `bench.mjs`). A `VmEngine` holds one `Runner` per executable (`chunk`, `init`, `outputs`).
- `worker.ts` (module Web Worker; gives `serve.ts` the `cut.ts` predictor) + `serve.ts` (its
  message loop; keeps the last frame of a shot for the next shot's prediction) + `protocol.ts`; `index.ts`:
  `VmClient` (one persistent worker: `ready`, `init(level)`, `shot(request, handlers)`,
  `outputs(state, inputs)`; frames, events and chunk reports stream while a request runs) and
  `WorkerTraceSource(client, request, { level, onChunk })` (a `TraceSource` of kind `'worker'`,
  re-exported by `src/trace/source.ts`; `level()` returns the `TraceLevel` the caller passes;
  `events` fills as the shot runs).
  `DEFAULT_LOAD` points at `/vm/pkg/slingfall_vm_runner.js` and the three executables under
  `/vm/fixtures/replay/`; `BALL_DROP_LOAD` at the stand-in. `npm run dev` serves them from the
  client root, `npm run build` copies them into `dist/vm/` (`../vite.config.ts`). The wasm is
  imported at run time, so the build never needs it.

## The slingfall replay executables (lot G4; wired by G6b)

`crates/slingfall_replay` builds one `executable.json` per entry point
(`scarb --manifest-path crates/slingfall_replay/Scarb.toml build`, then
`crates/slingfall_replay/target/dev/init.executable.json` and `step_chunk.executable.json`); the
worker loads both. Arguments (decimal felts, `-x` = P - x; the full layout is in
[`crates/slingfall_replay/README.md`](../../crates/slingfall_replay/README.md)):

- `init`: `<len L> <L...>` (the `Level` felts of `levelc.py to-felts`) → the state felts. Prints
  the level header lines (`trace 1`, `level …`, `material …`, `body …`).
- `step_chunk`: `<len S> <S...> <len I> <I...> <shot> <k> <trace>`, `I` = `player n (pull_x
  pull_y delay 0)×n`, `shot` 0-based, `k` ticks at most, `trace` 0/1 → the new state felts.
  State header: `S[1]` = shots finished (shot `s` is over when `S[1] == s + 1`), `S[2]` = level over,
  `S[5]` = tick, `S[6]` = score. So `remainingTicks` becomes "`S[1] == shot` and `S[2] == 0`".
- With `trace = 1`, one line per tick, `frame <tick> (<handle> <x> <y> <re> <im> <asleep>)*`, and
  the event lines `damage`, `destroyed`, `score`, `shot_end` (all start with the tick after the tag);
  the pebble of shot `s` has handle `bodies + s`.
- `outputs` (lots G6b, G4c; `slingfall_replay::outputs::outputs`): `<len S> <S...> <len I> <I...>` → the 10 felts of
  `Outputs` (D4): slingfall_replay's own `chunk::state_outputs` (≈ 41k steps on pile10), so that
  `level_hash`, `inputs_hash` and `final_state_hash` are the Poseidon hashes of the replay's code.
  `main` / `main_trace` over the whole level would need one VM run of all its ticks (47M steps on
  pile10's three shots: several GB of cells, beyond wasm32).

**Chunk sizing, amended by G6b** (`src/vm/sizing.ts`): `maxTicks` 60 → **20**, and a reserve floor
`minReserveCells` = **5M** cells. With the G1c rule, pile10's reference shot runs K = 37 then 54
flight ticks (65k steps per tick) and the 54-tick chunk runs into the impact: 6.3M steps, 6.7M
cells against a 4.5M reserve, so the segment doubles (602-820 MB of wasm). The floor costs no
memory (the worker already plateaus at the first chunk's 4.4M-cell reserve) and 20 ticks of
impact (4.2M steps, 4.5M cells, the worst chunk measured) fit in it.

**Contact cut and reserve ceiling, lot Q2** (QA M4; the figures below). The floor did not hold on
alpha.5: the flight chunks are sized on cheap flight ticks (K = 20) and the chunk that enters the
impact needed 5.4-7.9M cells against the 5M reserve, so the segment doubled (352 -> 673-681 MB on
pile10, tower, twin, the owner's and the cap shot). A shot's cost jumps in one tick, at the
pebble's first contact with a block or a core (K = 1 runs: ~35k cells per flight tick, ~480-630k on
the contact tick, 300-490k after it). Now:

1. **Cut at the contact.** The worker predicts the contact tick from the aim arc (bit-exact with
   the engine's free flight; `cut.ts`): the first arc point inside a block's or core's box grown
   by the pebble's radius (0.25 m), delay included, on the poses of the last frame of the previous
   shot (destroyed bodies dropped). Predicted vs first costly tick: owner 42 / 43, cap 42 / 43,
   pile10 reference 82 / 83, cores3 79 / 80, tower 78 / 79, bridge 120 / 120, twin 77 / 77 and
   118 / 119. The flight chunk ends `contactLead` = 1 tick before the predicted tick; the chunks
   after it run `impactTicks` = 8 at most until one of them measures the impact (steps per tick
   >= 2x the flight's) or `impactWatch` = 16 ticks have passed.
2. **Reserve ceiling = floor = 5M cells.** A reserve above the largest block the worker already
   holds cannot reuse it: the owner's shot once asked 5.20M cells (4.02M used) and grew the worker
   from 352 to 510 MB. K is lowered until 1.25 x cells per tick x K fits 5M, so every chunk reserves
   the same block.

Outputs are bit-identical (chunk boundaries never change results): `vm.test.ts` runs every
`fixtures/golden` case through the worker with the cut and compares the D4 outputs with `main`'s,
and checks that no chunk exceeds its reserve nor the ceiling.

Measured with `scarb execute` (native): a chunk's fixed cost (state decode, `WorldState` round
trip, level, inputs, serialisation) is ≈ 50k steps on pile10 (K = 1 over the reference shot adds
≈ 17M steps to its 43M); `init` ≈ 0.33M.

## Figures, lot Q2 (rapier2d `=0.1.0-alpha.5`; Node 24.21, `pkg-node`, 2026-09-27)

Shared VPS (8 vCPU, load average 5-16 during the runs, `nice -n 10`). One process per case (wasm
memory only grows), the three executables loaded (199 MB of wasm before any chunk). A = the G6b
sizing (no cut, no ceiling), B = lot Q2's; each pair ran at the same time, 3 times. CPU = the
process's user time (load and `init` included, the same in A and B).

| case (pulls) | steps A -> B | peak wasm A -> B | wall median A / B | B/A wall (sum) | B/A CPU (sum) |
|---|---:|---:|---:|---:|---:|
| pile10 owner (-1022, -63) | 16.07M -> 16.25M (+1.1 %) | 673 -> **368 MB** | 13.49 / 10.24 s | 0.928 | 1.016 |
| pile10 cap (-1019, -72), 180 ticks | 49.48M -> 49.67M (+0.4 %) | 673 -> **368 MB** | 37.02 / 25.75 s | 0.714 | 0.948 |
| pile10 reference (-604, -392) | 10.78M -> 10.96M (+1.7 %) | 673 -> **368 MB** | 4.86 / 4.84 s | 1.024 | 1.019 |
| pile10 three shots (QA's) | 21.66M -> 21.84M (+0.8 %) | 673 -> **368 MB** | 12.68 / 12.17 s | 1.110 | 0.999 |
| cores3 reference (-653, -304) | 14.41M -> 14.52M (+0.8 %) | 352 -> 352 MB | 6.58 / 6.57 s | 0.917 | 1.017 |
| tower reference (-604, -392) | 26.33M -> 26.50M (+0.6 %) | 673 -> **368 MB** | 10.30 / 9.96 s | 0.968 | 1.007 |
| bridge reference (-463, -552) | 12.43M -> 12.58M (+1.2 %) | 368 -> 352 MB | 4.61 / 4.54 s | 0.999 | 1.009 |
| twin reference (2 shots) | 27.88M -> 28.39M (+1.8 %) | 681 -> **376 MB** | 11.95 / 12.07 s | 1.004 | 1.031 |
| one_block (-600, -392, delay 30) | 2.62M -> 2.62M | 352 -> 352 MB | 1.69 / 1.73 s | 0.845 | 1.007 |
| one_block miss (-150, -150) | 3.14M -> 3.14M | 352 -> 352 MB | 1.79 / 1.69 s | 1.047 | 1.019 |
| all ten | +0.0 to +1.8 % | **<= 376 MB** | | **0.908** | **0.998** |

The wall medians of single cases swing ±30 % with the load; the sums and the CPU times agree
that the cut costs < 3.1 % (1-3 more chunks, ~50k steps of round trip each) and the doubling it
removes saved more on the costly shots. Browser (Playwright's Chromium, headless, Linux, `dist/`
served by `vite preview`, `docs/qa/harness/memory.mjs --autoshot`): the same K and steps, peak
wasm 368 MB (pile10 owner, cap, reference, three shots; tower), 376 (twin), 352 (cores3, bridge,
one_block). Owner's shot, K per chunk `5 20 15 | 8 15 14 15 16` (the cut after tick 40), against
G6b's `5 20 20 20 15 15 16` whose third 20 ran into the impact (5.44M cells, 673 MB).

**Losers.** (b) a 7.5M-cell floor (QA S2's alternative), no cut: 428-484 MB on every case and the
cap shot still doubles (7.88M cells: 934 MB); the ceiling alone, no cut: 673-681 MB (the flight
chunk runs into the impact whatever its reserve). (c) a fresh wasm instance per shot: the peak is
inside a shot (199 MB loaded + 153 MB for 5M cells), so it only frees memory between shots, for
0.8-0.9 s of instantiation and executable parsing plus 0.15-0.18 s of `init` per shot (Node,
3 rounds): not adopted. The plateau is now 199 MB of loaded executables + ~32 B per reserved cell.

## Figures, lot G6b (pile10, the slingfall replay; Node 24, `pkg-node`, 2026-09-25)

Same shared VPS, load average 6-9, `nice -n 10`. Reference shot (-600, -392): 191 ticks, won,
score 5 350, every frame, event and output felt equal to the native `main_trace` (`vm.test.ts`).

| figure | measured | budget (brief) |
|---|---:|---:|
| load in a `worker_threads` worker: wasm + `init` + `step_chunk` + `outputs` executables | 632 ms | – |
| `init` (level load, once per level) | 327k steps, 130-211 ms | – |
| release → first frame, across threads (`worker-check.mjs`) | **77 ms** | ≤ 0.5 s |
| release → first frame, same thread (`bench.mjs slingfall`, 4 runs) | 65-110 ms | ≤ 0.5 s |
| whole shot, end to end (`worker-check.mjs`) | **10.32 s**, 34.31M steps | ≤ 15 s |
| whole shot, `bench.mjs slingfall` (4 runs, G6b sizing) | 9.35-14.47 s, 2.37-3.67M steps/s | ≤ 15 s |
| worst gap between two frames | 285-441 ms | – |
| peak wasm, G6b sizing / G1c sizing (`bench.mjs slingfall 60`) | **299-349 MB** / 602-654 MB | ≤ 450 MB (G1c) |
| `outputs` run | 41k steps, 19-21 ms | – |

G6b sizing, K per chunk: `5 20 20 20 20 20 16 16 14 13 11 11 11` (13 chunks, +0.4M steps of
round trips over G1c's 10 chunks, 9.35-9.51 s against 9.77-10.14 s back to back). pile10's three
shots in one session (two weak, then the reference; `vm.test.ts`): 120 ticks 9.8M steps 2.7 s,
120 ticks 9.5M steps 2.5 s, 191 ticks 33.9M steps 10.0 s; won, score 1 350.

## Figures, lot G1c (this machine, Node 24.21, `pkg-node`, 2026-09-25)

AMD EPYC 9354P VPS, 8 vCPU, **load average 8-9.8** during every run (shared machine); `nice -n 10`.
`node client/vm/scripts/bench.mjs first-chunk 5` and `… shot <rule|K> [120] [reserveFactor]`, one
scenario per process, after a warm-up run (ball_drop 60 ticks, 1.3M steps) as the spike did.

| figure | measured | budget (brief) | spike G1b |
|---|---:|---:|---:|
| load: wasm + 8.9 MB JSON parse + program | 365-490 ms | – | 0.36 s |
| first pile12 chunk (init + 10 ticks, 5.38M steps, reserve 7M cells): steps/s | **3.68M** median of 5 (3.29-3.81) | ≥ 2.5M | 3.05M |
| peak wasm memory, that chunk | **410 MB** | ≤ 450 MB | 407 MB |
| first streamed tick (from the shot request, init chunk included) | **218-299 ms** | ≤ 0.35 s | 234-250 ms |

Whole pile12 shot (120 ticks, trace on, warmed-up engine; every row ends on the golden state):

| chunks | total | Cairo steps | steps/s | first tick | worst tick gap | peak wasm |
|---|---:|---:|---:|---:|---:|---:|
| sizing rule, reserve 1.25 (default) | 12.63 s | 41.60M | 3.29M | 299 ms | 275 ms | **330 MB** |
| sizing rule, reserve 1.5 | 11.97 s | 41.60M | 3.47M | 218 ms | 244 ms | 357 MB |
| sizing rule, reserve 1.1 (D8) | 12.17 s | 41.60M | 3.42M | 224 ms | 254 ms | 556 MB |
| fixed K = 5 | 13.79 s | 42.70M | 3.10M | 239 ms | 577 ms | 314 MB |
| fixed K = 10 | 11.91 s | 41.39M | 3.48M | 239 ms | 243 ms | 432 MB |

The rule's K per chunk: `5 6 6 6 6 6 6 7 15 13 13 14 14 3`, i.e. 2.7-3.8M steps per chunk
(0.8M for the last one). Native `slingfall-run` (release): the uninterrupted 120-tick run (mode 3)
takes 8.1 s at 4.9M steps/s (39.99M steps on rapier2d alpha.1; **22.76M** on alpha.2, `scarb execute`, lot H1).
Wasm memory never shrinks; the allocator reuses it, so a worker plateaus at its largest chunk
(baseline ≈ 197 MB after load and warm-up, plus ≈ 32 B per reserved cell). The absolute seconds
are pessimistic for an idle machine. A 4e7-step shot stays at ≈ 12 s on this VPS, as in the
spike (D10's ≤ 3e7 budget fits in ≈ 9 s).
