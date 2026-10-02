# CP — CI runs a test job only when its inputs changed (and PP2: retries, Pages, L4's tests)

Profile `impl-sonnet` (a workflow change with a mapping given). Lot id `cp-ci-paths`, branch `ci/cp-ci-paths`.
**Workflow file changed by this lot: `.github/workflows/ci.yml`** (rule nexus #60).

## 1. Goal and context

**Owner's rule (2026-10-02):** "CI tests must absolutely run only if files related to the tests were modified, so
docs should skip all tests."
- On a pull request, each test job runs only when files that concern it changed. The workflow computes this itself
  from the changed paths (never from a label). A docs-only PR runs no test job.
- `gh pr checks` must always return a result: a light final job, `all-checks`, always runs. It passes when every job
  that ran passed and every skipped job was skipped by the rule.
- **Pushes to `main` keep their full CI**, and so does `workflow_dispatch`: every job runs.
- A change to the toolchain or the workflow itself triggers everything: `.tool-versions`, any `Scarb.toml` or
  `Scarb.lock`, and `.github/workflows/**`.
- **Prose `.md` triggers nothing; a checked `.md` triggers the job that checks it.** A table that a script
  regenerates and compares is a checked file. In slingfall no CI job reads a `.md` as a checked artefact today: `grep`
  of `ci.yml` and the scripts finds only comments. If you find one, it triggers its job; list it in the report.

**Folded in, since they also edit `ci.yml` (formerly lot PP2):**
- one or two retries on the steps that download scarb or snforge (the HTTP 500 failures);
- the `pages` job in a concurrency group of its own, so that a push to main can never replace a pending dispatch.
  (Already on main: `cancel-in-progress` for pull requests only.)
- L4's shell tests in CI: `bash scripts/play/test_devnet_shim.sh` and `bash scripts/play/test_play_instance.sh`,
  in `play-local` before `up (cold)`, or in a light job of their own.

**How to edit.** Edit `.github/workflows/ci.yml` with the file-editing tool only, never by a script that rewrites
it (programme rule).

Read first:
- `.github/workflows/ci.yml` on main, in full (13 jobs);
- `docs/briefs/l4-devnet-shim.md` and `docs/briefs/pp-prepush.md` (their notes on CI);
- `OPERATIONS.md` §6 (what gates a merge).

## 2. Transactions

None.

## 3. Scope (allowlist)

- `.github/workflows/ci.yml`.
- `REPORT.md` (not committed).
- Nothing else. If a job needs a script change to be filtered, escalate.

## 4. The mapping: job → paths that trigger it on a pull request

`T` is the toolchain and workflow set, which triggers every job: `.tool-versions`, `**/Scarb.toml`, `**/Scarb.lock`,
`.github/workflows/**`. Each row also triggers on `T`.

Shared sets, used below:
- `PY` (the Python tools and fixtures the services, scripts and tests import or read): `tools/atlantic/**`,
  `tools/golden/**`, `tools/tracec/**`, `tools/levelc/**`, `fixtures/levels/**`, `fixtures/golden/**`;
- `CLIENT` (what `npm test` / `npm run build` read): `client/**`, `fixtures/levels/**`, `fixtures/traces/**`,
  `fixtures/golden/**`, `deploy/sepolia.json`, `deploy/sepolia.env.example`.

| Job | Runs on a PR when any of these changed (besides `T`) | Why (what it reads) |
|---|---|---|
| `fmt`, `lint` | `crates/**` | `scarb fmt` / `lint` of the workspace and the replay |
| `build` | `crates/**`, `tools/classsize/**`, `tools/tracec/**`, `fixtures/levels/**` | workspace build, class sizes, split determinism, one replay execute |
| `test` (matrix) | `crates/**`, `fixtures/**`, `steps/**`, `scripts/steps.py` | snforge per crate; its logs feed `steps` |
| `steps` | exactly when `test` runs: `needs: [changes, test]`, same output as `test` | `scripts/steps.py check` on the test logs |
| `client` | `CLIENT` | lint, unit tests, both builds, the Sepolia smoke |
| `vm` | `CLIENT`, `crates/**`, `fixtures/**` | runner tests, wasm build, `fetch-executables.sh --build` + diff, the whole `npm test` (incl. `vm.test.ts` on `fixtures/golden`) |
| `golden` (matrix) | `crates/**`, `fixtures/**`, `tools/golden/**`, `tools/tracec/**`, `tools/levelc/**` | golden check and fuzz per level |
| `prove` | `tools/prove/**`, `tools/tracec/**`, `tools/levelc/**`, `crates/**`, `fixtures/levels/**`, `fixtures/golden/**`, `fixtures/proofs/**` | stwo proving of one case; `prove.py`, `verify.py`, `test_prove.py` import tracec / levelc and read `fixtures/golden` |
| `e2e` | `services/**`, `deploy/**`, `crates/**`, `tools/settle/**`, `PY`, `fixtures/proofs/**`, `client/src/chain/**`, `client/package*.json` | attest / prove unit tests (`test_prove_service.py` reads `fixtures/proofs/atlantic`), v2 class, `deploy/e2e.sh` (`deploy/outputs.py` imports `tools/golden`, `tools/atlantic`) |
| `play-local` (+ L4's tests) | `scripts/play.sh`, `scripts/play/**`, `deploy/**`, `services/**`, `crates/**`, `PY`, `CLIENT` | `play.sh up` (attest `--execute`, `prove_local.py` imports `services/prove` and `tools/golden`), a shot, `down` |
| `pages` | unchanged: `workflow_dispatch` only. **Not** in `all-checks`. | |
| `all-checks` | always | the summary |

**Docs-only PRs.** The globs above also match prose READMEs inside code folders (`crates/*/README.md`,
`client/README.md`, `tools/*/README.md`…). `dorny/paths-filter`'s negation does not combine with OR rows under the
default `predicate-quantifier: some`, so do not use `!` patterns. Instead, the `changes` job outputs `docs_only`: true
when every changed path ends in `.md` and none of them is a checked file (there is none in slingfall today). Every test
job's condition is `docs_only == 'false' && <its row> == 'true'`. A PR that mixes a README with code is filtered by
its code. Drop the `client/vm/runner/**` exclusion idea: `CLIENT` includes it, a safe over-trigger.

These rows are my reading of what each job uses. **Before relying on them, check each one against the job's actual
steps** (what it builds, reads and runs, including scripts the steps call), and widen a row wherever a job reads more.
In doubt, trigger, never skip. Report every change to the table, with the reason.

## 5. Work

1. **A `changes` job** computes the changed paths of the pull request (`git diff --name-only` between the PR's base
   and head, after a checkout with enough history). It outputs one boolean per row of §4.
   - Use `dorny/paths-filter@ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d # v4.0.3`, pinned by commit sha as in
     nalgebra-cairo's `ci.yml`, with one filter per row of §4.
   - On `push` to main and on `workflow_dispatch`, every output is `true`.
2. Each test job gets `needs: changes` and an `if:` on its outputs (§4, docs-only rule). `steps` takes
   `needs: [changes, test]` and the same output as `test`. Keep each job's name, so a check that does not run simply
   reports as skipped.
3. **`all-checks`**:
   - `if: always()`, and it needs `changes` and every test job, including `vm`, `prove`, `e2e` and `play-local`, but
     not `pages`. Today it waits only
     for `fmt`, `lint`, `build`, `test`, `steps`, `golden` and `client`. Widening it to the four others is a change of
     merge gate: do it only if those four are green on main today, and say so; otherwise keep today's set and report.
   - It fails unless `needs.changes.result` is exactly `success` (if `changes` fails, every output is empty and nothing
     ran: that must be red).
   - For each test job, a skip is legitimate only when its output is exactly `'false'` (or `docs_only` is exactly
     `'true'`). A job whose output is `'true'` must be exactly `success`. Any other combination fails: an empty output, a
     failure, a cancellation, or a skip while the output was true.
   - Print each job, its output and its result.
4. **Retries** on the steps that download the tools (`software-mansion/setup-scarb`, `foundry-rs/setup-snfoundry`):
   one or two retries with a short pause, by a pinned retry action or by repeating the step with `continue-on-error`
   on the first try. Say which. Never retry a test.
5. **A dispatch can no longer be replaced.** GitHub keeps one pending run per concurrency group, and a newer pending
   run replaces the older one; a job-level group cannot help, since it applies only after the run starts. So the
   **workflow-level** group separates dispatches:
   `group: ${{ github.workflow }}-${{ github.ref }}-${{ github.event_name == 'workflow_dispatch' && github.run_id || 'ci' }}`,
   with `cancel-in-progress` unchanged. Keep a `pages` job-level group too, `pages-${{ github.ref }}`,
   `cancel-in-progress: false`.
6. **L4's tests** run where §1 says, triggered by `scripts/play/**`, `deploy/devnet.sh` and `T`.

## 6. Verification

Show, with links to the runs of this PR's branch (or a scratch branch of yours, deleted afterwards):
- a **docs-only change**, including a `crates/*/README.md`: every test job skipped, `all-checks` green;
- a **client-only change**: `client` (and `vm`, `e2e`, `play-local` as mapped) run, the Cairo jobs skipped,
  `all-checks` green;
- a **Cairo change** in `crates/slingfall_rules`: the Cairo jobs run;
- the PR itself: it touches `.github/workflows/**`, so everything runs.

Push to scratch branches sparingly: the Actions queue is saturated.
- At most four runs in total. Make them small commits on one scratch branch, each pushed only after the previous run
  finished.
- At most one `gh` call every 5 minutes.
- Delete the scratch branch at the end.

## 7. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `ci/cp-ci-paths` once, then `gh pr create`. Never merge; launch no agent and no review.
- `REPORT.md`: the final mapping table with your changes, the `all-checks` logic, the retry method, and the runs of §6.

Work autonomously, do not ask questions, do not widen the scope.
