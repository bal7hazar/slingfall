# HS2 — the attestation service: the owner session's six remarks and the audit's hardening notes

Profile `impl-opus` (root's install path and a service holding a key). Lot id `hs2-attest-remarks`, branch
`fix/hs2-attest-remarks`.

## 1. Goal and context

The owner is installing the attestation service at revision 3efb4ef (HS, #71). Before that, the owner's session had
another model review what runs as root and with the key. Its verdict was "safe, with remarks", none blocking. The
remarks are in `/home/claude/.herdr-projects/organisation/scratch/attest-remarks.md` (read-only).

That session verified on the VPS: `fs.protected_symlinks=1`, `fs.protected_regular=2`, no process of `nobody`, git
2.43, the agents' user not in the `caddy` group, and the sha256 of scarb in `install.sh` equal to v2.20.1's published
list.

This lot fixes the six remarks. It also folds in the six notes the security audit of #71 kept for hardening (report
`/home/claude/.herdr-projects/slingfall-game/threads/t-0062.md`, read-only), since they touch the same files.

The owner applies some of these meanwhile by hand: `TMPDIR=/root/tmp` for the install, and a systemd drop-in with the
first three unit settings. So the repository's versions must match what the owner does, and stay compatible with that
drop-in.

## 2. Transactions

None. Nothing is installed, nothing runs as root, and no real key is read. Tests use throwaway keys and temporary
files.

## 3. Scope (allowlist)

- `deploy/hosting/install.sh`, `deploy/hosting/slingfall-attest.service`, `deploy/hosting/prepare.sh` (only if a fix
  needs it).
- `services/attest/attest.py`, `services/attest/test_attest.py`.
- `docs/hosting.md`.
- `deploy/hosting/test_install.sh` (new): tests of `install.sh`'s functions without running the install. It sources
  the code between the `# --- archive checks: begin/end` and `# --- replay manifest: begin/end` markers into a
  temporary tree, with git run in a sanitised environment (`env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE
  -u GIT_COMMON_DIR -u GIT_PREFIX`, never on the real repository). It covers remark 1 (no file outside the private
  directory), remark 5 (git < 2.40 refused, check-attr failure fails closed), N15 (a multi-line string hiding a table),
  N16, N18 and N19 (an ELF file under `crates/`). Network-free; it leaves nothing behind. If the permission system
  refuses `git init` in the temporary tree, say so, and test what you can.
- `REPORT.md` (not committed).

## 4. Work

The owner's session's remarks (attest-remarks.md):
1. **install.sh, the `.sorted` files** (around l. 122): root writes files with predictable names in the shared `/tmp`.
   Use one private directory from `mktemp -d` under `/opt/slingfall/.build` for every temporary file of the install,
   removed at exit, and `export TMPDIR` to it, so that `sort -z` spills and here-strings use it too. This is also
   audit note "one mktemp -d".
2. **The service unit:** add `LimitCORE=0`, `ProtectProc=invisible` and `Environment=PYTHONNOUSERSITE=1`. Not
   `python3 -I`: it implies `-E`, which would drop the unit's `PYTHONDONTWRITEBYTECODE=1`.
   **Study** a limit on outgoing connections, since the service talks only to the RPC: `IPAddressDeny=any` plus an
   `IPAddressAllow=` for the RPC, or an equivalent. A hostname RPC cannot be allowed by name in systemd. Say what
   works, what it costs the owner (an address to maintain), and either add it as a commented, documented option or
   explain why not.
3. **attest.py, the RPC failure** (the `raise AttestError(503, f"chain: cannot read {name}: {e}")`, around l. 306): the
   error text reaches the caller and may carry the whole RPC URL, hence a provider key. Answer a fixed message
   (`chain: cannot read <name>`). The log line keeps only the exception's type and the RPC's host. Drop the URL's
   path, query and credentials: providers carry the key in the path (`/v2/<key>`). Add a test where the exception
   text holds `https://rpc.example/v2/SECRETKEY?k=SECRET`: neither the answer nor the log line contains `SECRET`.
4. **attest.py, two malformed bodies** (around l. 607 and 789): `{"inputs": {...}}` (an object where a list is
   expected) and deeply nested JSON raise an uncaught exception. Answer 400 for both, with a test each. Bound the
   nesting depth, or catch `RecursionError`.
5. **install.sh, git older than 2.40:** `check_attributes` (around l. 100) relies on `git check-attr --source`. Refuse
   explicitly when git is older than 2.40. Make the function fail closed: check the process substitution's status, or
   use a temporary file and test both commands' exit codes. This is also audit note N17.
6. **docs/hosting.md, Caddy:** the `read_header` / `read_body` timeouts sit in the global options and so apply to every
   site of the VPS, the web terminal included.
   - Scope them to this site if Caddy allows it; say so with the Caddy directive.
   - Otherwise say plainly what they do to the other sites, and that the service's own 20 s deadline (`DeadlineReader`)
     already bounds each request, so they are optional.
   - The owner does not set them for now: write the note to match that.

The audit's hardening notes (t-0062):
- **N15:** strip the crates' manifests with a TOML-aware method (Python's `tomllib` reads; write back only the kept
  tables, or refuse a manifest whose test-only parts are not plain tables), not line by line. A multi-line string must
  not hide a table.
- **N16:** build with `--locked` against the committed `Scarb.lock`, and refuse if the settled lock differs from the
  committed one. If `--locked` cannot work because the strip removes dev-dependencies from the lock, say so, and
  instead compare the settled lock's non-dev packages with the committed ones.
- **N18:** make the snforge guard SIGPIPE-safe: `grep -q` on a file, not on a pipe under `pipefail`.
- **N19:** extend the ELF and `.so` refusal to the archived `crates/` tree that `prepare.sh` copies.
- **N20:** reset the socket timeout to the idle value after reading the request, before writing the response.

## 5. Machine

The VPS. If the work builds the replay to test the install path, do it under
`flock -w <s> ~/orchestrator/heavy-build.lock env HEAVY_BUILD_LOCK_HELD=1 …`, wrapped in `/usr/bin/time -v`, and report
its peak RSS, wall time and `free -m` at the start. `install.sh` itself is never run (it is root's).

## 6. Definition of done

- Conventional commits with your model's trailer. Run `scripts/prepush.sh` before pushing.
- Push `fix/hs2-attest-remarks` once, then `gh pr create`. At most one `gh` call every 5 minutes.
- Never merge; launch no agent and no review.
- `REPORT.md`: each remark and note, what changed, its test or its check; the outgoing-connection study; anything
  not done, and why.

Work autonomously, do not ask questions, do not widen the scope.
