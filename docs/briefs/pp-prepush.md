# PP — a pre-push check: `scripts/prepush.sh` and its hook

Profile `impl-sonnet` (a clear tooling task). Lot id `pp-prepush`, branch `feat/pp-prepush`.

## 1. Goal and context

**Goal.** Stop pushing red CI. The owner counted 22 failed runs out of about 770 across the programme since
2026-10-01. About 15 of them a local check of seconds to minutes would have stopped. For slingfall these were mostly
pins and executables that were not regenerated. Give the repository a short local check that every push runs.

Read first: `AGENTS.md`, `README.md` (commands, one heavy command at a time on the shared machine),
`.github/workflows/ci.yml` (what CI runs, job by job), `OPERATIONS.md` §5 (the build-path rule: class hashes are
pinned from CI's output only, so a local class-hash difference is not a failure), `docs/proving.md` ("Deterministic
builds"),
`crates/slingfall_split/scripts/pin.py` (`--check`), `scripts/steps.py`, `tools/classsize/classsize.py`,
`client/vm/scripts/fetch-executables.sh`.

## 2. Transactions

None. No script of this lot sends anything to any network.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `scripts/prepush.sh` (new), `scripts/install-hooks.sh` (new), `.githooks/pre-push` (new).
- `AGENTS.md`: one short rule. Run `scripts/install-hooks.sh` once per clone, run `scripts/prepush.sh` (the hook does)
  before every push, never push red, never skip the hook.
- **Not** `.github/workflows/**` and **not** `README.md`: the running TC lot changes both. The download retries
  and the README line are a separate lot after TC merges.

## 4. Work

1. **`scripts/prepush.sh`**, bash, `set -euo pipefail`, `RAYON_NUM_THREADS=1` exported, committed **mode 100755**.
   It diffs against `git merge-base HEAD origin/main` (local ref, **no fetch**; `--base REF` overrides it). Output: one
   line per check (`ok` / `FAIL` / `warn` / `skip (inputs unchanged)` / `skip (use --full)`), then the total time.
   Exit non-zero on any `FAIL`. The **default run aims at under 2 minutes** on the VPS, not counting the wait for the
   heavy-build lock. `--full` adds the slow checks.

   **Default checks**, each only when its trigger paths changed (except the first):
   - always: `scarb fmt --check --workspace` and `scarb --manifest-path crates/slingfall_replay/Scarb.toml fmt --check`
     (the CI `fmt` job); `python3 -m py_compile` on changed `*.py`; `bash -n` on changed `*.sh`;
   - Python unit tests, by directory (trigger: that directory):
     `services/attest` → `python3 -m unittest discover -s services/attest`;
     `tools/atlantic` → `python3 -m unittest discover -s tools/atlantic -p 'test_*.py'`;
     `services/prove` → `python3 -m unittest discover -s services/prove`;
     `tools/prove` → `python3 tools/prove/test_prove.py` without `PROVE_RUN` (its decoding tests, as the CI `prove` job);
     `tools/settle`, `tools/levelc`, `scripts/play` → `python3 -m unittest discover -s <dir>` (not in CI; run them
     here, and report their time);
   - compile: `scarb build -p <crate>` for each touched workspace crate **and its dependents** (read the dependency
     order from the crates' manifests). The replay is not a workspace member but depends on `slingfall_level`,
     `_rules`, `_game` and `_testing`: build it (`scarb --manifest-path crates/slingfall_replay/Scarb.toml build`) when
     `crates/slingfall_replay/**` or one of those crates changed. If a measured case of §6 exceeds 2 minutes because
     of the dependents, build only the touched crates by default and the dependents under `--full`, and report both
     timings: the orchestrator settles it with the numbers;
   - `python3 tools/golden/golden.py to-cairo --check` (CI `golden` job) when `fixtures/**`, `tools/golden/**` or the
     generated Cairo file changed;
   - class sizes, errors (sizes are path-free): `classsize.py check --no-build` when `slingfall_contract` or a crate it
     depends on changed; `classsize.py split --no-build` when `slingfall_split` or a crate it depends on changed (both
     after the compile step above built them; the CI `build` job's forms). When their output says "CASM not checked"
     (no `starknet-sierra-compile` on PATH), the line reads `ok (CASM not checked)`;
   - class-hash pins, **advisory**: a local build root differs from CI's, so a local pin check cannot tell a stale pin
     from a path difference (OPERATIONS.md §5). When `crates/slingfall_split/**`, a crate it depends on, the root
     manifest or the lockfile changed, print a `warn` line: "split class hashes may move: re-pin from CI's output
     (OPERATIONS §5), not locally". No local `pin.py --check` in the default run.

   **`--full` adds** (each `skip (use --full)` in the default run, with the same triggers):
   - steps: `python3 scripts/steps.py check` (it runs every crate one by one; CI spreads it over 7 jobs);
   - pins, advisory: `pin.py --check`. Its exit 1 is a `warn` only when its output has `stale:` lines; an exit 1
     without them (a compile or test failure) is a `FAIL`. On `stale`, print the pinned value (read from
     `crates/slingfall_split/src/hashes.cairo` or `src/probes/hashes.cairo`) next to the new one, as a `warn`;
   - replay executables (same trigger as the replay build): build the replay, then byte-compare
     `crates/slingfall_replay/target/dev/{main_trace,init,step_chunk,outputs}.executable.json` with
     `client/vm/fixtures/replay/`. **Never run `fetch-executables.sh`** in the script (it overwrites tracked files).

   When Cairo sources changed and `--full` was not run, the last line says which `--full` checks were skipped.
2. **`.githooks/pre-push`** (mode 100755) runs `scripts/prepush.sh` and blocks the push on failure. It does nothing
   for a branch delete (a pushed sha of all zeros) or a tag-only push.
3. **`scripts/install-hooks.sh`** (mode 100755) sets `git config core.hooksPath .githooks`. Run it once in your
   worktree. This writes the shared `.git/config` of the VPS clone, so the VPS main clone and its worktrees are covered
   (allowed in this lot). The Mac clone is set by the orchestrator after the merge.
4. Unit tests: none required for the shell scripts. A failure path is shown in the report instead: break `scarb fmt` on
   a scratch edit, run the script, show the `FAIL` line, revert.

## 5. Machine

The VPS. Heavy commands go through the shims and wait for the heavy-build lock. Never bypass them. Foreground only.

## 6. Definition of done

Conventional commits with your model's trailer; push `feat/pp-prepush` (the hook runs on that push); `gh pr create`;
`gh pr checks --watch` in the foreground until green; never merge; launch no agent and no review.
`REPORT.md` contains:
- the **measured** run time of `scripts/prepush.sh` (real `time` output, not an estimate) in four cases: no Cairo
  change (this branch); one Cairo file touched in `slingfall_rules` (scratch edit, reverted); the same with `--full`;
  one Python file touched in `services/prove`. Say how long each waited for the heavy-build lock, if it did;
- the failure path of §4.4;
- the list of checks with their trigger paths.

Work autonomously, do not ask questions, do not widen the scope.
