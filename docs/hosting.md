# Hosting the attestation service

For the owner: how `services/attest` (the provisional tier, `docs/contract-v2.md` "Attestations") runs as a
permanent service on the VPS. Lot HS (`docs/briefs/hs-hosting-services.md`). Every step here is root's, and
the owner's: no agent runs them.

## Why it is laid out this way

Every agent runs as the same Unix user, which can write its whole home (checkouts, the asdf toolchain). So the
attestation key must be out of that user's reach, both for reading and for running code as its owner:

- the key is a file owned by a dedicated system user, mode 0600, under `/etc/slingfall`;
- that user runs only root-owned, read-only code: `/usr/bin/python3`, the release under `/opt/slingfall`
  (the service, the modules it imports, the prebuilt replay) and scarb under `/opt/slingfall/scarb`;
- it writes only its state directory `/var/lib/slingfall-attest` (`ReadWritePaths`); `ProtectHome=true`:
  nothing under `/home` is used.

| path | owner | mode | holds |
| --- | --- | --- | --- |
| `/etc/slingfall/attest.key` | `<user>` | 0600 | the attestation key (hex), written by the owner only |
| `/etc/slingfall/attest.env` | `root:<user>` | 0640 | contract address, RPC URL, the key file's path |
| `/etc/systemd/system/slingfall-attest.service` | root | 0644 | the unit |
| `/opt/slingfall/releases/<sha>/` | root | read-only | one installed revision: code, prebuilt replay, offline scarb cache, `REVISION` |
| `/opt/slingfall/current` | root | link | the running release |
| `/opt/slingfall/scarb/scarb-v2.19.4-x86_64-unknown-linux-gnu/` | root | read-only | scarb, the official tarball |
| `/var/lib/slingfall-attest/` | `<user>` | 0700 | scratch: `HOME`, the replay's working copy, scarb's cache and config |

`<user>` is a name the owner chooses; `slingfall-attest` by default (`install.sh --user` otherwise).

## Create (once, as root)

```sh
useradd --system --no-create-home --home-dir /var/lib/slingfall-attest --shell /usr/sbin/nologin slingfall-attest
install -d -o root -g root -m 0755 /etc/slingfall
# The key: a Stark-curve scalar in hex, on one line. Written without echoing it to a terminal or a history.
install -o slingfall-attest -g slingfall-attest -m 0600 /dev/null /etc/slingfall/attest.key
$EDITOR /etc/slingfall/attest.key
```

`install.sh` creates `/opt/slingfall`, the state directory comes from the unit (`StateDirectory=`), and the
environment file from the template.

## Install a revision (as root)

The agents' clone is agent-writable, its git objects included: never read or run anything from it. Fetch the
revision by its hash from GitHub into a root-owned directory, read `install.sh` there, and run it from there:

```sh
SHA=<the merged commit, 40 hex>
install -d -o root -g root -m 0755 /root/src
git clone https://github.com/bal7hazar/slingfall.git /root/src/slingfall-$SHA
git -C /root/src/slingfall-$SHA checkout --detach $SHA
less /root/src/slingfall-$SHA/deploy/hosting/install.sh
/root/src/slingfall-$SHA/deploy/hosting/install.sh             # prints its plan, asks before acting
$EDITOR /etc/slingfall/attest.env                               # first time: ATTEST_CONTRACT, STARKNET_RPC_URL
systemctl restart slingfall-attest
curl -s http://127.0.0.1:8547/health                            # "revision" is $SHA
```

`install.sh` refuses a checkout that is not root-owned, is group- or other-writable, has local changes or lives
under `/home`. It never reads the key (it checks the file's owner and mode with `stat`), never starts or restarts
the service, and is idempotent: a release already installed is kept, `current` is re-pointed. A rollback is
`install.sh` from the older checkout, or re-pointing `/opt/slingfall/current` at an older release, then a restart.

### Who builds the replay

The service re-executes each request's replay with `scarb execute --no-build`: no compile at runtime. The
replay (`crates/slingfall_replay/target/dev/*.executable.json`) is prebuilt by `install.sh` as the unprivileged
user `nobody`, in a scratch copy under `/var/tmp` with its own `HOME` and scarb cache, never as root and never as
the service user (the build downloads registry packages and compiles them; neither root nor the key's owner
runs that). The script copies the five `*.executable.json` and that build's scarb cache into the release, makes
the release root-owned and read-only, then runs it as the service will (`prepare.sh`, then the replay offline),
still as `nobody`, and refuses to install unless the pile10 reference shot gives its committed golden outputs.
A process running as `nobody` during those minutes could alter the scratch copy; nothing on this VPS is known
to run as `nobody`, and agents cannot become it.

scarb is the official release tarball of the version `.tool-versions` pins (2.19.4), checked against the
release's sha256 (pinned in `install.sh`), extracted by root into `/opt/slingfall/scarb`. The unit's
environment names everything `scarb execute --no-build` reads, nothing under `/home`: `PATH` (scarb's `bin`
first, then `/usr/bin:/bin`), `HOME`, `SCARB_CACHE` and `SCARB_CONFIG` (both in the state directory),
`SCARB_OFFLINE=true`.

scarb opens the replay's `Scarb.lock` for writing on every run, even `scarb execute --no-build` (measured: it
fails with `failed to open lockfile: Permission denied` in a read-only tree), and its cache takes a
`.package-cache.lock`. So at every start the unit's `ExecStartPre` (`deploy/hosting/prepare.sh`, as the service
user) copies from the release into the state directory the replay's workspace (`Scarb.toml`, `Scarb.lock`,
`crates/` with the prebuilt executables, about 25 MB) and the offline cache the release was built with (38 MB), and
`attest.py --replay-dir` runs scarb there. Nothing is compiled: `target/` holds only the prebuilt
`*.executable.json`, and `scarb execute --output none` writes no execution output. The Python code still runs
from the release. The copy takes 0.2 s.

### What to re-install after a merge

Re-run `install.sh` from the new revision after any merge that touches what the release holds:
`services/attest`, `tools/golden`, `tools/tracec`, `tools/levelc`, `tools/atlantic`,
`crates/slingfall_contract/tools`, the crates the replay builds (`slingfall_replay`, `slingfall_game`,
`slingfall_level`, `slingfall_rules`), `Scarb.toml`, `Scarb.lock`, `fixtures/levels`, `.tool-versions`
(a scarb bump also needs `install.sh`'s pinned version and sha256) or `deploy/hosting`. Nothing else
needs it. A change of the replay's crates is a new engine release: the service must not run it before the
contract pins it (`pin_program`), since it signs whatever outputs its replay gives under the contract's
`current_program()`.

## Run

```sh
systemctl start slingfall-attest       # stop, restart, status likewise
systemctl enable slingfall-attest      # install.sh does it: starts again at boot
journalctl -u slingfall-attest -f      # the log
journalctl -u slingfall-attest --since today | grep ' 429 '
```

Every request logs one line: time (UTC), method, path, status, duration, client (`local` for a caller on the
machine itself) and player; an attestation adds its mode, epoch and message hash, a refusal its reason. Never a
key, a signature input or a body. The unit restarts the service 5 s after any exit, at most 5 times in 300 s.

`GET /health` answers `{"service", "revision", "uptime", "public_key", "mode", "verify", "contract",
"chain_id", "program_hash", "epoch"}`: the installed sha, seconds since the start, and the chain values as last
read for a request (no chain call of its own).

## Port and limits

The service listens on `127.0.0.1:8547` (the same port as `scripts/play.sh`); only the reverse proxy reaches it
from outside. The limits are in memory (one process: a restart resets them) and answer 429 with `Retry-After`.

| flag | unit | default | why |
| --- | --- | --- | --- |
| `--rate` / `--rate-window` | 20 / 3600 s | 20 / 3600 s | per player; the player is chosen by the caller, so this alone does not stop a flood |
| `--client-rate` / `--client-window` | 120 / 3600 s | 120 / 3600 s | per client address: a few players behind one NAT, each under `--rate` |
| `--max-concurrent` | 1 | 1 | replays at once: one pile10 replay holds 1.9 GB and a CPU for 14 s |
| `--max-queue` | 4 | 4 | replays waiting beyond the running one; the next is refused at once rather than queued for minutes |

The client is the last entry of `X-Forwarded-For` when the peer is 127.0.0.1 (the proxy; Caddy sets the header
to the address it saw), else the peer address; the header is ignored from any other peer. A caller on the
machine itself without that header (an agent, a health check) is outside the per-client limit, though not
the per-player limit or the queue. Idle keys are pruned after a window, and at most 100,000 are kept.

`--rate 0` turns every limit off (per player, per client and the queue's): that is local play's flag
(`scripts/play.sh`), never the hosted service's. Replays then still run `--max-concurrent` at a time.

## Resources

One `POST /attest` with `--execute` on the pile10 reference shot, measured on the VPS (2026-10-02, scarb 2.19.4,
`RAYON_NUM_THREADS=1`, a throwaway key, the release laid out as above and made read-only, under the heavy-build
lock), `/usr/bin/time -v` of the service process and its scarb child:

```
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:14.57      (the request: 14.05 s)
User time (seconds): 5.68
System time (seconds): 8.00
Percent of CPU this job got: 93%
Maximum resident set size (kbytes): 1890224
```

So `MemoryMax=3G` (one replay at 1.9 GB plus the Python process, with headroom; raise it with
`--max-concurrent`, about 2 GB per extra replay) and `TasksMax=64` (the HTTP threads and scarb's). The heaviest
reference shots (tower, bridge) were not measured. The service does not take the agents' heavy-build lock: a
replay can coincide with an agent's build, within the VPS's 31 GB.

## Rotating the key

1. Write the new key: `install -o slingfall-attest -g slingfall-attest -m 0600 /dev/null /etc/slingfall/attest.key.new`,
   edit it, then `mv /etc/slingfall/attest.key.new /etc/slingfall/attest.key`.
2. `systemctl restart slingfall-attest`; `curl -s http://127.0.0.1:8547/health` shows the new `public_key`.
3. The same public key through the file:
   `runuser -u slingfall-attest -- env SLINGFALL_ATTEST_KEY_FILE=/etc/slingfall/attest.key /usr/bin/python3 /opt/slingfall/current/services/attest/attest.py pubkey`.
4. The owner's `set_attestation_key(<public key>)` transaction (it bumps `attestation_epoch()`).
5. `systemctl restart slingfall-attest` again, or wait 30 s (the service reads the epoch again after 30 s).

From the first restart until step 5, attestations are rejected by the contract: first because the contract
still holds the old key, then because they carry the old epoch. Attestations signed before the rotation are
void once the epoch bumps. Plan the rotation for a quiet moment; it takes a minute.

## Caddy, later (an example, not a change)

When the owner creates the subdomain:

```caddy
attest.<domain> {
    request_body {
        max_size 1MB
    }
    reverse_proxy 127.0.0.1:8547
}
```

Caddy replaces any `X-Forwarded-For` from an untrusted client with the address it saw, which is what the
per-client limit reads. The web client then points `VITE_ATTEST_URL` at `https://attest.<domain>`.
