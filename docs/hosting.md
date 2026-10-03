# Hosting the attestation service

For the owner: how `services/attest` (the provisional tier, `docs/contract-v2.md` "Attestations") runs as a
permanent service on the VPS. Lot HS (`docs/briefs/hs-hosting-services.md`). Every step here is root's, and
the owner's: no agent runs them.

**Root's shell.** The owner logs in as root directly, over SSH from their own machine (`ssh root@<vps>`). Never
through `su` or `sudo` typed in the agents' account, nor in a terminal that account runs (herdr, tmux, the `ttyd`
web terminal): the agents can rewrite that account's shell start-up files, so a password typed there, or the
root shell it opens, would be theirs. This holds for every section below: "Create", "Install a revision",
"Rotating the key".

## Why it is laid out this way

Every agent runs as the same Unix user, which can write its whole home (checkouts, the asdf toolchain). So the
attestation key must be out of that user's reach, both for reading and for running code as its owner:

- the key is a file owned by a dedicated system user, mode 0600, under `/etc/slingfall`;
- that user runs only root-owned, read-only code: `/usr/bin/python3`, the release under `/opt/slingfall`
  (the service, the modules it imports, the prebuilt replay) and scarb under `/opt/slingfall/scarb`;
- it writes only its state directory `/var/lib/slingfall-attest` (`ReadWritePaths`); `ProtectHome=true`:
  nothing under `/home` is used;
- its process leaves no core dump (`LimitCORE=0`: it holds the key in memory), sees no other user's process
  (`ProtectProc=invisible`), and Python adds no user site-packages from that state directory
  (`PYTHONNOUSERSITE=1`; not `python3 -I`, which would drop `PYTHONDONTWRITEBYTECODE`). A drop-in that sets the
  same three is compatible with the unit;
- it listens on a Unix socket held by systemd from boot (`slingfall-attest.socket`,
  `/run/slingfall-attest/attest.sock`) that only root and the reverse proxy's group can open: the agents' user
  cannot reach the service, and no other process can take the socket while the service is down.

| path | owner | mode | holds |
| --- | --- | --- | --- |
| `/etc/slingfall/attest.key` | `<user>` | 0600 | the attestation key (hex), written by the owner only |
| `/etc/slingfall/attest.env` | `root:<user>` | 0640 | contract address, RPC URL, CORS origin, the key file's path |
| `/etc/systemd/system/slingfall-attest.{socket,service}` | root | 0644 | the units |
| `/run/slingfall-attest/attest.sock` | `root:caddy` | 0660 | the service's socket (systemd's; its directory root 0755) |
| `/opt/slingfall/releases/<sha>/` | root | read-only | one installed revision: code, prebuilt replay, offline scarb cache, `REVISION` |
| `/opt/slingfall/current` | root | link | the running release |
| `/opt/slingfall/scarb/scarb-v2.20.1-x86_64-unknown-linux-gnu/` | root | read-only | scarb 2.20.1, the official tarball |
| `/opt/slingfall/.build/` | root | 0755 | `install.sh`'s scratch builds and its private temporary directory (`tmp.*`, 0700; one of each per run, removed after it) |
| `/var/lib/slingfall-attest/` | `<user>` | 0700 | scratch: `HOME`, the replay's working copy, scarb's cache and config |

`<user>` is a name the owner chooses; `slingfall-attest` by default (`install.sh --user` otherwise).

## Trust: what to review before an install

**The trust model, as the owner accepts it: the agents can merge to `main`.** The agents' Unix user holds
GitHub credentials that merge to `main` (the threads merge their own pull requests), so a merged commit is not
trusted because it is merged. Whatever a commit puts in the release runs as the service user, which reads the
key, and `install.sh` and its check run as root. Anything on that user's side (an agent, or a compromised
dependency an agent ran) could land such a commit. What stands between a merge and the key is the owner's review
of the release paths before each install, in the root-owned checkout: everything the release runs or installs
that changed since the running revision:

```sh
cd /root/src/slingfall-$SHA
OLD="$(cat /opt/slingfall/current/REVISION)"
# 1. All the Python the service runs with the key (the six directories it puts on sys.path, every file in
#    them), what root runs or installs, and every .gitattributes (the root one included): read in full.
git diff "$OLD" "$SHA" -- services/attest crates/slingfall_contract/tools tools/atlantic tools/golden \
    tools/levelc tools/tracec deploy/hosting ':(glob)**/.gitattributes'
# 2. The Cairo dependencies: read in full.
git diff "$OLD" "$SHA" -- Scarb.lock crates/slingfall_replay/Scarb.lock
# 3. The rest of the release: the Cairo crates and the fixtures.
git diff --stat "$OLD" "$SHA" -- crates fixtures Scarb.toml .tool-versions
```

The first command covers every file of the six directories the service imports from (`services/attest`,
`crates/slingfall_contract/tools`, `tools/atlantic`, `tools/golden`, `tools/levelc`, `tools/tracec`), not only
the modules it imports today: anything placed there could be imported by the service user. It also covers
`deploy/hosting` (`install.sh`, `prepare.sh`, the units), which root runs or installs. `install.sh` backs this
up: it refuses a revision that holds compiled Python (`__pycache__`, `*.pyc`) anywhere, or any importable file
(`*.py`, `*.so`, ...) in those six directories that is not in its own `PYTHON_FILES` list, so a new module shows
up in the `install.sh` diff too. The `.gitattributes` files are in it because `git archive`, which `install.sh`
uses to export the release, applies their `export-subst` (which expands `$Format:...$` placeholders, the commit
message included) and `export-ignore`: the release could then differ from the reviewed files. `install.sh`
refuses either attribute on a release path, and checks every exported file against its blob in the commit
(content and mode), with no file missing or extra: the release is the reviewed bytes.

On the first install there is no previous revision: the owner reads all of those directories in full, for
example `ls -R services/attest crates/slingfall_contract/tools tools/atlantic tools/golden tools/levelc
tools/tracec deploy/hosting` and `git ls-files ':(glob)**/.gitattributes'`, then each file (`less`, or
`git show $SHA:<path>`).

The second command shows the Cairo dependencies: registry packages the programme's orchestrators publish. A bump
there changes what the replay computes, so what gets signed. The owner reads it in full and checks each changed
package's version against the programme's publishing records. `install.sh` holds the build to it: the lock the
build settles (the stripped manifests, "Who builds the replay" below) may hold only packages of the committed
`crates/slingfall_replay/Scarb.lock`, with the same version, source and checksum, or the install is refused. A
crate's `Scarb.toml` that asks for another version shows in the third command's `--stat` only, and that check
refuses it. The third command's `--stat` covers only the Cairo
crates and the fixtures: they run inside the Cairo VM and decide what gets signed, not what runs natively; the
pile10 golden check of `install.sh` catches a change that reaches that shot, not every change.

`install.sh` also takes an optional `--signed-tag TAG --signer FINGERPRINT`: it then refuses unless `TAG` points
at the checked-out commit and `git verify-tag` finds a good OpenPGP signature by that key in root's keyring.
It adds nothing to the review above and is not required; used, the fingerprint and the public key come from the
owner's own machine, never from the VPS or from GitHub (the agents hold the GitHub account's token).

## Create (once, as root)

```sh
useradd --system --no-create-home --home-dir /var/lib/slingfall-attest --shell /usr/sbin/nologin slingfall-attest
install -d -o root -g root -m 0755 /etc/slingfall
# The key: a Stark-curve scalar in hex, on one line. Written without echoing it to a terminal or a history.
install -o slingfall-attest -g slingfall-attest -m 0600 /dev/null /etc/slingfall/attest.key
$EDITOR /etc/slingfall/attest.key
```

The key is generated on the owner's own machine and pasted straight into the editor (or generated here as root
with code not taken from `/home`): never with the repository's tools from an agent's checkout, which the agents
control.

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
curl -s --unix-socket /run/slingfall-attest/attest.sock http://localhost/health    # "revision" is $SHA
systemctl show -p MainPID slingfall-attest      # the service's pid ...
ss -lxp | grep /run/slingfall-attest/attest.sock    # ... and who holds the socket: systemd (pid 1) and that pid
```

Check the last three together: `/health` alone is answered by whatever holds the socket. The socket belongs to
systemd from boot, so `ss` lists `systemd` and the service's `python3` (the pid of `MainPID`), nothing else.
`install.sh --proxy-group` names the reverse proxy's group (default `caddy`), the socket's group.

`install.sh` needs git 2.40 or later (`git check-attr --source`; the VPS has 2.43) and refuses an older one.
It refuses a checkout that is not root-owned, is group- or other-writable, has local changes, lives
under `/home`, or reads its git objects from outside itself (a gitfile, a shared or alternate object store). It
validates `--user` and `--proxy-group`, never reads the key (it checks the file's owner and mode with `stat`), never starts or
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
Root's own temporary files (its checks' lists, sort's spills, here-documents) are in one private directory
there too (`mktemp -d`, `TMPDIR` points at it), never in the shared `/tmp`, and the script's exit removes it.

Root then takes only regular files from what `nobody` wrote, copied without following links: if the build
left a symbolic link, a device or a socket among the executables or in the scarb cache, or if either directory
resolves (`realpath`) outside the build directory, the install is refused. It also refuses any shared object or
ELF file there, and again in the whole release before it is made root-owned (the archived `crates/` that
`prepare.sh` copies included): the service user runs no native code from the build or the revision.

That is why `install.sh` makes one deliberate change to the exported files: before the build, it strips every
crate's `Scarb.toml` of what only the tests use (`[dev-dependencies]`, `allow-prebuilt-plugins`, the snforge
profile and tool settings), and the release keeps the `Scarb.lock` the build then settles (a subset of the
committed one, checked: "Trust" above). The strip goes line by line, then Python's `tomllib` reads both
manifests: the stripped one must be the reviewed one minus exactly those keys, so a table hidden in a
multi-line string cannot come alive. With those parts,
`scarb execute --no-build` loads the prebuilt `snforge_scarb_plugin_v0.64.0_x86_64-unknown-linux-gnu.so` from the
scarb cache on every replay (measured with `strace -f -e trace=openat`, scarb 2.20.1): native code fetched from the
registry, run as the key's owner. Without them, scarb fetches no plugin, and the replay opens no shared object
outside the system's libraries (`/lib/x86_64-linux-gnu`) and scarb's own directory (measured the same way:
"Resources" below). The replay's path dependencies have `snforge_std` dev-dependencies too, so stripping the
replay's manifest alone is not enough: the first replay then rewrote the lock and the next one failed offline
(measured), which is also why `install.sh`'s check replays pile10 twice.
The script copies the five `*.executable.json` and that build's scarb cache into the release, makes the release
root-owned and read-only, then runs it as the service will (`prepare.sh`, then the replay offline), again as
`nobody` in a confined unit, and refuses to install unless the pile10 reference shot gives its committed golden
outputs. Nothing on this VPS is known to run as `nobody`, and agents cannot become it.

scarb is the official release tarball of the version `.tool-versions` pins (2.20.1), checked against the
sha256 of the release's own `checksums.sha256` (pinned in `install.sh`:
`https://github.com/software-mansion/scarb/releases/download/v2.20.1/checksums.sha256`, fetched 2026-10-02), extracted by root into `/opt/slingfall/scarb`. The unit's
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
key, a signature input or a body. When the RPC fails, the caller gets `503 chain: cannot read <name>` and the
log adds the exception's type and the RPC's host (`detail="URLError rpc=*.example.net"`): never its URL, whose
path, query or leftmost label may carry the provider's key. Grep the log for `detail=` to diagnose. The unit restarts the service 5 s after any exit, at most 5 times in 300 s.
Past that, systemd also fails the socket unit and closes the socket; recover both, then check who holds it:

```sh
systemctl reset-failed slingfall-attest slingfall-attest.socket && systemctl start slingfall-attest.socket
systemctl restart slingfall-attest
ss -lxp | grep /run/slingfall-attest/attest.sock    # systemd and the service's MainPID only
```

A replay killed for memory fails that request (500), not the unit (`OOMPolicy=continue`).

`GET /health` answers `{"service", "revision", "uptime", "public_key", "mode", "verify", "contract",
"chain_id", "program_hash", "epoch"}`: the installed sha, seconds since the start, and the chain values as last
read for a request (no chain call of its own).

## Socket and limits

systemd listens on the Unix socket `/run/slingfall-attest/attest.sock` (`slingfall-attest.socket`) from boot and
hands it to the service (`--systemd-socket`). The socket is `root:<proxy group> 0660` in a root-owned directory:
only root and the reverse proxy (Caddy, group `caddy` by default) can open it, so the agents' user cannot reach
the service at all, and nothing else can take the path while the service is down. The service trusts
`X-Forwarded-For` only on that socket. Started on TCP instead (`--host`/`--port`, local play), it never reads the
header: a loopback caller counts as `local` whatever it sends, any other peer by its own address.

A connection idle for 10 s (headers or body not arriving), or still sending its request 20 s after it opened
(however slowly it trickles), is closed, a late body with 408; at most 32 connections are open at
once and the next is closed at once, so slow connections cannot exhaust the unit's `TasksMax=64`. A request body above 16 KiB answers 413 (an `--execute` request is under 1 KiB). Browsers may call
only from `ATTEST_CORS_ORIGIN` (the env file: the web client's origin, `https://<subdomain>`).

The limits are in memory (one process: a restart resets them) and answer 429 with `Retry-After`. They are charged
in this order, so a refused request costs nothing further:

| order | flag | default | why |
| --- | --- | --- | --- |
| 1 | `--client-rate` / `--client-window` | 20 / 3600 s | per client address (an IPv6 client is its /64), charged on every `POST /attest` before its body is read, malformed ones included; sized against the one replay slot below |
| 1 | `--local-rate` | 60 / 3600 s | every local caller together: on the socket, a request without a valid IP literal in `X-Forwarded-For` (root's own checks) |
| 2 | (the request is read and parsed) | | a malformed request (400) charges nothing further |
| 3 | `--max-concurrent` | 1 | replays at once: one replay holds 4.6 GB (tower) and a CPU for 12 to 19 s |
| 3 | `--max-queue` | 4 | replays waiting beyond the running one; the next is refused at once (busy) rather than queued for minutes |
| 4 | `--rate` / `--rate-window` | 20 / 3600 s | per player, charged only once the gate admits the request; the player is chosen by the caller |

The client is the last entry of `X-Forwarded-For`, every line of the header joined (the last proxy's addition
comes last; Caddy sets the header to the address it saw); a last entry that is not an IP literal counts as local.
Idle keys are pruned after a window, and at most 100,000 are kept. The player is chosen by the caller and its
address is public: twenty well-formed requests naming a player lock that player out for an hour, at the cost of
twenty of the caller's own replays and client budget.

**One service on one slot can be saturated.** A replay holds the only slot for 12 s (pile10) to 19 s
(tower), so the service attests at most about 300 pile10 replays an hour (about 190 tower ones). With the
defaults, one address gets at most 20 an hour (under a tenth of that). About 15 addresses (15 IPv6 /64s, a handful of
cloud machines) attesting continuously keep the slot busy and the queue full, and every other player then gets
429 busy until they stop. The limits bound the cost of a flood (memory, CPU), not its reach; for the MVP on
Sepolia that is accepted, and the numbers can be tuned in the unit's `ExecStart`.

`--rate 0` turns every limit off (per player, per client, local and the queue's): that is local play's flag
(`scripts/play.sh`), never the hosted service's. Replays then still run `--max-concurrent` at a time.

## Outgoing connections

The service opens one kind of outgoing connection: to the RPC (`STARKNET_RPC_URL`), for the chain id, the
program, the epoch and the latest block. The replay runs offline (`SCARB_OFFLINE=true`). The unit could hold it
to that: `IPAddressDeny=any` with `IPAddressAllow=` the RPC's addresses (systemd's cgroup filter; Unix sockets,
the reverse proxy's included, are not filtered). It is in the unit as a commented, optional block, not on,
because:

- systemd allows addresses and prefixes, never a hostname. A hostname RPC needs its current addresses in the
  unit, and the local resolver's too (`127.0.0.53/32` with systemd-resolved: `/etc/resolv.conf` says which).
- Hosted RPCs sit behind CDNs whose addresses change without notice. The owner then keeps that list by hand, and
  a stale list answers every attestation `503 chain: cannot read ...` until it is updated and the unit
  restarted. Allowing the CDN's whole ranges keeps it working but lets much of the internet back in.
- What it would stop: a compromised service (or code it runs) sending the key anywhere but the RPC. The
  service runs only root-owned, reviewed code ("Trust" above), so this is a second line, not the first.

It suits an RPC on a fixed address (a node of the owner's, a devnet): uncomment both lines, list the addresses,
`systemctl daemon-reload && systemctl restart slingfall-attest`. An equivalent that keeps hostnames, a local
forward proxy with a hostname allowlist, would need the service to speak to it (a code change), so it is not
offered here.

## Resources

One `POST /attest` with `--execute`, measured on the VPS (2026-10-02, scarb 2.20.1 from the official tarball,
`RAYON_NUM_THREADS=1`, a throwaway key, the release built as `install.sh` builds it (stripped manifests, a fresh
scarb cache) and made read-only, under the heavy-build lock): `/usr/bin/time -v` of the service process and its
scarb child, and the peak thread count of each process (`Threads:` of `/proc/<pid>/status`, sampled every 20 ms).
pile10, the reference shot:

```
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:12.19      (the request: 11.56 s)
User time (seconds): 5.16
System time (seconds): 6.56
Percent of CPU this job got: 96%
Maximum resident set size (kbytes): 1776004
peak threads: python3 2, scarb 12, scarb-execute 1 (the whole tree 16)
```

tower, the reference shot, the largest of the golden cases (22.3M Cairo steps):

```
Elapsed (wall clock) time (h:mm:ss or m:ss): 0:21.77      (the request: 18.92 s)
User time (seconds): 10.02
System time (seconds): 9.91
Percent of CPU this job got: 91%
Maximum resident set size (kbytes): 4559116
peak threads: python3 2, scarb 16, scarb-execute 1 (the whole tree 20)
```

Both answers carried the golden outputs, and a third replay on the same working copy (the `strace` run) worked
too. `strace -f -e trace=openat` of that `scarb execute --no-build` lists the shared objects it opens:
`libc.so.6`, `libdl.so.2`, `libgcc_s.so.1`, `libm.so.6`, `libpthread.so.0` and `librt.so.1`, all in
`/lib/x86_64-linux-gnu`; none from the scarb cache or the release (the cache holds no ELF file: `install.sh`
refuses one).

So `MemoryMax=7G` (the tower replay, 4.6 GB, plus the Python process, with headroom; raise it with
`--max-concurrent`, by about 5 GB per extra replay), `OOMPolicy=continue` (an OOM kill fails that replay, not
the unit) and `TasksMax=64`: the main thread, at most 32 connection threads (`MAX_CONNECTIONS`) and one replay's
17 (scarb 16, scarb-execute 1) make 50, leaving 14 spare. Raise `TasksMax` by about 17 per extra
`--max-concurrent`. The service does not take the agents' heavy-build lock: a replay can coincide with an
agent's build, within the VPS's 31 GB.

## Rotating the key

As root, logged in directly over SSH from the owner's own machine ("Root's shell" above), with the new key
generated on that machine:

1. Write the new key: `install -o slingfall-attest -g slingfall-attest -m 0600 /dev/null /etc/slingfall/attest.key.new`,
   edit it, then `mv /etc/slingfall/attest.key.new /etc/slingfall/attest.key`.
2. `systemctl restart slingfall-attest`; `curl -s --unix-socket /run/slingfall-attest/attest.sock http://localhost/health`
   shows the new `public_key`.
3. The same public key through the file:
   `runuser -u slingfall-attest -- env SLINGFALL_ATTEST_KEY_FILE=/etc/slingfall/attest.key /usr/bin/python3 /opt/slingfall/current/services/attest/attest.py pubkey`.
4. The owner's `set_attestation_key(<public key>)` transaction (it bumps `attestation_epoch()`).
5. `systemctl restart slingfall-attest` again, or wait 30 s (the service reads the epoch again after 30 s).

From the first restart until step 5, attestations are rejected by the contract: first because the contract
still holds the old key, then because they carry the old epoch. Attestations signed before the rotation are
void once the epoch bumps. Plan the rotation for a quiet moment; it takes a minute.

## Caddy, when the subdomain exists

The site's lines are an example; two global options are not: `admin off` and no `trusted_proxies` are part of
the service's protection. Caddy's user must be in the socket's group (`caddy` by default).

The read timeouts are optional, and the owner does not set them for now. The service already bounds each request
itself: a connection idle for 10 s, or still sending its request 20 s after it opened, is closed
(`DeadlineReader`, "Socket and limits" above), so a slow client holds one of its 32 connections for 20 s at most.
`read_header` and `read_body` would only stop such clients at Caddy instead. They cannot be scoped to this site:
they are server options (`servers [<listener>] { timeouts { ... } }`), and a server is a listener address, which
every site on `:443` shares, the `ttyd` web terminal included. Set there, they apply to every request of every
site: headers not received within 5 s, or a request body not received within 10 s in all (an upload, any
site's), and Caddy drops the request. Caddy's per-request `timeouts` directive is experimental, bounds only
stalls in a body (not headers, not a total), and needs a global idle timeout turned off; it is not used here.

```caddy
{
    # Required: no admin API (the live state).
    # Never add trusted_proxies (in the global or the server options) covering loopback or this machine's
    # addresses (private_ranges included): Caddy would then pass on an X-Forwarded-For a local caller wrote.
    admin off
    # Optional, not set for now: they apply to every site on this server, the web terminal included (above).
    # servers {
    #     timeouts {
    #         read_header 5s
    #         read_body 10s
    #     }
    # }
}

attest.<domain> {
    request_body {
        max_size 16KB
    }
    reverse_proxy unix//run/slingfall-attest/attest.sock
}
```

Caddy replaces any `X-Forwarded-For` from an untrusted client with the address it saw, which is what the
per-client limit reads. **The per-client limit is only as trustworthy as Caddy's admin access and its
`trusted_proxies`.** By default Caddy's admin API listens on `127.0.0.1:2019` without authentication, so any local
user, the agents' included, could replace Caddy's configuration: set any `X-Forwarded-For`, lift the body cap, or
send the subdomain to another process. On this VPS Caddy's admin API is off (`admin off`, the live state since
2026-10-02), and the example keeps it so. With the API off, `caddy reload` cannot apply a change: any change to
Caddy's configuration, this site included, takes `systemctl restart caddy`. The web client then points
`VITE_ATTEST_URL` at `https://attest.<domain>`, and `ATTEST_CORS_ORIGIN` is that client's origin.
