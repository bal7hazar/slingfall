# G5 — determinism and budget CI: golden replays, three builds agree, input fuzzing, step ceilings

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D4, D10; `docs/PLAN.md` (budgets, G4 row); on `main`: `crates/slingfall_replay/`
(README: argument layouts, `tools/tracec/tracec.py args`), `scripts/steps.py`, `.github/workflows/ci.yml`
(the `build` job's replay smoke step), `fixtures/levels/*.felts.json`, `fixtures/traces/pile10-reference.json`.
Note: G4b (library split, Sonnet) may run in parallel and move code between crates; keep this lot's tests
in `crates/slingfall_replay/tests/` or under `tools/` so that a rebase is trivial.

## 2. Scope (allowlist)
`tools/golden/**` (new, Python 3 stdlib), `fixtures/golden/**` (new), `.github/workflows/ci.yml` ONLY to add
one `golden` job (and to `all-checks`), `crates/slingfall_replay/tests/**` (new snforge tests only),
`crates/slingfall_replay/README.md` section.

## 3. Work
1. `tools/golden/golden.py`: for every case in `fixtures/golden/cases.json` (level fixture + shots; start with
   pile10 reference, pile10 three shots, cores3 one and three shots, one_block miss, one_block with delay 30,
   a pull on the disk boundary, a pull outside the disk (clamped)): run `scarb execute` of `main`, `main_trace`
   and the chained `init` / `step_chunk` (K from a list: 1, 7, 60) and assert the 10 outputs are identical
   across the three builds and equal to the committed golden in `fixtures/golden/<case>.json` (outputs +
   Cairo steps of `main`). `--update` rewrites goldens; `--check` fails on any difference; a step ceiling per
   case = golden steps × 1.10, failing when exceeded (a lower value prompts `--update`).
2. Input fuzzing: `golden.py fuzz --seed S --n 20`: random pulls / delays / shot counts on each fixture level;
   `main` ≡ chained chunks (K random) for each; no golden stored; run in CI with a fixed seed and n = 6.
3. CI job `golden` (Ubuntu runner, scarb via setup-scarb): `--check` then `fuzz`; time it; if above ~8 min,
   split the matrix per level. Add to `all-checks`.
4. snforge: one test per fixture that `main` on the golden inputs returns the golden outputs (felts copied
   from the golden files by a `golden.py to-cairo` generator with `--check`).

## 4. Budget
The CI job under 8 minutes; document the measured time.

## 5. Tests
`golden.py --check` green on the committed goldens; a deliberate one-felt change to a golden makes it red
(show it in the report, then revert); the fuzz run reports zero mismatches.

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/g5-determinism-ci`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · Cases and goldens table with steps · CI time · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
