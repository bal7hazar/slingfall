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
| `fixtures/ball_drop/` | the stand-in executable's source (spike G1b copy, registry `rapier2d`) until lot G4 |
| `fixtures/ball_drop.executable.json` | its build (the worker and the tests load it) |
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
was produced with `slingfall-run client/vm/fixtures/ball_drop.executable.json "3 3 120 0 0"`.

**Fixture.** `scarb --manifest-path client/vm/fixtures/ball_drop/Scarb.toml build`, then copy
`fixtures/ball_drop/target/dev/ball_drop.executable.json` to `fixtures/`, rerun `slingfall-run`
for the golden state. Arguments: `mode scene steps trace <len> <state felts..>`; mode 1 =
`init(scene)`, 2 = `step_chunk(state, steps)`, 3 = build + `steps` ticks + save (the
bit-exactness reference); scene 0 = ball_drop, 3 = pile12 (12 boxes hit by a ball). With
`trace = 1` every tick prints `tick <i> y <raw>` (y of the ball).

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
  after that, K = floor(`targetSteps` / previous chunk's steps per tick), clamped to [1, 60]
  and to the ticks left; `targetSteps` = 3.5M (D8: 2-5M). The execution segment is reserved at
  `reserveFactor` x the previous chunk's execution-segment cells per tick x K (1.25; the first
  chunk assumes 700k cells per tick). D8 says 1.1. Measured, 1.1 is overrun when steps per tick
  rise by more than 10 % from one chunk to the next, and the segment then doubles (556 MB instead
  of 330 MB).
- `program.ts`: the `ChunkProgram` interface (init/step_chunk arguments, ticks left, a
  `TickLineParser` from `src/trace/lines.ts` and the sample-to-`TraceFrame` mapping) and its only
  implementation, `ballDropProgram` (`SpikeTickLineParser`). G4's replay executable and observer
  format replace it, with no change to the loop.
- `shot.ts`: `runShot(engine, program, level, inputs, options)`, the chunk loop (pure, used by the
  worker, the tests and `bench.mjs`).
- `worker.ts` (module Web Worker) + `serve.ts` (its message loop) + `protocol.ts`; `index.ts`:
  `VmClient` (one persistent worker: `ready`, `shot(request, handlers)`) and
  `WorkerTraceSource(client, request, { level, onChunk })` (a `TraceSource` of kind `'worker'`,
  re-exported by `src/trace/source.ts`; `level()` returns the `TraceLevel` the caller passes;
  `events` stays empty until G4's observer prints events).
  `DEFAULT_LOAD` points at `/vm/pkg/slingfall_vm_runner.js` and
  `/vm/fixtures/ball_drop.executable.json`. `npm run dev` serves both from the client root. The
  wasm is imported at run time, so `npm run build` never needs it. Lot G6b will serve it in a
  production build.

## Figures (this machine, Node 24.21, `pkg-node`, 2026-09-25)

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
takes 8.1 s at 4.9M steps/s (39.99M steps).
Wasm memory never shrinks; the allocator reuses it, so a worker plateaus at its largest chunk
(baseline ≈ 197 MB after load and warm-up, plus ≈ 32 B per reserved cell). The absolute seconds
are pessimistic for an idle machine. A 4e7-step shot stays at ≈ 12 s on this VPS, as in the
spike (D10's ≤ 3e7 budget fits in ≈ 9 s).
