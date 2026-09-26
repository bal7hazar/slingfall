# G8b — retune and pre-settle `pile10` / `cores3`; CI matrix, client level list, Cairo fixtures for all levels

## 1. Read first
`AGENTS.md`; `docs/levels.md` (G8's workflow and measured values); on `main`: `tools/settle/settle.py`,
`tools/levelc/{levelc,rules}.py` (`check --rules`, `to-cairo`), `tools/golden/golden.py` (`--update`, `to-cairo`),
`fixtures/levels/`, `fixtures/golden/cases.json`, `crates/slingfall_level/src/level/fixtures.cairo`,
`crates/slingfall_replay/tests/golden.cairo`, `client/src/main.ts` (`LEVELS`), `.github/workflows/ci.yml` (`golden` matrix).
G8's escalations are this lot.

## 2. Scope (allowlist)
`fixtures/levels/{pile10,cores3}.json` + felts, `client/public/levels/**`, `fixtures/golden/**`,
`crates/slingfall_level/src/level/fixtures.cairo` (regenerated only), `crates/slingfall_replay/tests/golden.cairo`
(regenerated only), `crates/slingfall_game/src/fixtures.cairo` (reference inputs / outputs if the reference shot
changes), `crates/slingfall_contract/src/submit/fixtures.cairo` (golden vectors), `client/src/main.ts` (only the
`LEVELS` list; add a `levels.json` index under `client/public/levels/` if it makes the list data-driven; then
`client/src/**` only where the index is read), `.github/workflows/ci.yml` ONLY the `golden` matrix,
`docs/levels.md`, `steps/**` snapshots of the regenerated probes.

## 3. Work
1. `pile10` and `cores3`: materials on G8's tuned values, `tick_cap` 180, pre-settled with `settle.py`,
   `check --rules` green (report the tables).
2. Regenerate everything that depends on their hashes / results in one PR: `levelc to-cairo` (all five
   levels + one_block), `golden.py --update` for the `pile10-*` / `cores3-*` cases, `golden.py to-cairo`, the
   game / contract reference fixtures (the reference shot may change: pick the pull that wins `pile10` in
   one shot after retuning, keep it as `reference_inputs`), `steps.py snapshot` of the affected probes; list
   every changed golden with before / after steps.
3. CI `golden` matrix: add `tower`, `bridge`, `twin` (report the job times; if a leg exceeds ~8 min, split it).
4. Client: the five levels + `one_block` selectable (index file or list); `npm test` green.

## 4. Budget
Reference shots per level ≤ 1e8 steps (report; note which are above 3e7).

## 5. Tests
All CI jobs green; `levelc.py check --rules` green on the five levels (local, documented command).

## 6. Definition of done
`AGENTS.md` §6 (crate-scoped: level, game, replay `--manifest-path`, contract tests); conventional commits with the
trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push `feat/g8b-legacy-levels`; `gh pr create`;
`gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Levels table · Changed goldens table ·
CI times · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
