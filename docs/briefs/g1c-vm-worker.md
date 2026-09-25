# G1c — `client/vm/`: the chunked cairo-vm Web Worker as a reusable package

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D8; `docs/research/03-spike-wasm-vm.md` and `04-spike-chunked-execution.md`
(everything: runner, build commands, pitfalls, measurements); the spike tree itself, read-only:
`/home/claude/projects/pm/spikes/wasm-vm/` (`g1-runner/` crate incl. `cairo-vm-reserve.patch`, `web/shot.mjs`,
`web/chain.html`, `node/chain.mjs`, `scripts/build_wasm.py`, `ball_drop/` executable with modes 1/2/3).
On `main`: `client/src/trace/source.ts` (the `TraceSource` interface the worker must implement).

## 2. Scope (allowlist)
`client/vm/**` (new: `runner/` Rust crate, `scripts/`, `README.md`), `client/src/vm/**` (new TS: worker,
`WorkerTraceSource`), `client/src/trace/source.ts` (add the worker implementation only), `client/package.json`
+ lockfile for new dev dependencies, `client/README.md` section, `.github/workflows/ci.yml` ONLY if a wasm
build job is added (keep it optional / cached; escalate if it needs more than 5 min or Rust on the runner
is a problem: then leave CI untouched and document the local build).

## 3. Expected content
1. `client/vm/runner/`: the spike's `g1-runner` promoted to a package: cairo-vm as a cargo **git dependency
   pinned to `f7ac327f`**; the 16-line reservation patch handled without a fork: a `scripts/vendor.sh`
   that clones cairo-vm at that rev under `client/vm/vendor/` (git-ignored), applies the patch and is
   referenced by `[patch]` in `Cargo.toml` — document it, and write under "Escalations" the cleaner
   option (a `bal7hazar/cairo-vm` fork branch, or upstreaming `Memory::reserve_segment`).
   Public JS API (wasm-bindgen): `new Runner(executableJson)`, `runner.run(args, {reserveCells, onPrint}) ->
   {steps, memoryCells, returned}`; the `DebugPrint` hint streams to `onPrint`. Build with
   `scripts/build.sh` (wasm32, `wasm-bindgen --target web`, optional `wasm-opt`), output `client/vm/pkg/`
   (git-ignored, built in CI or locally). Native binary `slingfall-run` kept for tests.
2. `client/src/vm/worker.ts` + `client/src/vm/index.ts`: a Web Worker loading the wasm once, running
   **step-budgeted chunks** (`init(level)` then `step_chunk(state, inputs, k)` per D1: choose `k` from the
   previous chunk's steps per tick, target 2-5M steps per chunk, reserve 1.1x the previous chunk's cells),
   keeping the worker alive between chunks, streaming parsed ticks as `TraceFrame`s; `WorkerTraceSource`
   implements `TraceSource`. Until G4 exists, test against the spike's `ball_drop` executable (copy its
   built `executable.json` under `client/vm/fixtures/`, modes 1/2/3, tick line `tick <i> y <raw>`): the
   parser is behind an interface and the G4 observer format replaces it later.
3. `client/vm/README.md`: build, run, measured figures on this machine (steps/s in Node, peak wasm memory
   per chunk, first-tick latency) reproduced from the spike, and the chunk-sizing rule.

DEFER: `main_trace` format (G4), `wasm64`, VM profiling, Chrome measurements.

## 4. Budget
Match the spike: ≥ 2.5M steps/s in Node for the 5.4M-step first chunk of `pile12`, ≤ 450 MB wasm memory per
chunk, first tick ≤ 0.35 s. Report the figures.

## 5. Tests
Vitest (Node, `pkg-node` build): chaining K = 5/10/30 on `pile12` 120 ticks gives the same final state as
mode 3 (bit-exact, compare felts); streaming order of ticks; chunk sizing rule; a Rust unit test in the
runner for `parse_args` with negative felts. No fuzz.

## 6. Definition of done
Foreground; Rust builds `nice -n 10 cargo build -j 4`; `npm run lint`, `npm test`, `npm run build`
(the app build must not require the wasm: lazy import); conventional commits with the trailer
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push `feat/g1c-vm-worker`; `gh pr create`;
`gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · API · Figures · Deviations ·
Deferred · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
