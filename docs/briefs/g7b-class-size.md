# G7b — measure and shrink the `Slingfall` contract class (Starknet size limits)

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D9; on `main`: `crates/slingfall_contract/` (G7 + G4b hook: `simulate` runs
`slingfall_game::play` and therefore the whole `rapier2d` step), `crates/slingfall_game`, `crates/slingfall_rules`.
Facts (2026-09-26, `scarb build -p slingfall_contract`): `warn: Sierra program exceeds maximum byte-code size on
Starknet for contract Slingfall: 81920 felts allowed. Actual size: 201974 felts` and `Contract class size ... 4089446
bytes allowed. Actual size (without debug info): 11725481 bytes`. A class that cannot be declared cannot be executed
in the SNIP-36 virtual OS either: this blocks E2 / M5. glam-cairo has a precedent for tracking class size
(`packages/consumer`, `scripts/bytecode_size.py`, `docs/audits/R1-bytecode-size.md`, read-only at
`/home/claude/projects/glam-cairo/`).

## 2. Scope (allowlist)
`crates/slingfall_contract/**`, `tools/classsize/**` (new, Python stdlib), `steps/slingfall_contract/*.snap`,
a new measurement package `crates/slingfall_sizes/**` (Starknet contract fixtures, not published) + its
workspace member line in the root `Scarb.toml` (one line; list it under Escalations too).

## 3. Work
1. **Decompose the size.** Build contract fixtures that expose, one at a time: (a) registry + submit only
   (no `simulate`), (b) + `slingfall_level` decode / validate, (c) + `slingfall_rules::GameTrait::new`
   (world building, no step), (d) + one `World::step_with_force_events`, (e) the real `simulate`. Report
   Sierra felts and class bytes for each (`tools/classsize/classsize.py` reads `target/dev/*.contract_class.json`
   and the CASM size from `starknet-sierra-compile` if available, else the Sierra felt count and the scarb
   warning figures). Identify what the step costs (narrow-phase generators per shape pair, solver, dispatch).
2. **Levers, measured on (e):** (i) cut unused shape pairs from the game's reachable set (the game uses ball,
   cuboid, convex polygon, half-space: are capsule / segment generators still compiled in through the closed
   enum dispatch? report which arms are reachable); (ii) `#[inline(never)]` on cold paths of the game / rules
   crates; (iii) a two-class layout: `Slingfall` (registry, submit, small) + `SlingfallSim` (simulate) called
   through `library_call_syscall` or a plain contract call, so that only the simulation class carries the
   physics: measure both classes; (iv) anything scarb offers (`sierra-replace-ids = false`, `inlining-strategy`
   in `[cairo]`: try `inlining-strategy = "avoid"` for the contract profile and report felts and the steps
   delta on the `simulate` golden).
3. **Recommendation:** what gets the simulation class under 81 920 felts / 4 089 446 bytes, what it costs in
   Cairo steps on the reference shot, and which part must come from rapier-cairo (bytecode of `World::step`:
   give the numbers for the rapier orchestrator).

## 4. Budget
Steps of `simulate` on the golden may not change in this lot except for the measured variants (report deltas).

## 5. Tests
The fixtures build; `classsize.py` prints the table; the contract golden still passes.

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
push `feat/g7b-class-size`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · Size table (a)-(e) · Levers table · Recommendation · Escalations (rapier numbers) · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
