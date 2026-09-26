# B2 — bump to `rapier2d = "=0.1.0-alpha.3"` (BT3 + BT4), adopt the cheap activation reads

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D5, D11; rapier-cairo `CHANGELOG.md` for 0.1.0-alpha.3 (registry source after
`scarb fetch`): results bit-identical to alpha.2, `WorldState` unchanged (v2), new `ArenaField` / `get_field` and
`RigidBodySet::get_field` with `BodySleeping` / `BodyLinvel` / `BodyAngvel` / `BodyPose` selectors (88 steps per
read instead of 146-269); B1's report note (`docs/PLAN.md` B1 row): the alpha.2 accessors were measured worse in
`calm.cairo` because they still copied the body. On `main`: `crates/slingfall_rules/src/{calm,world}.cairo`,
`tools/golden/golden.py`, `fixtures/golden/`, `client/vm/scripts/fetch-executables.sh`, `steps/**`.

## 2. Scope (allowlist)
Root `Scarb.toml`, `crates/slingfall_replay/Scarb.toml`, `client/vm/fixtures/ball_drop/Scarb.toml` (version pins) + lockfiles;
`crates/slingfall_rules/src/**`; `steps/**`; `fixtures/golden/**`; `crates/slingfall_replay/tests/golden.cairo` and the
game / contract reference fixtures (regenerated only if an output changes: none expected); `client/vm/fixtures/**`
(rebuilt executables and the stand-in); `fixtures/traces/pile10-reference.json` (only if changed).

## 3. Work
1. Pin `=0.1.0-alpha.3` everywhere; build.
2. `calm.cairo` and any other activation / velocity scan: use `get_field` selectors (`BodySleeping`, `BodyLinvel`,
   `BodyAngvel`, `BodyPose`) instead of `World::body` copies where only those fields are needed; measure
   `steps_calm__update` and `steps_tick__pile10_flight` before / after and keep the cheaper form (report both).
3. Regenerate steps snapshots, goldens (`--update` then `to-cairo`), executables; assert all 11 goldens' outputs are
   bit-identical to alpha.2 (report any change with the reason).
4. Before / after steps table per golden case and per tick.

## 4. Budget
Expected: every case cheaper; report.

## 5. Tests
All CI jobs green (`golden` matrix, `vm`).

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/b2-bump-rapier2d-alpha3`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`.

## 7. Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs.
