# G3b — rules follow-up: pebble damping, whole-shot tests, projectiles field

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D5 (amended: pebble damping, settle step), D12; `docs/PLAN.md` (G3 row, budgets);
on `main`: `crates/slingfall_rules/src/{sling,calm,world}.cairo` and `world/tests.cairo` (three `#[ignore]`d
whole-shot tests; the step cap is now 400M in the workspace `Scarb.toml`); `rapier2d` prelude for
`RigidBodyBuilder::{linear_damping, angular_damping}` (registry sources under `~/.cache/scarb/registry/src/`).

## 2. Scope (allowlist)
`crates/slingfall_rules/src/**`, `crates/slingfall_rules/README.md`, `steps/slingfall_rules/*.snap`.

## 3. Work
1. Pebble damping: `PEBBLE_LINEAR_DAMPING = 0.5`, `PEBBLE_ANGULAR_DAMPING = 2.0` (raw Q32.32 constants) applied
   in `sling::launch` through the builder; measure on the six pulls of the G3 report (lifted cap) how many
   shots now end by the calm rule instead of the cap, the end tick and the steps; if a pull still hits the cap,
   try 1.0 / 4.0 and report both tables. Keep the values that end every shot before the cap with the least
   change of the destruction results; report if none does.
2. Un-ignore the three whole-shot tests (the cap is raised); make sure `snforge test -p slingfall_rules`
   stays under ~10 minutes on this machine (report the time); if not, keep the longest one ignored and say why.
3. Read `level.projectiles[shot index]`: kind 0 = pebble; any other kind panics `'rules: projectile kind'`
   (abilities are deferred, but the field must not be silently ignored).
4. README of the crate: the static-load finding of G3 (inner bottom timber blocks over the 40 N threshold
   when awake at rest) as a note for level authors / G8.

## 4. Steps budget
Damping must not add more than 1 % to a flight tick; report `steps_tick__pile10_flight` before / after.

## 5. Tests
Table-driven; a test that the reference pull ends by calm with damping and its end tick; the projectile-kind panic.

## 6. Definition of done
`AGENTS.md` §6: `scarb fmt --workspace`, `scarb lint -p slingfall_rules --deny-warnings`, `scarb build -p slingfall_rules`,
`snforge test -p slingfall_rules`, `python3 scripts/steps.py snapshot --filter slingfall_rules`; conventional commits with the
trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push `feat/g3b-rules-followup`; `gh pr create`;
`gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Tables · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
