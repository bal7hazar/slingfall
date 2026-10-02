# L4 — `play.sh up` stops silently on a first run with an unset asdf shim of starknet-devnet

Profile `impl-sonnet` (a small bug with a probable cause and a clear fix). Lot id `l4-devnet-shim`, branch
`fix/l4-devnet-shim`.

## 1. Goal and context

**Symptom** (the owner's session, local-play test on the Mac, 2026-10-02): the machine has an asdf shim of
`starknet-devnet` with no version set. On the first `scripts/play.sh up`, the script stops silently right after
`devnet: installed …`. A second launch succeeds: the four services start, and the page answers on both LAN addresses.

**Probable cause** (read in the script, not proven by an isolated test):
1. `install_devnet` (`deploy/devnet.sh`) first calls `starknet-devnet --version`, which resolves to the failing asdf
   shim, and bash caches that path.
2. The binary is then downloaded into `deploy/.devnet/bin`.
3. The second call, `starknet-devnet --version` at the end of `install_devnet` (line 85), reuses the cached shim and
   fails.
4. `set -e` ends the script with no message.

**Probable fix:** `hash -r` after the installation, or call the binary by its path.

Read first: `deploy/devnet.sh` (`install_devnet`, `up`, the `DEVNET_VERSION` and `BIN_DIR` lines, the comment at line
51 on asdf), `scripts/play.sh` (`up`), `scripts/play/test_play_instance.sh` (an existing script test to imitate),
`docs/play-local.md`.

## 2. Transactions

None. The devnet is local.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `deploy/devnet.sh`, `scripts/play.sh`: the fix and the error messages.
- `scripts/play/test_devnet_shim.sh` (new): the regression test.
- `docs/play-local.md`: one line under troubleshooting, if it has such a section.
- `REPORT.md`.
- **Not** `.github/workflows/**`: the running toolchain lot changes `ci.yml`. Wiring the new test into CI belongs to a
  later lot (PP2): say in the report which job and which command it needs.

## 4. Work

1. **Reproduce first**, on the VPS, in a temporary `PATH` and a temporary copy or `HOME` that touches nothing of the
   machine's own asdf:
   - put first in `PATH` a stub `starknet-devnet` that behaves like an asdf shim with no version set (it prints
     asdf's "No version is set for command starknet-devnet" message on stderr and exits non-zero);
   - make sure the real binary is not already in `deploy/.devnet/bin` of the copy;
   - run `deploy/devnet.sh` (or the shortest path through `install_devnet`) and show the silent stop: the last line,
     the exit code, and that `hash` lists the stub.
   If the cause turns out to be different, say what it is with the evidence, and fix that instead.
2. **Fix it**: after installing into `BIN_DIR`, either run `hash -r` or call the binary by its full path everywhere
   `install_devnet` and `up` use it. Choose the one that also works when `BIN_DIR` is not first in `PATH`, and say why.
3. **No silent stop**: when `install_devnet` ends without a working `starknet-devnet`, it prints an error naming the
   command that failed and its output, then exits non-zero. Do the same for any other `--version` check in `up` that
   `set -e` could end silently. `play.sh up` shows that message.
4. **Regression test** `scripts/play/test_devnet_shim.sh`:
   - the stub of step 1, then `install_devnet` succeeds on the first run;
   - a second case where the download fails prints the error and exits non-zero;
   - no network: replace the download with a local stub binary through a variable or function the test can
     override. If `devnet.sh` needs a small seam for that, it is allowed, and the default behaviour is unchanged;
   - it runs in seconds and leaves nothing behind.
5. Run `scripts/play.sh up`, then `down`, once on the VPS, to show that the normal path still works (through the
   heavy-build lock if it builds).

## 5. Machine

The VPS. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `fix/l4-devnet-shim`, then `gh pr create`, then `gh pr checks --watch` in the foreground until green
  (`play-local` included).
- Never merge; launch no agent and no review.
- `REPORT.md`:
  - the reproduction (commands and output);
  - the cause confirmed or corrected;
  - the fix and why;
  - the test and its output;
  - the CI wiring it needs.

Work autonomously, do not ask questions, do not widen the scope.
