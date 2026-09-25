# G6b — client live mode: the worker runs the real replay, shot loop, slow-motion impact, score UI

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D3, D5, D8; on `main`: `client/README.md` (trace format v1), `client/src/{render,aim,trace,vm}/`,
`client/vm/README.md` (+ the G4 section: `init` / `step_chunk` argument layouts, `ChunkState` header, trace lines),
`crates/slingfall_replay/README.md`, `fixtures/traces/pile10-reference.json`, `tools/tracec/tracec.py`,
`docs/research/04` §"Verdict" (chunk sizing, memory), G4's report figures (`/home/claude/projects/pm/reports/slingfall-G4.md`
is NOT readable from your sandbox: the numbers are in `docs/PLAN.md` budgets and the replay README).

## 2. Scope (allowlist)
`client/**` except `client/vm/runner/**` (Rust runner unchanged) and `client/package.json` version bumps;
`client/vm/fixtures/**` (add the built `slingfall_replay` executables: `main_trace`, `init`, `step_chunk`
`executable.json` files built from `main` with `scarb --manifest-path crates/slingfall_replay/Scarb.toml build`,
plus a script `client/vm/scripts/fetch-executables.sh` that copies them from `target/`); `.github/workflows/ci.yml`
ONLY the existing `vm` job if it must build the replay first.

## 3. Work
1. `client/src/vm/program.ts`: a `slingfallProgram` implementing `ChunkProgram` for the real executables:
   `init(level felts)` (parses the level header lines), `step_chunk(state, inputs, shot, k, trace = 1)` with the
   G4 argument layout and `ChunkState` header (offsets 1 = shots_used, 2 = over); the trace-line parser for
   `frame` / `damage` / `destroyed` / `score` / `shot_end` lines into `TraceFrame`s and events (format v1).
2. Shot loop in `client/src/main.ts` (or a `game/` module): load a level (`fixtures/levels/*.felts.json` served
   from `client/public/levels/`, plus the JSON for names / display), `init` in the worker once, aim → release
   → `step_chunk` chunks for that shot until `shot over`, streaming frames to the renderer; keep the inputs so
   far; end of level → outputs (from the state header: score, won) shown in the UI; "retry" resets.
3. Presentation: live playback during flight (frames arrive faster than real time), **slow-motion impact**
   (play frames at the arrival rate when they lag real time, with a "simulating…" indicator), HUD score /
   shots / tick, damage flashes and destroyed fade-outs from the events.
4. Determinism display: after the level, show `final_state_hash`, `inputs_hash` and the outputs felts (they
   are what a proof will carry), and a "copy inputs" button (JSON of the shots).
5. Serve `client/vm/pkg/` and the executables in dev and in `vite build` (`public/` or an asset plugin);
   the app build must still not require the wasm to exist (lazy import; a "VM not built" message otherwise).
6. Browser check: run it in headless Firefox if `firefox` is installed (`which firefox`) with a Playwright-free
   script (the spike used `scripts/browser_bench.py` style: a local server + Firefox `--headless --screenshot`);
   at least capture the console output of one full pile10 shot and its timing; if no browser runs in the
   sandbox, say so and measure in Node through the worker protocol as G1c did.

## 4. Budget
First frame ≤ 0.5 s after release; a pile10 shot end-to-end ≤ 15 s in Node on this machine; no per-frame allocation in
the renderer (as G6).

## 5. Tests
Vitest: program argument encoding / decoding against fixtures produced by `tracec.py args`; trace-line parsing
of a recorded `main_trace` output; the shot loop with a fake engine; and, when `pkg-node/` exists, one real
pile10 shot through `WorkerTraceSource` comparing the final outputs with `fixtures/golden` or the replay README's
reference values (won, score 5 350, 191 ticks).

## 6. Definition of done
`AGENTS.md` §6 client part; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
push `feat/g6b-client-live`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · Flow · Figures · Deviations · Deferred · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
