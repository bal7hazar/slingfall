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
  nothing under `/home` is used;
- its port is held by systemd from boot (`slingfall-attest.socket`), so no other process can take it while the
  service is down.

| path | owner | mode | holds |
| --- | --- | --- | --- |
| `/etc/slingfall/attest.key` | `<user>` | 0600 | the attestation key (hex), written by the owner only |
| `/etc/slingfall/attest.env` | `root:<user>` | 0640 | contract address, RPC URL, CORS origin, the key file's path |
| `/etc/systemd/system/slingfall-attest.{socket,service}` | root | 0644 | the units |
| `/opt/slingfall/releases/<sha>/` | root | read-only | one installed revision: code, prebuilt replay, offline scarb cache, `REVISION` |
| `/opt/slingfall/current` | root | link | the running release |
| `/opt/slingfall/scarb/scarb-v2.19.4-x86_64-unknown-linux-gnu/` | root | read-only | scarb, the official tarball |
| `/opt/slingfall/.build/` | root | 0755 | `install.sh`'s scratch builds (one directory per run, removed after it) |
| `/var/lib/slingfall-attest/` | `<user>` | 0700 | scratch: `HOME`, the replay's working copy, scarb's cache and config |

`<user>` is a name the owner chooses; `slingfall-attest` by default (`install.sh --user` otherwise).

## Trust: what to review before an install

**A merged commit is not trusted because it is merged.** The agents' Unix user holds GitHub credentials that
can merge to `main` (the threads merge their own pull requests). Whatever a commit puts in the release runs as
the service user, which reads the key, and `install.sh` and its check run as root. Anything on that user's side
(an agent, or a compromised dependency an agent ran) could land such a commit. So before each install the owner
reviews, in the root-owned checkout, everything the release runs or installs that changed since the running
revision:

```sh
cd /root/src/slingfall-$SHA
git diff "$(cat /opt/slingfall/current/REVISION)" "$SHA" -- \
    services/attest/attest.py crates/slingfall_contract/tools/vectors.py tools/levelc/poseidon.py \
    tools/atlantic/encoding.py tools/golden/golden.py tools/tracec/tracec.py \
    deploy/hosting/install.sh deploy/hosting/prepare.sh \
    deploy/hosting/slingfall-attest.service deploy/hosting/slingfall-attest.socket
git diff --stat "$(cat /opt/slingfall/current/REVISION)" "$SHA" -- \
    services tools crates fixtures Scarb.toml Scarb.lock .tool-versions deploy/hosting
```

The first command is the code that runs with the key or as root (`attest.py` and the modules it imports, the
golden check `install.sh` runs, the start script, the units, the installer itself). The second lists every other
change in the release: the Cairo replay and its fixtures, which decide what gets signed, run inside the Cairo VM.
On the first install there is no previous revision: the owner reads all of the first list.

Better still, install only a commit that carries a tag signed with a key the agents do not hold (an OpenPGP key
kept on the owner's own machine, never on the VPS): the owner reviews, tags and signs on their machine
(`git tag -s attest-<date> <sha>`, then `git push origin attest-<date>`), imports the public key into root's
keyring on the VPS once (`gpg --import`), and installs with `--signed-tag`, which refuses unless the tag points at
the checked-out commit and `git verify-tag` finds a good signature by that fingerprint:

```sh
git -C /root/src/slingfall-$SHA verify-tag attest-<date>                    # by hand: "Good signature from ..."
/root/src/slingfall-$SHA/deploy/hosting/install.sh --signed-tag attest-<date> --signer <40-hex fingerprint>
```

The agents cannot forge that signature, but the review is still the owner's: a signature says only that the
owner vouched for the commit.

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
revision by its hash from GitHub into a root-owned directory (a plain clone: no `--reference` or `--shared`),
review it ("Trust" above), and run `install.sh` from there:

```sh
SHA=<the reviewed commit, 40 hex>
install -d -o root -g root -m 0755 /root/src
git clone https://github.com/bal7hazar/slingfall.git /root/src/slingfall-$SHA
git -C /root/src/slingfall-$SHA checkout --detach $SHA
# review: "Trust" above
/root/src/slingfall-$SHA/deploy/hosting/install.sh [--signed-tag T --signer F]   # prints its plan, asks first
$EDITOR /etc/slingfall/attest.env               # first time: ATTEST_CONTRACT, STARKNET_RPC_URL, ATTEST_CORS_ORIGIN
systemctl start slingfall-attest.socket && systemctl restart slingfall-attest
curl -s http://127.0.0.1:8557/health            # "revision" is $SHA
systemctl show -p MainPID slingfall-attest      # the service's pid ...
ss -ltnp 'sport = :8557'                        # ... and the process holding 8557: systemd (pid 1) and that pid
```

Check the last three together: `/health` alone is answered by whatever holds the port. The socket belongs to
systemd from boot, so `ss` lists `systemd` and the service's `python3` (the pid of `MainPID`), nothing else.

`install.sh` refuses a checkout that is not root-owned, is group- or other-writable, has local changes, lives
under `/home`, or reads its git objects from outside itself (a gitfile, a shared or alternate object store). It
validates `--user`, never reads the key (it checks the file's owner and mode with `stat`), never starts or
restarts the service, and is idempotent: a release already installed is kept, `current` is re-pointed. A
rollback is `install.sh` from the older checkout, or re-pointing `/opt/slingfall/current` at an older release,
then a restart.

### Who builds the replay

The service re-executes each request's replay with `scarb execute --no-build`: no compile at runtime. The
replay (`crates/slingfall_replay/target/dev/*.executable.json`) is prebuilt by `install.sh` as the unprivileged
user `nobody`, never as root and never as the service user (the build downloads registry packages and compiles
them; neither root nor the key's owner runs that). The build runs in a transient systemd unit (`systemd-run
--uid=nobody --pipe --wait --collect`): no terminal, a private `/tmp`, no `/home`, `/etc/slingfall`
inaccessible, no new privileges, and every process it started killed when it ends. Its scratch directory
(`HOME`, scarb cache, sources) is under the root-owned `/opt/slingfall/.build`, not a world-writable `/var/tmp`.

Root then takes only regular files from what `nobody` wrote, copied without following links: if the build
left a symbolic link, a device or a socket among the executables or in the scarb cache, the install is refused.
The script copies the five `*.executable.json` and that build's scarb cache into the release, makes the release
root-owned and read-only, then runs it as the service will (`prepare.sh`, then the replay offline), again as
`nobody` in a confined unit, and refuses to install unless the pile10 reference shot gives its committed golden
outputs. Nothing on this VPS is known to run as `nobody`, and agents cannot become it.

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

Re-run `install.sh` from the new revision (reviewed, "Trust" above) after any merge that touches what the release
holds: `services/attest`, `tools/golden`, `tools/tracec`, `tools/levelc`, `tools/atlantic`,
`crates/slingfall_contract/tools`, the crates the replay builds (`slingfall_replay`, `slingfall_game`,
`slingfall_level`, `slingfall_rules`), `Scarb.toml`, `Scarb.lock`, `fixtures/levels`, `.tool-versions`
(a scarb bump also needs `install.sh`'s pinned version and sha256) or `deploy/hosting`. Nothing else
needs it. A change of the replay's crates is a new engine release: the service must not run it before the
contract pins it (`pin_program`), since it signs whatever outputs its replay gives under the contract's
`current_program()`.

## Run

```sh
systemctl start slingfall-attest       # stop, restart, status likewise (the socket stays up)
systemctl enable slingfall-attest      # install.sh does it, and enables the socket: both start at boot
journalctl -u slingfall-attest -f      # the log
journalctl -u slingfall-attest --since today | grep ' 429 '
```

Every request logs one line: time (UTC), method, path, status, duration, client (`local` for a caller on the
machine itself) and player; an attestation adds its mode, epoch and message hash, a refusal its reason. Never a
key, a signature input or a body. The unit restarts the service 5 s after any exit, at most 5 times in 300 s
(then `systemctl reset-failed slingfall-attest`). A replay killed for memory fails that request (500), not
the unit (`OOMPolicy=continue`).

`GET /health` answers `{"service", "revision", "uptime", "public_key", "mode", "verify", "contract",
"chain_id", "program_hash", "epoch"}`: the installed sha, seconds since the start, and the chain values as last
read for a request (no chain call of its own).

## Port and limits

systemd listens on `127.0.0.1:8557` (`slingfall-attest.socket`; not `scripts/play.sh`'s 8547) from boot and
hands the socket to the service (`--systemd-socket`); only the reverse proxy reaches it from outside. A TCP port
on loopback rather than a Unix socket only Caddy's group can reach: local callers can reach it, and are capped
together (`--local-rate`). A request body above 16 KiB answers 413 (an `--execute` request is under 1 KiB).
Browsers may call only from `ATTEST_CORS_ORIGIN` (the env file: the web client's origin, `https://<subdomain>`).

The limits are in memory (one process: a restart resets them) and answer 429 with `Retry-After`. They are charged
in this order, so a refused request costs nothing further:

| order | flag | default | why |
| --- | --- | --- | --- |
| 1 | `--client-rate` / `--client-window` | 20 / 3600 s | per client address (an IPv6 client is its /64), sized against the one replay slot below |
| 1 | `--local-rate` | 60 / 3600 s | every local caller together (127.0.0.1 without the header, or with a header that is not an IP address) |
| 2 | (the request is parsed) | | a malformed request (400) charges nothing further |
| 3 | `--max-concurrent` | 1 | replays at once: one replay holds 4.2 GB (tower) and a CPU for 14 to 23 s |
| 3 | `--max-queue` | 4 | replays waiting beyond the running one; the next is refused at once (busy) rather than queued for minutes |
| 4 | `--rate` / `--rate-window` | 20 / 3600 s | per player, charged only once the gate admits the request; the player is chosen by the caller |

The client is the last entry of `X-Forwarded-For` when the peer is 127.0.0.1 (the proxy; Caddy sets the header
to the address it saw), else the peer address; the header is ignored from any other peer, and a last entry that
is not an IP literal counts as local. Idle keys are pruned after a window, and at most 100,000 are kept.

**One service on one slot can be saturated.** A replay holds the only slot for 14 s (pile10) to 23 s
(tower), so the service attests at most about 250 pile10 replays an hour (about 150 tower ones). With the defaults, one address gets at
most 20 an hour (under a tenth of that), and local callers 60. About 13 addresses (13 IPv6 /64s, a handful of
cloud machines) attesting continuously keep the slot busy and the queue full, and every other player then gets
429 busy until they stop. The limits bound the cost of a flood (memory, CPU), not its reach; for the MVP on
Sepolia that is accepted, and the numbers can be tuned in the unit's `ExecStart`.

`--rate 0` turns every limit off (per player, per client, local and the queue's): that is local play's flag
(`scripts/play.sh`), never the hosted service's. Replays then still run `--max-concurrent` at a time.

## Resources

One `POST /attest` with `--execute`, measured on the VPS (2026-10-02, scarb 2.19.4, `RAYON_NUM_THREADS=1`, a
throwaway key, the release laid out as above and made read-only, under the heavy-build lock), `/usr/bin/time -v`
of the service process and its scarb child. pile10, the reference shot (8.7M Cairo steps):

```
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:14.57      (the request: 14.05 s)
User time (seconds): 5.68
System time (seconds): 8.00
Percent of CPU this job got: 93%
Maximum resident set size (kbytes): 1890224
```

tower, the reference shot, the largest of the golden cases (22.3M Cairo steps):

```
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:23.36      (the request: 22.89 s)
User time (seconds): 8.92
System time (seconds): 11.34
Percent of CPU this job got: 86%
Maximum resident set size (kbytes): 4170540
```

So `MemoryMax=6G` (the tower replay plus the Python process, with headroom; raise it with
`--max-concurrent`, by the same again per extra replay), `OOMPolicy=continue` (an OOM kill fails that replay,
not the unit) and `TasksMax=64` (the HTTP threads and scarb's). The service does not take the agents'
heavy-build lock: a replay can coincide with an agent's build, within the VPS's 31 GB.

## Rotating the key

1. Write the new key: `install -o slingfall-attest -g slingfall-attest -m 0600 /dev/null /etc/slingfall/attest.key.new`,
   edit it, then `mv /etc/slingfall/attest.key.new /etc/slingfall/attest.key`.
2. `systemctl restart slingfall-attest`; `curl -s http://127.0.0.1:8557/health` shows the new `public_key`.
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
{
    admin off
}

attest.<domain> {
    request_body {
        max_size 16KB
    }
    reverse_proxy 127.0.0.1:8557
}
```

Caddy replaces any `X-Forwarded-For` from an untrusted client with the address it saw, which is what the
per-client limit reads. **The per-client limit is only as trustworthy as Caddy's admin access.** By default
Caddy's admin API listens on `127.0.0.1:2019` without authentication (it does on this VPS today), so any local
user, the agents' included, can replace Caddy's configuration: set any `X-Forwarded-For`, lift the body cap, or
send the subdomain to another process. Hence `admin off` in the global options (reload by restarting Caddy), or
`admin unix//run/caddy/admin.sock` with that socket readable by root only. The web client then points
`VITE_ATTEST_URL` at `https://attest.<domain>`, and `ATTEST_CORS_ORIGIN` is that client's origin.
