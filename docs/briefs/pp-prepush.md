# PP — a pre-push check: `scripts/prepush.sh` and its hook

Profile `impl-sonnet` (a clear tooling task). Lot id `pp-prepush`, branch `feat/pp-prepush`.

## 1. Goal and context

**Goal.** Stop pushing red CI. The owner counted 22 failed runs out of about 770 across the programme since
2026-10-01. About 15 of them a local check of seconds to minutes would have stopped. For slingfall these were mostly
pins and executables that were not regenerated. Give the repository a short local check that every push runs.

Read first: `AGENTS.md`, `README.md` (commands, one heavy command at a time on the shared machine),
`.github/workflows/ci.yml` (what CI runs, job by job), `docs/proving.md` ("Deterministic builds", the build-path rule:
class hashes are pinned from CI's output only, so a local class-hash difference is not a failure),
`crates/slingfall_split/scripts/pin.py` (`--check`), `scripts/steps.py`, `tools/classsize/classsize.py`,
`client/vm/scripts/fetch-executables.sh`.

## 2. Transactions

None. No script of this lot sends anything to any network.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `scripts/prepush.sh` (new), `scripts/install-hooks.sh` (new), `.githooks/pre-push` (new).
- `AGENTS.md`: one short rule. Run `scripts/install-hooks.sh` once per clone, run `scripts/prepush.sh` (the hook does)
  before every push, never push red, never skip the hook.
- `README.md`: one line in the commands table.
- **Not** `.github/workflows/**`. The download retries are a separate lot after the TC lot merges, because TC changes
  `ci.yml`.

## 4. Work

1. **`scripts/prepush.sh`**, bash, `set -euo pipefail`, `RAYON_NUM_THREADS=1` exported. **Under 2 minutes** on the VPS
   for a typical lot. It compares against the merge base with `origin/main` (`git merge-base HEAD origin/main`;
   `--base REF` overrides it) and runs:
   - always: `scarb fmt --check --workspace` and the replay's `scarb --manifest-path crates/slingfall_replay/Scarb.toml
     fmt --check`; `python3 -m py_compile` on changed `*.py`; `bash -n` on changed `*.sh`;
   - the unit tests of the Python scripts whose directory changed, as CI runs them (`python3 -m unittest discover`, the
     same `-s` / `-p` arguments as `ci.yml`);
   - `scarb build -p <crate>` for each touched crate of the workspace, plus the replay build if
     `crates/slingfall_replay/**` changed;
   - **generated artefacts, only when their inputs changed**: the step snapshots (`scripts/steps.py`) when Cairo
     sources, manifests or `steps/**` changed; `pin.py --check` when `crates/slingfall_split/**`, the root manifest or
     the lockfile changed; the class-size check (`classsize.py check`) in the same case; the replay executables
     (`fetch-executables.sh`'s check mode, or a byte comparison with `client/vm/fixtures/replay/`) when the replay
     changed. Read each tool's options; do not invent flags. If an artefact check alone takes more than 2 minutes, run it
     only with `--full` and say so in the script's help and the report.
   - **Class hashes**: a local build root differs from CI's, so a class-hash pin check can fail locally on a class that
     holds a closure while CI passes. A class-hash mismatch is a **warning** that names both values. Sizes, steps and
     CASM-side checks are path-free and stay errors.
   - Output: one line per check (`ok` / `FAIL` / `skip (inputs unchanged)`) and the total time. Exit non-zero on any
     failure.
2. **`.githooks/pre-push`** runs `scripts/prepush.sh` and blocks the push on failure.
3. **`scripts/install-hooks.sh`** sets `git config core.hooksPath .githooks`. Run it once in your worktree. This writes
   the shared `.git/config` of the VPS clone, so the VPS main clone and its worktrees are covered (allowed in this lot).
   The Mac clone is set by the orchestrator after the merge.
4. Unit tests: none required for the shell scripts. A failure path is shown in the report instead: break `scarb fmt` on
   a scratch edit, run the script, show the `FAIL` line, revert.

## 5. Machine

The VPS. Heavy commands go through the shims and wait for the heavy-build lock. Never bypass them. Foreground only.

## 6. Definition of done

Conventional commits with your model's trailer; push `feat/pp-prepush` (the hook runs on that push); `gh pr create`;
`gh pr checks --watch` in the foreground until green; never merge; launch no agent and no review.
`REPORT.md` contains:
- the **measured** run time of `scripts/prepush.sh` (real `time` output, not an estimate) in three cases: no Cairo
  change (this branch), one Cairo file touched in a crate (scratch edit, reverted), and `--full` if it exists;
- the failure path of §4.4;
- the list of checks with their trigger paths.

Work autonomously, do not ask questions, do not widen the scope.
