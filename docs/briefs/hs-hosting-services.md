# HS — the attestation service, ready to host on the VPS

Profile `impl-opus` (access control: binding, rate limit, secrets). Lot id `hs-hosting-services`, branch
`feat/hs-hosting-services`.

## 1. Goal and context

**Goal.** Deliver everything the owner needs to install `services/attest` (the provisional tier) as a permanent
service on the current VPS: files and a short operations note, **not** an installed service.

**Owner's decisions (2026-10-02).** The service is hosted on the current VPS, not on a dedicated machine. The web
clients get subdomains later; the owner creates them. **No Atlantic for the MVP**: the MVP's settled tier is contract
v3's proven tier through SNIP-36, which waits for PROOF2 on Sepolia (E2). So `services/prove` in its Atlantic form is
**not** prepared here, no Atlantic key is needed, and the relay of the settled tier waits for the SNIP-36 form. On
Sepolia the relayer stays the admin account (OPERATIONS.md §7).

**What stays the owner's**, and what no agent does or works around: the subdomain, the Caddy site (root), the creation of
the dedicated system user, putting the secret in place, and the installation itself (root: `systemctl`, `/etc/**`,
`useradd`). This lot never asks for a secret, never reads one, never prints one, and never runs `sudo`.

**Why a dedicated user.** Every agent runs as the same Unix user as everything else on the VPS. The attestation key
must therefore be unreadable by that user: it lives in a file owned by a system user dedicated to the service, mode
0600, outside the repository and outside the agents' home. The service runs as that user.

Read first: `AGENTS.md`, `services/attest/attest.py` and `test_attest.py`, `docs/play-local.md` and `scripts/play.sh`
(how the service starts today), `deploy/sepolia.env.example` (the variables it reads), `docs/contract-v2.md`
("Attestations": what is signed), `OPERATIONS.md` §7.

## 2. Transactions

None. No command of this lot sends anything to Sepolia. Tests use fakes and temporary keys.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `deploy/hosting/**` (new): the systemd unit `slingfall-attest.service`, an environment file template with
  **placeholders only** (`attest.env.example`), and an install script `install.sh` meant to be **read and run by the
  owner as root**. Never run it.
- `services/attest/attest.py` and `services/attest/test_attest.py`, only for the points of §4: bind address and port
  from the environment, `/health`, logging, per-player rate limit, reading the key from a file path given in the
  environment.
- Not `services/prove/**`.
- `docs/hosting.md` (new): the operations note.

## 4. Work

1. **Bind and port.** The service listens on `127.0.0.1` by default, on a fixed port documented in `docs/hosting.md`
   (keep the port `scripts/play.sh` uses today if it is fixed; say which). A bind to anything else needs an explicit
   variable. Caddy, the owner's, proxies to it.
2. **`/health`**: `GET /health` answers `200` with a small JSON (service name, version or git sha, uptime, the contract
   address and epoch it last read). It does no chain call of its own and reads no secret.
3. **Logging**: one line per request (time, method, path, status, duration, player address if any) to stdout, so
   journald keeps it. Never log a secret, a signature's private input, or a full request body.
4. **Per-player rate limit**: on `POST /attest` (each request runs the replay), a limit per player address, plus a limit per client IP for requests without one, both from the environment, with defaults you
   justify in the note. Over the limit: `429` with `Retry-After`. In memory is enough (one process); say so.
   Unit tests: the limit, the reset, two players isolated.
5. **The key from a file**: the service reads the attestation key from a file named by
   `SLINGFALL_ATTEST_KEY_FILE`, as well as from `SLINGFALL_ATTEST_KEY` used today (kept for `play.sh` and CI). The env
   template uses only the `_FILE` form, pointing under the dedicated user's directory (for example `/etc/slingfall/` or
   `/var/lib/slingfall/`, mode 0600, owner the service user). Tests use temporary files with fake values.
6. **systemd unit**: `User=` the dedicated user (a placeholder name the owner chooses, documented), `Restart=always`,
   `WantedBy=multi-user.target` (restart on reboot), `EnvironmentFile=` the env file, the working directory a checkout
   or a copy that the note names (with what `--execute` needs to run the replay there), and hardening options that do not break the services (`NoNewPrivileges`,
   `ProtectSystem=strict` with the needed `ReadWritePaths`, `ProtectHome=true`,
   `PrivateTmp`). Check each with `systemd-analyze verify` if it runs without root; otherwise say it was not checked.
7. **`docs/hosting.md`** for the owner, short: what to create as root (user, directories, secret files with their
   modes), how to install (the commands of `install.sh`), start, stop, restart, read the logs (`journalctl -u ...`),
   rotate the attestation key (the contract's `set_attestation_key`, the owner's transaction; write the new file;
   restart; check `/health` and `attest.py pubkey`), and the Caddy lines to add for the subdomains
   later (an example, not a change). It names the port, the rate-limit variables and their defaults, and the
   memory and CPU of one `/attest` request measured on the VPS (real `/usr/bin/time -v` output of one request on the
   pile10 reference shot, through the heavy-build lock if it builds).

## 5. Machine

The VPS. Builds through the shims and the heavy-build lock, never bypassed. Foreground only.

## 6. Definition of done

Conventional commits with your model's trailer; run `scripts/prepush.sh` before pushing if it exists on main; push
`feat/hs-hosting-services`; `gh pr create`; `gh pr checks --watch` in the foreground until green; never merge; launch
no agent and no review. `REPORT.md`: what the service now does on each point of §4, the defaults chosen and why, the
tests added, what was not checked (for example `systemd-analyze` without root), and anything the owner must decide.
Work autonomously, do not ask questions, do not widen the scope.
