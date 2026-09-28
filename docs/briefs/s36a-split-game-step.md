# S36a — spike: the game's chunk on declared classes (SNIP-36 path), sizes and steps measured

## 1. Read first
`AGENTS.md`; `docs/research/06-fast-validation.md` §1a; rapier-cairo `docs/research/class-split.md` (§9-10: layouts,
per-transaction tables) and the registry sources of `rapier2d_classes` 0.1.0-alpha.7 (`SlimSplitStep`,
`SplitStepConfig`, `ClassHashes`, `StageConfig`, `BasicWorldState`), its `tests/game_ticks.cairo`;
`/home/claude/projects/pm/research/SN1-snip36-library-call.md` (what the virtual OS executes: library_call yes; no
deploy / replace_class / get_block_hash; the only output of a proven transaction is its L2->L1 messages; no reverted
transaction; at most 10M steps per transaction); `docs/DESIGN.md` D4-D9, `docs/proving.md` "Chunk binding";
`crates/slingfall_rules/src/**`, `crates/slingfall_game/src/**`, `crates/slingfall_replay/src/**` (`init`,
`step_chunk`, `outputs`), `crates/slingfall_contract/src/simulate/**`, `crates/slingfall_sizes/**`, `tools/classsize`.

## 2. Question
rapier's slim caller is 73,083 CASM felts, 645 under the 73,728 gate (real limit 81,920), BEFORE any game code. The
game's tick adds the sling, damage from force events, removals, the calm rule, scoring, the state hash. Find the class
layout in which a whole shot runs as a chain of transactions of at most 10M steps, every declared class at most 73,728
Sierra and CASM felts, results bit-identical to `main`.

## 3. Scope (allowlist)
New crate `crates/slingfall_split/**` (contracts and tests of the spike, `publish = false`), its entry in the root
`Scarb.toml` members and `rapier2d_classes = "=0.1.0-alpha.7"` / `rapier2d = "=0.1.0-alpha.7"` pins needed to build it
(lot B5 bumps the rest of the repository in parallel: touch no other pin, no golden, no fixture), `tools/classsize/**`
(to measure the new classes), `docs/research/07-split-game-step.md` (the deliverable). No deployment, no
transaction, no credentials. Engine changes are out of scope: needs for rapier go under "Escalations" with figures.

## 4. Work
1. Inventory: Sierra and CASM felts of each game stage (world build, sling / pebble insertion, damage and removals,
   calm rule, scoring, `ChunkState` encode / decode and hash) from real contract builds.
2. Build and measure at least these layouts, each playing the pile10 reference shot and the owner's shot
   ((-1022, -63), 151 ticks) tick by tick against `main` (outputs, `final_state_hash`, events):
   (a) the game tick inside the class that holds the world (game code + rapier's slim caller in one class): size;
   (b) a game class that owns the chunk loop and the game state, and library-calls rapier's slim caller once per
       engine step with the world, force events coming back;
   (c) the world kept by rapier's caller class for K ticks, the game rules called back per tick with compact data
       (force events in; removals, insertions, velocities out);
   (d) any better layout you find (for example game rules folded into an existing small class).
   Per layout: class sizes, steps per tick (flight, impact), steps of each shot, transactions of at most 10M steps
   with the calldata felts of each (state in, state out as a message hash), and the margin of every class.
3. Transactions: specify the chain for the best layout: `init` -> chunks -> `outputs`, what each sends as L2->L1
   message (the P1b binding headers with `new_state` replaced by its hash), and how a real contract links and
   finalises them (R6 §1a "Parallel"). No panic may be reachable on a valid level's path.
4. Verdict: is there a layout that fits today? If not, the smallest engine or game change that makes one fit, with
   measured felts.

## 5. Machine
Whole-shot test runs are heavy (rapier's peak near 20 GB): run them one at a time under
`flock ~/orchestrator/heavy-build.lock <command>`; your unit is capped at 14 GB, so prefer chunked runs and
`snforge test <filter>` on single tests; if a run is killed for memory, split it and say so.

## 6. Definition of done
`AGENTS.md` §6 crate-scoped checks on `slingfall_split`; conventional commits with the trailer
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push `feat/s36a-split-game-step`; `gh pr create`;
`gh pr checks --watch` in the foreground until green; never merge; `REPORT.md` (summary, tables, verdict,
escalations). Foreground only. Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs.

## 7. Hints from the rapier orchestrator (estimates, to be measured; added 2026-09-28)
- The game contract IS the caller class (it holds the world and runs the tick loop). With 645 felts of margin no game
  rule fits in it as it is: rules live in declared classes; the caller keeps the chunk loop, the application of
  removals, the pebble insertion (World API it already compiles) and the state hash (Poseidon over the felts the basic
  codec already writes).
- Cheapest hook: a per-tick rules class called once per tick after the step. In: the tick's force events in compact
  form (handle or pair + magnitude), HP / score state if it lives outside the world. Out: handles to remove, score
  delta. Estimated 2-4k steps per call, about +1-2 % on the shot.
- Better: fold the damage rule into `ForceEventsClass`, so the caller never materialises force events: the class
  computes them, applies damage and returns only the removals (removes about 572 CASM from the caller and one
  crossing). Calm rule, out of bounds and scoring in the same rules class, from poses and velocities or a compact
  per-entity summary.
- rapier can add a `StageConfig` slot `TickHook` (in-process no-op by default, zero steps) that the slim stages
  library-call right after the force-event stage and whose returned removals are applied inside the step. Measure
  layout (c) both with what alpha.7 offers and, on a vendored copy of `rapier2d_classes` inside the spike crate, with
  such a hook; report the figures so the request to rapier is precise.
