# S1 — substeps and tick rate: measure ×2 (and ×1, 30 Hz) on the six levels; switch if stability holds

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D5, D10; rapier-cairo `docs/BUDGETS.md` "Cost of a level" and ADR 0001 entry 9
(read-only at `/home/claude/projects/rapier-cairo/`): upstream fidelity is identical at ×4 / ×2 / ×1 / 30 Hz up to the
impact tick, so only the game's stability decides; on `main`: `crates/slingfall_rules/src/world.cairo`
(`IntegrationParameters`, `num_solver_iterations`, dt), `tools/levelc/rules.py` (`check --rules`: rest, awake-at-rest,
settle), `tools/settle/settle.py`, `tools/golden/golden.py`, `fixtures/golden/`, `docs/levels.md`.

## 2. Scope (allowlist)
`crates/slingfall_rules/src/**` (a `SimConfig` / constants: substeps and dt read from the `Level` if you add an
optional field with default ×4 / 60 Hz, else crate constants; keep the felt layout of `Level` unchanged unless you
add a trailing optional field with a version bump of `LEVEL_VERSION`: prefer crate constants for this lot),
`tools/levelc/rules.py` (`--substeps`, `--hz` switches passed to the executables via an env / argument the rules
crate reads at build time: `SLINGFALL_SUBSTEPS` scarb feature or a `cfg`), `tools/golden/**`, `fixtures/golden/**`
(new cases per setting, existing ones untouched unless the default changes), `docs/levels.md`, `steps/**`,
`docs/briefs/s1-substeps.md` (this file: append your results table).

## 3. Work
1. Make the substep count and tick rate a build-time choice of `slingfall_rules` (Scarb features
   `substeps_2`, `substeps_1`, `hz_30`; default ×4 / 60 Hz) so that every tool can run the matrix without editing levels.
2. Matrix on the six levels: ×4 (baseline), ×2, ×1, 30 Hz ×4: for each, `levelc check --rules --jobs 2` (rest and
   awake-at-rest: zero damage lines, zero moved bodies, settle idempotent), the reference pull(s): destroyed set,
   score, won, end tick, steps; a jitter test: 300 ticks awake at rest, count wake-ups / poses drift (mm);
   the pebble at 25 m/s vs the 0.5 m plank (tunnelling) at each setting.
3. Decision rule (apply it, report it): switch the default to the cheapest setting where every level passes the
   stability checks, every reference pull still wins with the same destroyed set (or a superset), tunnelling does
   not appear, and the client's exact flight arc (`client/src/aim/arc.ts`, 60 Hz Euler) still matches the engine's
   free flight (if 30 Hz is chosen, the arc changes: report and do not switch to 30 Hz in this lot; only substeps).
4. If the default changes: regenerate goldens / executables / steps, and note it in `docs/levels.md`
   ("numeric change: MINOR" for the game).

## 4. Budget
Report steps per reference shot per setting; expected ×2 ≈ −25 to −35 %.

## 5. Tests
`levelc check --rules` on all six levels at the chosen default; goldens green; snforge rules tests green.

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/s1-substeps`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Matrix
table · Decision · Deviations · Escalations · PR URL). At most 2 parallel jobs; never two golden runs at once.

## 7. Work autonomously, do not ask questions, do not widen the scope.
