# B4 — bump to `rapier2d = "=0.1.0-alpha.6"` (SF1 numeric change, `BasicStepConfig`), re-validate the six levels, re-pin Sepolia

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D2 (levels pre-settled), D5, D6, D9 (`SatelliteConfig.child_program_hash` pinned per
release), D11; `docs/levels.md` (settle, validator, goldens workflow); `docs/briefs/b3-bump-rapier2d-alpha5.md` and the
B3 row of `docs/PLAN.md` (the pattern of a bump); rapier-cairo CHANGELOG 0.1.0-alpha.6 (registry source after
`scarb fetch`):
- **Numeric change (SF1)**: exactly closed contact gaps solve rigidly as upstream. Goldens change.
- **`StepConfig` / `DefaultStepConfig` / `BasicStepConfig`** with `step_with::<C>` and
  `step_with_force_events_with::<C>`: `BasicStepConfig` compiles ball, cuboid, convex polygon and half-space only, no
  joints, composites or sensors; it **panics at the step that meets an unsupported feature**. Results are bit-identical
  to the default configuration on a supported world; the game-shaped program shrinks 565k -> 231k felts.
- RG1: force-event worlds step below alpha.4 again. WorldState is still v3.

## 2. Credentials
`STARKNET_*` in your environment; never print or commit values. Transactions this lot MAY send on Sepolia, and no other:
1. exactly one `set_satellite_config` with the new `child_program_hash` (other constants unchanged);
2. only for a level whose file had to change (§4.3): one `register_level` of the new level and one
   `set_level_active(old_hash, false)`.

## 3. Scope (allowlist)
Version pins (root `Scarb.toml`, `crates/slingfall_replay/Scarb.toml`, `client/vm/fixtures/ball_drop/Scarb.toml`,
`tools/atlantic/c1main/Scarb.toml`, `deploy/contract/`) + lockfiles; `crates/slingfall_rules/src/**`,
`crates/slingfall_sizes/src/**`, `crates/slingfall_game/src/**`, `crates/slingfall_replay/src/**` (step call sites
only); `steps/**`; `fixtures/golden/**`; `crates/slingfall_replay/tests/golden.cairo`; `fixtures/levels/**` and
`client/public/levels/**` (only under §4.3); `client/vm/fixtures/**`; client test fixtures that embed golden outputs;
`fixtures/proofs/**`; `deploy/sepolia.json`; `docs/proving.md` (program-hash history), `docs/levels.md` (measured
tables). Everything else: "Escalations" in `REPORT.md`.

## 4. Work
1. Pin alpha.6 everywhere; build. Replace every engine step of the game path by its `BasicStepConfig` form
   (`step_with_force_events_with::<BasicStepConfig>` in the tick, `step_with::<BasicStepConfig>` for the settle step of
   the world build, the sizes hooks, tests). Check that every level shape and the pebble are inside the supported set.
2. Measure before touching levels: steps per golden case (alpha.5 -> alpha.6 table), `c1main` bytecode size,
   `SlingfallSim` / `Slingfall` class sizes (`tools/classsize`), the `outputs` of each golden case before / after.
3. Re-validate the six levels, **unchanged first**: `levelc.py check --strict --rules` on each (one at a time: the
   probes take up to 7 GB). A level that passes with its current file and whose reference pulls still win keeps its
   file and its `level_hash`; only its goldens are regenerated. A level that fails is re-settled (`settle.py`) and, if
   still failing, retuned by the smallest change (reference pull first, then poses), then re-registered (§2.2). Report
   per level: passes unchanged / re-settled / retuned, old and new reference pulls, scores, ticks, steps.
4. Also replay the owner's recorded browser shot on `pile10` (player `123610794124658`, pull `(-1022, -63)`, delay 0;
   on alpha.5: won, score 5300, 106 ticks) and report its alpha.6 outputs (information only).
5. Regenerate goldens (`golden.py run --update`, `to-cairo`), steps snapshots, executables
   (`fetch-executables.sh --build`), the stand-in state, the `ChunkState` golden hash, client fixtures.
6. `c1main` build and program hash (`atlantic.py program-hash`); Sepolia `set_satellite_config`; record the tx hash
   and fee in `deploy/sepolia.json`; add the alpha.6 row to the program-hash history of `docs/proving.md`; read the
   config back with `deploy/sepolia.sh`.

## 5. Budget
Expected: steps at or below alpha.4 levels (RG1, and −1,612 steps per engine step from CS2); `c1main` bytecode about
−59 %. Report the measured values; a regression of more than 0.5 % on any golden case is reported with its cause.

## 6. Tests
Crate-scoped checks of `AGENTS.md` §6; a test that a world with an unsupported feature is not reachable from a valid
level is not required (the level format has no such feature: say so in the report with the evidence). CI green (golden
matrix, vm, prove, e2e).

## 7. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push
`feat/b4-bump-rapier2d-alpha6`; `gh pr create`; `gh pr checks --watch` until green (foreground); never merge;
`REPORT.md`. Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs; one heavy probe
at a time.
