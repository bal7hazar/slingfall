# G4c — `outputs` executable in the replay package; CI check of the committed client executables

## 1. Read first
`AGENTS.md`; on `main`: `client/vm/fixtures/outputs/` (G6b's standalone package wrapping
`slingfall_game::chunk::state_outputs`), `crates/slingfall_replay/Scarb.toml` (four `[[target.executable]]`),
`client/vm/scripts/fetch-executables.sh`, `client/vm/fixtures/replay/` (committed executable JSONs, 28 MB),
`.github/workflows/ci.yml` (`vm` job), G6b's escalations 2-3 in `docs/PLAN.md` (G6b row).

## 2. Scope (allowlist)
`crates/slingfall_replay/**` (5th executable `outputs`), `client/vm/fixtures/**` (delete the `outputs` package,
regenerate the committed executables), `client/vm/scripts/**`, `client/src/vm/**` ONLY the executable name /
path constants, `.github/workflows/ci.yml` ONLY the `vm` job (add a step that rebuilds the executables with
`fetch-executables.sh --build` and fails on `git diff --exit-code` of `client/vm/fixtures/replay/`), `client/vm/README.md`.

## 3. Work
1. Add `[[target.executable]] name = "outputs"` to the replay package (function `slingfall_replay::outputs::outputs(state, inputs)`,
   body moved from the client copy), tests for it under the `snforge` profile (golden: the pile10 reference outputs).
2. Regenerate `client/vm/fixtures/replay/*.executable.json` from `main`, delete `client/vm/fixtures/outputs/`.
3. CI: the `vm` job rebuilds the executables and fails on a diff; measure the added time (report it); if the
   rebuild exceeds ~4 min, escalate the alternative (build in-job, do not commit).
4. Client: `npm test` green (the real-replay tests of G6b keep passing with the regenerated files).

## 4. Budget
No step change of any executable (`outputs` 41k steps as measured by G6b).

## 5. Tests
Replay `snforge test --profile snforge outputs`; `npm test`; the CI diff step green.

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/g4c-outputs-executable-ci`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`.

## 7. Work autonomously, do not ask questions, do not widen the scope.
