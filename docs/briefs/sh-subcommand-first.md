# SH — every `scarb` call puts its subcommand first (run from the package's directory), so the machine's heavy lock sees it

Profile `impl-sonnet` (a mechanical rewrite). Lot id `sh-subcommand-first`, branch `fix/sh-subcommand-first`.

## 1. Goal and context

The VPS `scarb` shim (outside this repository; it belongs to the owner) recognises the subcommand on `$1` only.
`scarb --manifest-path X build|test|check|lint|execute` therefore takes no heavy-build lock and runs outside the
machine's memory serialisation. The Overseer's rule for the whole programme: nothing relies on that gap.

**`scarb <subcommand> --manifest-path X` does not work**: scarb accepts `--manifest-path` only before the subcommand
(`scarb build --manifest-path X` fails with "unexpected argument '--manifest-path' found", checked on 2.19.4 and
2.20.1). So every call is rewritten to run scarb **from the package's directory**, with the subcommand first:
`(cd X && scarb build ...)` in shell, `subprocess.run(["scarb", "build", ...], cwd=X)` in Python. Any other global
option before the subcommand moves after it only if `scarb <sub> --help` lists it; otherwise use the directory form or
an environment variable scarb documents.

**Same package, same target.** A member directory of a workspace may resolve to the whole workspace, not only that
member. For each rewritten call, build once with the old form and once with the new, and compare the artefacts it
produces (the file list under `target/` and their sha256). Report the comparison. If they differ, add the selector
that restores the old scope (for example `-p <package>`) and compare again.

`scripts/build-shims/lock.sh` already parses global options, but only the old `executor.sh` used it. herdr threads go
through the machine shim, so this lot fixes the callers, not the shim.

Other lots carry the rest of the same rewrite, and their files are not in this one:
- `.github/workflows/ci.yml` and the manifests' comments: the toolchain lot (TC);
- `deploy/devnet.sh` and `scripts/play.sh`: lot L4;
- `tools/golden/golden.py`: lot HS;
- `scripts/prepush.sh`: lot PP.
- Deferred to a documents lot after TC merges (entry in `docs/PLAN.md`, row SH): the message at
  `deploy/slingfall.ts:290` (TC edits that file), and the docs people copy commands from: `README.md`,
  `client/vm/README.md`, `docs/e2e.md`, `docs/levels.md`, `docs/proving.md`, `docs/testers.md`,
  `scripts/executor/system-prompt.md`, `tools/settle/README.md`, `tools/tracec/README.md`.

## 2. Transactions

None. Run no deploy script: a syntax check and the tests of §4 are the verification.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- Calls to rewrite (found on main at fc00698, by a grep of `scarb --manifest-path` and `"scarb", "--manifest-path"`):
  - `client/vm/scripts/fetch-executables.sh:24`
  - `deploy/e2e.sh:90`
  - `deploy/sepolia.sh:77`, `:210`
  - `deploy/v2.sh:27`
  - `crates/slingfall_replay/scripts/measure.py:54`
  - `tools/prove/prove.py:92`, `:205`
- Text that shows the old form, for consistency: the docstrings or messages of `tools/prove/prove.py:4`,
  `tools/levelc/rules.py:4`,
  `tools/settle/settle.py:4`, `tools/prove/verify.py:214` and `services/prove/prove_service.py:89`, `:327`.
- Any other call with a global option before the subcommand that your own grep finds outside the files of §1's list
  (`--manifest-path`, `--profile`, `-P`, `--offline`, `--target-dir` ...). List each one in the report.
- `REPORT.md`.

## 4. Work

1. Rewrite each call to the directory form: `scarb --manifest-path X/Scarb.toml execute --executable-name ...`
   becomes `(cd X && scarb execute --executable-name ...)`, or `cwd=X` in Python. Paths given to scarb relative to the
   old working directory (for example `--arguments-file`) are made absolute or adjusted for the new one.
2. The artefact comparison of §1 for each call. The old-form build runs on the VPS under
   `flock -w <s> ~/orchestrator/heavy-build.lock env HEAVY_BUILD_LOCK_HELD=1 …`, never bare; or both run on the Mac.
3. `bash -n` on each shell script; `python3 -m py_compile` on each Python file; the Python unit tests of the
   directories touched (`python3 -m unittest discover -s services/prove`, `python3 tools/prove/test_prove.py` without
   `PROVE_RUN`).
4. A final grep with both forms, showing that no call with an option before the subcommand is left in the files
   this lot holds: `git grep -nE 'scarb (--|-[A-Za-z])'` (shell and text) and `git grep -nE '"scarb", *"-'` (Python
   lists). Quote what remains and which lot holds it.
5. Quote the `scarb build --help` and `scarb execute --help` lines for every option kept after the subcommand, and
   run one real `(cd crates/slingfall_replay && scarb execute --no-build ...)` on a small case (`one_block`)
   through the shim, showing that the shim took the heavy lock (foreground).

## 5. Machine

The Mac (`/Users/bal7hazar/git/slingfall`): the comparisons build Cairo but write no pin. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `fix/sh-subcommand-first` once, when the work is complete, then `gh pr create`. Do not poll the checks: at most
  one `gh` call every 5 minutes, or report and stop with the checks still running.
- Never merge; launch no agent and no review.
- `REPORT.md`: every call rewritten (file, line, before and after), and the final grep.

Work autonomously, do not ask questions, do not widen the scope.
