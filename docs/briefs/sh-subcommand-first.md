# SH — every `scarb` call puts its subcommand first, so the machine's heavy lock sees it

Profile `impl-sonnet` (a mechanical rewrite). Lot id `sh-subcommand-first`, branch `fix/sh-subcommand-first`.

## 1. Goal and context

The VPS `scarb` shim (outside this repository; it belongs to the owner) recognises the subcommand on `$1` only.
`scarb --manifest-path X build|test|check|lint|execute` therefore takes no heavy-build lock and runs outside the
machine's memory serialisation. The Overseer's rule for the whole programme: nothing relies on that gap. Every call
is rewritten to the form `scarb <subcommand> --manifest-path X ...`.

`scripts/build-shims/lock.sh` already parses global options, but only the old `executor.sh` used it. herdr threads go
through the machine shim, so this lot fixes the callers, not the shim.

Other lots carry the rest of the same rewrite, and their files are not in this one:
- `.github/workflows/ci.yml` and the manifests' comments: the toolchain lot (TC);
- `deploy/devnet.sh` and `scripts/play.sh`: lot L4;
- `tools/golden/golden.py`: lot HS;
- `scripts/prepush.sh`: lot PP.

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
- Text that shows the old form, for consistency: the docstrings or messages of `tools/levelc/rules.py:4`,
  `tools/settle/settle.py:4`, `tools/prove/verify.py:214` and `services/prove/prove_service.py:89`, `:327`.
- Any other call with a global option before the subcommand that your own grep finds outside the files of §1's list
  (`--manifest-path`, `--profile`, `-P`, `--offline`, `--target-dir` ...). List each one in the report.
- `REPORT.md`.

## 4. Work

1. Rewrite each call: subcommand first, options after it, with the arguments and their order otherwise unchanged
   (`scarb --manifest-path X execute --executable-name ...` becomes `scarb execute --manifest-path X
   --executable-name ...`). Check in `scarb <sub> --help` that each option is accepted after the subcommand.
2. `bash -n` on each shell script; `python3 -m py_compile` on each Python file; the Python unit tests of the
   directories touched (`python3 -m unittest discover -s services/prove`, `python3 tools/prove/test_prove.py` without
   `PROVE_RUN`).
3. A final `git grep` showing that no `scarb --<option> ... <sub>` call is left in executable code outside the
   files other lots hold (§1).

## 5. Machine

The VPS. No heavy build is needed. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `fix/sh-subcommand-first`, then `gh pr create`, then `gh pr checks --watch` in the foreground until green.
- Never merge; launch no agent and no review.
- `REPORT.md`: every call rewritten (file, line, before and after), and the final grep.

Work autonomously, do not ask questions, do not widen the scope.
