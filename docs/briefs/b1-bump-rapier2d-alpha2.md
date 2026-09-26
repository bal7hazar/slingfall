# B1 — bump to `rapier2d = "=0.1.0-alpha.2"` and regenerate everything that depends on the engine's results

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D11; rapier-cairo `CHANGELOG.md` for 0.1.0-alpha.2 (registry source under
`~/.cache/scarb/registry/src/*/rapier2d-0.1.0-alpha.2/` after `scarb fetch`; headline: BT1 −41 % impact steps,
BT2 sleeping bodies cost 0 steps per tick, `WorldState` **version 2** (v1 states panic `'world state: version'`),
`WorldTrait::{is_sleeping, linvel, angvel}`, results bit-identical except two upstream alignments: bodies
inserted asleep stay asleep; removed colliders no longer wake sensor partners); on `main`: root `Scarb.toml`
(`[workspace.dependencies] rapier2d`), `crates/slingfall_replay/Scarb.toml`, `tools/golden/golden.py`,
`fixtures/golden/`, `crates/slingfall_replay/tests/golden.cairo`, `crates/slingfall_game/src/fixtures.cairo`,
`crates/slingfall_contract/src/submit/fixtures.cairo`, `client/vm/fixtures/replay/` + `fetch-executables.sh`,
`client/vm/fixtures/pile10-reference.*`, `steps/**`, `crates/slingfall_rules/src/{world,calm}.cairo` (the
settle step and the activation reads through `World::body`).

## 2. Scope (allowlist)
Root `Scarb.toml` and `crates/slingfall_replay/Scarb.toml` (the version pin only) + both `Scarb.lock`;
`crates/slingfall_rules/src/**` (use the new `is_sleeping` / `linvel` / `angvel` reads instead of `World::body`
copies in the calm scan and elsewhere; keep the settle step); `steps/**`; `fixtures/golden/**`;
`crates/slingfall_replay/tests/golden.cairo`, `crates/slingfall_game/src/fixtures.cairo`,
`crates/slingfall_contract/src/submit/fixtures.cairo` (regenerated goldens); `client/vm/fixtures/**` (rebuilt
executables, regenerated reference trace / args / state files); `fixtures/traces/pile10-reference.json`;
`docs/PLAN.md` budgets table ONLY the measured figures row (report the rest under Escalations).

## 3. Work
1. Pin `=0.1.0-alpha.2`, `scarb fetch`, build every crate; fix compile errors from the facade changes (CW) if any.
2. Rules: replace `World::body(h)` activation / velocity reads by the new accessors where the value alone is
   needed; measure `steps_tick__pile10_flight` and `steps_calm__update` before / after.
3. Regenerate: `steps.py snapshot` (all crates), `golden.py --update` (all cases) then `to-cairo`, the game /
   contract reference fixtures (outputs must be bit-identical to before if the CHANGELOG's claim holds for the
   game's scenes: **verify and report** any output that changed, with the reason), the client executables
   (`fetch-executables.sh --build`) and the reference trace / state files, `levelc to-cairo --check`.
4. Report the new Cairo steps per shot / per level for every golden case (before / after table) and the new
   flight / impact tick figures.

## 4. Budget
Expected: reference shot well under 3e7 steps; report each level against D10.

## 5. Tests
Every CI job green (`golden` matrix included); `npm test` with the wasm (`vm` job) green.

## 6. Definition of done
`AGENTS.md` §6 crate-scoped on each touched crate; conventional commits with the trailer
`Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push `feat/b1-bump-rapier2d-alpha2`; `gh pr create`;
`gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Before / after steps table · Outputs that
changed and why · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
