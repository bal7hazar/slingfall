# H3 — build, gate and declare only the classes the game's layout calls

## 1. Read first
`AGENTS.md`; `docs/research/07-split-game-step.md` ("Status after H2"); `crates/slingfall_split/Scarb.toml`
(`build-external-contracts = ["rapier2d_classes::*"]`), `crates/slingfall_split/src/hashes.cairo`,
`crates/slingfall_split/scripts/pin.py`, `tools/classsize/classsize.py` (`split`), `deploy/split.ts` (`deploy-split`
declares 17 classes), `services/prove/snip36.py` (`bundle_hash`), `client/src/chain/slingfall.ts`
(`SPLIT_BUNDLE_CLASSES`).

## 2. Facts (rapier orchestrator, 2026-09-28)
For the slim layout on rapier2d_classes 0.1.0-alpha.7 a game declares: `NarrowPhaseClass`, `ContactBallClass`,
`ContactPolygonClass` (still called on alpha.7; no longer after rapier's next release), `SolveAdvanceClass`,
`IslandsClass`, `BroadPhaseClass`, `MassClass`, `ActiveSetClass`, and `ForceEventsClass` only if the game calls it.
`OrchestratorClass` (73,554 CASM, margin 174) and `SolverClass` belong to layouts the game does not use.

## 3. Scope (allowlist)
`crates/slingfall_split/**`, `tools/classsize/**`, `deploy/split.ts`, `deploy/e2e.sh`, `services/prove/snip36.py` and
its tests, `client/src/chain/slingfall.ts` and its tests, `docs/research/07-split-game-step.md`,
`docs/contract-v3.md`, `docs/proving.md`. No deployment on Sepolia, no credentials.

## 4. Work
1. Find by measurement which rapier classes layout (e) and the fallback layout (b) really call (a test that runs the
   reference chain and records the class hashes library-called), and compare with §2.
2. `build-external-contracts` lists exactly those; the class-size gate, the pinned hashes, `deploy-split`, the bundle
   hash (Cairo tests, Python and TypeScript must still agree) use the same single list, generated from one source.
3. Report: classes before / after, the margins table, the new bundle hash, build time of the crate before / after.
4. `deploy/e2e.sh` still passes (the `e2e` CI job green).

## 5. Definition of done
`AGENTS.md` §6; conventional commits with the trailer of the model you are (`Co-Authored-By: Claude <model name>
<noreply@anthropic.com>`); push `feat/h3-declared-classes-only`; `gh pr create`; `gh pr checks --watch` in the
foreground until green; never merge; `REPORT.md`. Foreground only. Heavy runs one at a time under the heavy-run lock.
Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs.
