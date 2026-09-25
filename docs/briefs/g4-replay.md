# G4 — `slingfall_replay`: `main`, `main_trace`, chunked `init` / `step_chunk`; wire the contract hook

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D4, D8, D10; `docs/PLAN.md` (G4 row: trace format v1 and its semantics);
`client/README.md` §"Trace format v1" and `client/src/trace/{types,lines}.ts` (what the client parses);
`client/vm/README.md` and `client/src/vm/program.ts` (`ChunkProgram`: how the worker calls `init` / `step_chunk`
and parses `println!` lines; `ball_drop` modes 1/2/3 are the stand-in to replace); on `main`:
`crates/slingfall_replay/` (nested package, `#[executable]`, `enable-gas = false`, tests under profile `snforge`),
`crates/slingfall_rules` (G3: `GameTrait::{new, tick, play_shot, to_state, from_state, final_state_hash}`,
`GameState`), `crates/slingfall_level` (`Level`, `Inputs`, `Outputs`, hashes, `levelc` for felts of the fixtures),
`crates/slingfall_contract/src/simulate.cairo` (`pub impl ActiveHook = StubSimulateHook;` and the `SimulateHook` trait).
Note: G3b (pebble damping, Sonnet) runs in parallel in `slingfall_rules`; do not edit that crate; rebase when it merges.

## 2. Scope (allowlist)
`crates/slingfall_replay/**` (source, tests, README, its own `Scarb.toml` if the nested package needs a
dependency), `crates/slingfall_contract/src/simulate.cairo` ONLY the `ActiveHook` impl and its `use` lines
(+ a `SimulateHook` impl file `crates/slingfall_contract/src/simulate/replay_hook.cairo` if needed; the
contract's `Scarb.toml` dependency on the replay logic is orchestrator-owned: if the replay logic must live in
a library crate shared by the executable and the contract, put the logic in `slingfall_replay`'s library
target if the package can have both `lib` and `executable` targets, else escalate the split),
`fixtures/traces/**` (generated traces), `steps/slingfall_replay/*.snap`.

## 3. Expected content (D1)
- Library logic `play<O, +Observer<O>>(level: @Level, inputs: @Inputs, ref obs: O) -> Outputs`: validate,
  `GameTrait::new`, for each shot `play_shot` (delay, launch, ticks until shot over, pebble removal), stop
  when won or shots exhausted, `Outputs` per D4 (`level_hash`, `inputs_hash`, `player`, `score`, `won`,
  `shots_used`, `ticks_run`, `final_state_hash`). `Observer` trait: `on_level(@Level)`, `on_tick(@Game)`,
  `on_event(...)` (damage / destroyed / score / shot_end); `NoopObserver` (compiles to nothing; assert with
  the step counts) and `TraceObserver` printing **trace format v1** (`client/README.md`): the level header
  once, per tick the poses of every live dynamic body with `asleep`, events as they happen; one `println!`
  per line, felts as decimal strings.
- Executables: `main(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252>` (proof build, noop
  observer), `main_trace(level, inputs) -> Array<felt252>` (trace observer), `init(level) -> Array<felt252>`
  (serialised `GameState`), `step_chunk(state: Array<felt252>, inputs: Array<felt252>, shot: u8, k: u32, trace: u8)
  -> Array<felt252>` (restore, run up to `k` ticks of the given shot (launching it if not started), return the
  new state; trace lines when `trace != 0`); the exact argument layout is API for the client: document it in
  the README and in `client/vm/README.md` (a short section; the client code itself is G6b's).
- Wire the contract: `ActiveHook` = an impl calling `play` with the noop observer.
- Fixtures: `fixtures/traces/pile10-reference.json` produced by `scarb execute` of `main_trace` on
  `fixtures/levels/pile10` with the reference pull (-600, -392) (converted from the `println!` lines by a
  small Python tool `tools/tracec/tracec.py`, stdlib), replacing the hand-made `pile10.json` of G6 for the
  client (keep G6's synth generator for its tests).
- Measurements (`scarb execute --print-resource-usage`): `main` on the three fixture levels with 1 and 3
  shots, `main_trace` overhead, `init` + chained `step_chunk` bit-exact vs `main` (compare outputs); write
  **Cairo steps per shot and per level** into the README and the report.

DEFER: client wiring (G6b), CI golden snapshots (G5), abilities.

## 4. Steps budget
`play` overhead beyond the rules ≤ 1 %; `TraceObserver` ≤ 10 % of a shot; state round trip per chunk as
measured by rapier (52k for pile10) + the game's fields.

## 5. Tests
Under the `snforge` profile: `main` outputs of the reference shot (golden felts), `main_trace` ≡ `main`
outputs, `init` + `step_chunk` chain (K = 1, 7, 60) ≡ `main` bit for bit (`final_state_hash` and every output),
argument validation panics; ≤ 4 fuzz. Contract: one test that `simulate` on `pile10` with the reference
inputs returns the same `Outputs` as `main` (in the contract crate's tests only if its allowlist above permits;
else describe the test for the orchestrator).

## 6. Definition of done
`AGENTS.md` §6 (crate-scoped, foreground; the replay package builds with `scarb --manifest-path
crates/slingfall_replay/Scarb.toml build` and tests with `snforge test --profile snforge` inside it);
`scarb lint -p slingfall_contract --deny-warnings && snforge test -p slingfall_contract` after the hook change;
`python3 scripts/steps.py snapshot --filter slingfall_replay`; conventional commits with the trailer
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push `feat/g4-replay`; `gh pr create`; `gh pr checks --watch`
until green; never merge; `REPORT.md` (Summary · API and argument layouts · Steps per shot / per level table ·
Deviations · Deferred · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
