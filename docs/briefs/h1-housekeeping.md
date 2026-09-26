# H1 — housekeeping after B1: stand-in on alpha.2, validator LEGACY list, `cores3` golden leg, browser check script

## 1. Read first
`AGENTS.md`; on `main`: `client/vm/fixtures/ball_drop/` (stand-in package pinning four `=0.1.0-alpha.1`
crates), `client/vm/fixtures/pile12-mode3-120.state.txt`, `client/src/vm/vm.test.ts` (which fixtures it uses),
`tools/levelc/rules.py` (`LEGACY`), `.github/workflows/ci.yml` (`golden` job: cores3 leg 8m10s),
`client/vm/scripts/browser-check.py` (unrun), `docs/PLAN.md` open points.

## 2. Scope (allowlist)
`client/vm/fixtures/ball_drop/**` + `client/vm/fixtures/pile12-mode3-120.state.txt` + the `ball_drop.executable.json`,
`client/src/vm/*.test.ts` (numbers only if the stand-in's goldens change), `tools/levelc/rules.py`,
`.github/workflows/ci.yml` ONLY the `golden` job (split each leg into `check` and `fuzz` steps as two matrix
entries, or shard `cores3`), `client/vm/scripts/browser-check.py`, `client/vm/README.md`.

## 3. Work
1. Bump the `ball_drop` stand-in to `=0.1.0-alpha.2` (all four crates), rebuild its executable, regenerate
   `pile12-mode3-120.state.txt` (WorldState v2), rerun the `vm` tests through CI; report the new step count of
   the 120-tick run (was 39 990 765).
2. `rules.py`: drop `pile10` / `cores3` from `LEGACY` (only `one_block` stays); `levelc.py check --rules` on
   the five levels still green (`--jobs 2`).
3. `golden` job: bring every leg under 8 minutes (two matrix entries per level: `check` and `fuzz`, or shard
   `cores3`'s fuzz); report the new leg times from the PR run.
4. `browser-check.py`: make it runnable where Firefox launches (`--firefox <path>`, `--timeout`); try it here once
   (`which firefox`); if the sandbox refuses, say so and leave the script documented in the README.

## 4. Budget
No step change anywhere except the stand-in's own figures.

## 5. Tests
CI green (`vm`, `golden` matrix, everything else).

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/h1-housekeeping`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`.

## 7. Work autonomously, do not ask questions, do not widen the scope.
