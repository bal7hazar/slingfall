# HS — the attestation service, ready to host on the VPS

Profile `impl-opus` (access control: binding, rate limits, a secret that agents must not reach). Lot id
`hs-hosting-services`, branch `feat/hs-hosting-services`.

## 1. Goal and context

**Goal.** Deliver everything the owner needs to install `services/attest` (the provisional tier) as a permanent
service on the current VPS: files and a short operations note, **not** an installed service.

**Owner's decisions (2026-10-02, relayed by the project manager).**
- The service is hosted on the current VPS, not on a dedicated machine.
- The web clients get subdomains later; the owner creates them.
- **No Atlantic for the MVP.** The MVP's settled tier is contract v3's proven tier through SNIP-36, which waits for
  PROOF2 on Sepolia (E2). So `services/prove` is **not** prepared here, no Atlantic key is needed, and the relay of
  the settled tier waits for the SNIP-36 form.
- On Sepolia the relayer stays the admin account.

**What stays the owner's**, and what no agent does or works around: the subdomain, the Caddy site (root), the
creation of the dedicated system user, putting the key in place, and the installation itself (root: `systemctl`,
`/etc/**`, `/opt/**`, `useradd`). This lot never asks for the key, never reads it and never prints it. It never runs
`sudo` and never runs `install.sh`.

**The threat this lot must close.** Every agent runs as the same Unix user as everything else on the VPS, and can
write that user's home, including every checkout and the asdf toolchain. The attestation key must therefore be
unreachable from that user, in two ways:
- **Reading the key:** it lives in a file owned by a system user dedicated to the service, mode 0600, outside any
  agent-writable tree.
- **Running code as the key's owner:** the service user runs only code and tools that agents cannot write. Code,
  replay artefacts and the toolchain `--execute` uses are installed by the owner into a **root-owned, non-writable
  tree** (for example `/opt/slingfall`). The service user can write only a scratch directory listed in
  `ReadWritePaths`. Nothing the unit runs may resolve to a path under `/home`.

Read first:
- `AGENTS.md`;
- `services/attest/attest.py` (docstring, `serve` flags, `RateLimiter`, `player_of`, `parse_key`, `/health`,
  `log_message`, `--execute` and `scarb_replay`) and `test_attest.py`;
- `tools/golden/golden.py` (what `--execute` runs);
- `scripts/play.sh` (how the service starts today: `PLAY_ATTEST_PORT`, `--rate 0`);
- `docs/contract-v2.md` ("Attestations": what is signed, `set_attestation_key`, the epoch).

## 2. Transactions

None. No command of this lot sends anything to Sepolia. Tests and the measurement use fakes and a throwaway key
generated for the purpose, never the real one.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `deploy/hosting/**` (new):
  - the systemd unit `slingfall-attest.service`;
  - an environment file template with placeholders only (`attest.env.example`);
  - `install.sh`, which the owner reads and runs as root. You never run it. It must be idempotent, print what it
    will do before doing it, and never read or print the key file. **Where it comes from:** the agents' clone is
    agent-writable, objects included, so the owner never reads or runs anything from it. `docs/hosting.md` tells the
    owner to fetch the revision, as root, by a hash-verified fetch from the GitHub remote into a root-owned directory
    (a fresh `git clone` then `git checkout <sha>`, or `git fetch origin <sha>`), to read `install.sh` there, and to
    run it from there. `install.sh` installs from that directory only, and writes a `REVISION` file with the sha.
- `services/attest/attest.py` and `services/attest/test_attest.py`, only for the deltas of §4; `tools/golden/golden.py`
  only as §4.5 allows.
- `docs/hosting.md` (new): the operations note.
- `REPORT.md` at the worktree root.
- Not `services/prove/**`, not `scripts/play.sh` (local play must keep working unchanged), not `.github/**`.

## 4. Work: deltas against what `attest.py` already has

What already exists on main, to keep:
- `--host` (default `127.0.0.1`) and `--port` (default 8547, the same as `play.sh`'s `PLAY_ATTEST_PORT`);
- `GET /health`;
- request logging;
- a per-player `RateLimiter` (`--rate` 20 per `--rate-window` 3600 s), answering 429.
`play.sh` passes `--rate 0`: that must keep meaning "no limit". The unit passes flags in `ExecStart`; add environment
variables only where a flag cannot do it.

1. **`/health`**: answers 200 with a small JSON: service name, git sha of the installed code (read from the
   `REVISION` file `install.sh` writes; the installed tree has no `.git`), uptime, and the
   contract address and epoch it last read. It makes no chain call of its own and reads no secret.
2. **Logging**: one line per request to stdout (journald keeps it): time, method, path, status, duration, and the
   player if any. Never a key, a signature's private input or a full body.
3. **Rate limits.** The player key is chosen by the caller (`player_of`), so a per-player limit alone does not stop
   a flood of `--execute` replays.
   - Keep the per-player limit.
   - Add a per-client limit keyed on `X-Forwarded-For` as Caddy sets it (its last entry), trusted only when the
     peer is `127.0.0.1`. Local callers are outside this limit; say so in the note.
   - Add a global cap on concurrent and queued replays.
   - `play.sh` may not change and passes only `--rate 0`: `--rate 0` turns off **every** limit (per player, per client
     and global), or the new limits default to values local play cannot reach. Choose and say which. A test runs the
     `play.sh` flag set and shows that many requests from one peer are all served.
   - Prune idle keys, so memory stays bounded.
   - Answer 429 with `Retry-After`.
   - In memory is enough (one process); say so.
   - Unit tests: each limit, the reset, two players isolated, pruning, and the forwarded-for trust rule.
4. **The key from a file**: `parse_key` (used by `serve`, `sign` and `pubkey`) also reads `SLINGFALL_ATTEST_KEY_FILE`.
   `--key` and `SLINGFALL_ATTEST_KEY` stay, for `play.sh` and CI. The env template uses only the `_FILE` form.
   Tests use temporary files holding throwaway keys.
5. **`--execute` without agent-writable code**: decide and document how the installed service re-executes the
   replay from the root-owned tree:
   - Preferred: prebuilt replay artefacts plus a `scarb` installed outside `/home` (say how: version, path, by
     whom), with no compile at runtime.
   - If a runtime compile cannot be avoided, its target directory is the service's scratch directory.
   - The unit's environment names everything `scarb execute --no-build` needs, with nothing under `/home`: `PATH`
     (the scarb directory), `HOME`, `SCARB_CACHE` and any scarb config directory, in the scratch directory or as an
     offline, pre-filled cache in the root-owned tree. Say whether scarb writes `target/`, a lock or `Scarb.lock` next
     to the manifest, and where that goes.
   - **Prove the read-only run before the owner installs:** copy the tree to a temporary directory, `chmod -R a-w`
     it, run `attest.py serve --execute --no-build` with `HOME` and `SCARB_CACHE` in a separate scratch directory and a
     throwaway key, and post one pile10 request. Report the commands and the output.
   - If `tools/golden/golden.py` must change for this (for example to point at prebuilt artefacts), it is allowed, only
     for that.
   - Whatever you choose, say what the owner must re-install after a merge touching `services/attest`,
     `tools/golden` or the crates the replay builds.
6. **systemd unit**:
   - `User=` the dedicated user (a placeholder name the owner chooses, documented);
   - `ExecStart=` with `serve --execute --no-build` and the bind, port and limit flags; never `--no-verify` or
     `--verify-cmd`;
   - `Restart=always`, `RestartSec=`, a start limit, and `WantedBy=multi-user.target` (restart on reboot);
   - `MemoryMax=` and `TasksMax=`, sized from the measurement of §4.7;
   - `EnvironmentFile=` the env file;
   - `WorkingDirectory=` inside the root-owned tree;
   - hardening that matches §1: `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=true` (nothing under
     `/home` is needed), `PrivateTmp`, `ReadWritePaths=` the scratch directory only.
   - Check it with `systemd-analyze verify` if that runs without root; otherwise say it was not checked.
7. **`docs/hosting.md`** for the owner, short:
   - what to create as root: the user, the root-owned tree, the scratch directory and the key file, with their
     owners and modes;
   - how to install, start, stop and restart, and how to read the logs (`journalctl -u ...`);
   - what to re-install after which merges;
   - how to rotate the key: write the new file, restart, check `/health` and
     `attest.py pubkey` (through `_FILE`), then the owner's `set_attestation_key` transaction, then restart again (or
     wait the epoch cache's TTL). Attestations from the first restart to the second are rejected: say so;
   - example Caddy lines for the subdomain later (an example, not a change);
   - the port, every rate-limit flag with its default and why;
   - the memory and CPU of one `/attest --execute` request on the pile10 reference shot, measured on the VPS with a
     throwaway key (real `/usr/bin/time -v` output; builds through the heavy-build lock).

## 5. Machine

The VPS. Builds go through the shims and the heavy-build lock, never bypassed. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `feat/hs-hosting-services`, then `gh pr create`, then `gh pr checks --watch` in the foreground until green.
- Never merge; launch no agent and no review.
- `REPORT.md`:
  - what the service now does on each point of §4, and the defaults chosen and why;
  - the tests added;
  - the `--execute` installation choice;
  - what was not checked;
  - anything the owner must decide.

Work autonomously, do not ask questions, do not widen the scope.
