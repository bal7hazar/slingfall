#!/usr/bin/env python3
"""attest: the attestation service of the provisional tier (contract v2, `docs/contract-v2.md`
"Attestations"; research 06 §2.1). Python 3 standard library only.

    attest.py serve [--key HEX] (--execute | --verify-cmd CMD | --no-verify) --contract HEX
                    [--rpc URL] [--chain-id FELT] [--program-hash HEX] [--epoch N] [--ttl S]
                    [--rate N] [--rate-window S] [--client-rate N] [--client-window S]
                    [--local-rate N] [--max-concurrent N] [--max-queue N] [--cors-origin ORIGIN]
                    [--host H] [--port N | --systemd-socket] [--proof-dir DIR]
                    [--timeout S] [--no-build] [--replay-dir DIR]
    attest.py sign [--key HEX] --chain-id FELT --contract HEX --program-hash HEX --epoch N
                   --expiry T (--outputs FILE | FELT...)
    attest.py pubkey [--key HEX]
    attest.py request --url URL (--level NAME|HASH --inputs FILE | --outputs FILE | FELT...)
                      [--proof-path PATH | --proof FILE]

The key is the attestation secret (a Stark-curve scalar); without `--key` it is read from the
environment variable `SLINGFALL_ATTEST_KEY` (a command line is visible to every user of the
machine), or else from the file `SLINGFALL_ATTEST_KEY_FILE` names (a hosted service: the file
belongs to the service's own user, `docs/hosting.md`). The contract checks the signature with the public key the admin set
(`set_attestation_key`, `attest.py pubkey`).

What is signed (`verifier::attestation_message`):

    poseidon_hash_span(['SLINGFALL_ATTEST', chain_id, contract, program_hash, epoch, expiry,
                        outputs[0..10]])

and the answer's `evidence = [program_hash, expiry, r, s]` is what `submit(outputs, evidence)`
takes. `chain_id` is `--chain-id` or the RPC's `starknet_chainId`; `contract` the deployed
`Slingfall`; `epoch` its `attestation_epoch()` (read again every 30 s, so a key rotation is seen;
`--epoch` pins it offline); `program_hash` is `--program-hash` (the engine release this service
runs) or else the contract's `current_program()`; `expiry = now + --ttl` (default 600 s), `now`
being the later of the latest block's timestamp (when an RPC is configured: a devnet's clock may
run ahead of the wall clock) and the wall clock. The RPC is `--rpc` or `$STARKNET_RPC_URL`.

`serve`: HTTP on `--host:--port` (default 127.0.0.1:8547), or on the socket systemd passes
(`--systemd-socket`: `LISTEN_FDS`; the hosted service's `slingfall-attest.socket` is a Unix socket
only the reverse proxy's group can open), one of three modes:

* `--execute` (research 06 §2.1, the default of a real deployment): `POST /attest` `{"level":
  "<name or level_hash>", "inputs": [felts], "outputs": [10 felts] (optional)}`. The service
  re-executes the replay natively (`scarb execute` of `crates/slingfall_replay`'s proof build
  `main`, as `tools/golden/golden.py` does; built once at start unless `--no-build`), and signs its
  own outputs; claimed `outputs` that differ answer 422. Seconds, not the minutes of a proof.
  `--replay-dir` runs another copy of `crates/slingfall_replay` (with its sibling crates and its
  prebuilt `target/`): scarb opens `Scarb.lock` for writing even with `--no-build`, so a hosted
  service runs a writable copy of its read-only release (`deploy/hosting/prepare.sh`).
* `--verify-cmd CMD`: `POST /attest` `{"outputs": [10 felts], "proof_path": "..."}` (or `"proof":
  "<base64>"`): runs P1's `tools/prove/verify.py` (`<CMD> <proof> <outputs.json>`, the outputs as
  a JSON array of `0x` felts; `{proof}` / `{outputs}` in CMD place the two paths) and signs when it
  exits 0 (422 otherwise). For players who bring a proof. `--proof-dir` confines `proof_path`.
* `--no-verify`: signs whatever outputs it is sent (a devnet without a replay); it warns at start
  and every answer says `"verified": false`. Never expose a `--no-verify` service.

Every answer carries `{"message", "evidence", "signature": [r, s], "public_key", "verified",
"mode", "outputs", "chain_id", "contract", "program_hash", "epoch", "expiry"}`. A malformed
request answers 400 (413 above 16 KiB in `--execute` mode, 64 MiB otherwise) and a refused one
422. Limits (in memory: one process), each answering 429 with `Retry-After`, charged in this order:

1. per client, on every `POST /attest` before its body is read: `--client-rate` (default 20)
   within `--client-window` seconds (default 3 600). On a Unix socket (the reverse proxy's) the
   client is the last entry of `X-Forwarded-For`; on TCP it is the peer address, and the header is
   ignored. An IPv6 client counts as its /64. Local callers (a loopback TCP peer whatever header
   it sends, or a Unix-socket caller without a valid IP literal in the header) share one key,
   capped by `--local-rate` (default 60) within `--client-window`;
2. the request is read and parsed (400: no further limit is charged);
3. globally: `--max-concurrent` executions or verifications run at once (default 1) and at most
   `--max-queue` more wait (default 4); a request refused as busy charges nothing further;
4. per player (`outputs.player`, or `inputs.player`, chosen by the caller): `--rate` requests
   (default 20) within `--rate-window` seconds (default 3 600). A verification refused as
   malformed (400) gives its charge back.

`--rate 0` turns every limit off (local play, `scripts/play.sh`): no 429 at all, the queue is
unbounded, and `--max-concurrent` still runs that many at once. Idle keys are pruned.
`--cors-origin` is the one origin browsers may call from (default `*`, local play). A connection
idle for 10 s is closed, and at most 32 are open at once (the next is closed at once).

`GET /health`: `{"service", "revision", "uptime", "public_key", "mode", "verify", "contract",
"chain_id", "program_hash", "epoch"}` (the last three as last read; no chain call). `revision` is
the `REVISION` file at the root of an installed tree (`deploy/hosting/install.sh`), else null.
Every request logs one line to stdout: time, method, path, status, duration, client and player.

`sign` prints the message and the evidence of the given outputs (offline attestation); `request`
posts to a running service and prints its answer (the client of `deploy/e2e.sh`).
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import json
import math
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "crates" / "slingfall_contract" / "tools"))
import vectors  # noqa: E402  (Stark curve, ECDSA, Poseidon, `attestation_message`)

sys.path.insert(0, str(ROOT / "tools" / "atlantic"))
import encoding  # noqa: E402  (`selector`: starknet_keccak)

# `golden` (tools/golden: `scarb execute` of the replay) is imported by `--execute` only.
sys.path.insert(0, str(ROOT / "tools" / "golden"))

P = vectors.P
N_OUTPUTS = 10  # the felts of `Outputs` (docs/DESIGN.md D4)
PLAYER_INDEX = 3
KEY_ENV = "SLINGFALL_ATTEST_KEY"
KEY_FILE_ENV = "SLINGFALL_ATTEST_KEY_FILE"
SERVICE = "slingfall-attest"
REVISION = ROOT / "REVISION"
MAX_BODY = 64 << 20  # a base64 proof; P1's proofs are a few MB
MAX_EXECUTE_BODY = 16 << 10  # an --execute request: a level, at most 22 input felts, 10 outputs
LEVELS = ROOT / "fixtures" / "levels"
OUTPUT_NAMES = ["version", "level_hash", "seed", "player", "inputs_hash", "score", "won", "shots_used",
                "ticks_run", "final_state_hash"]
DEFAULT_TTL = 600.0
DEFAULT_RATE = 20
DEFAULT_RATE_WINDOW = 3600.0
# One replay holds the only slot for about 14 s (pile10, docs/hosting.md): about 250 an hour in
# all. 20 per address is under a tenth of that; a few players behind one NAT share it.
DEFAULT_CLIENT_RATE = 20
DEFAULT_LOCAL_RATE = 60  # every local caller together (agents on the machine, health checks)
DEFAULT_MAX_CONCURRENT = 1
DEFAULT_MAX_QUEUE = 4
MAX_KEYS = 100_000  # rate-limit keys kept at most (the least recently seen go first)
LOCAL = "local"  # the per-client key of every local caller
IPV6_PREFIX = 64  # an IPv6 client is its /64: one subscriber gets a whole /64
SD_LISTEN_FDS_START = 3
CONNECTION_TIMEOUT = 10.0  # seconds a connection may stay idle (headers, body) before it is closed
MAX_CONNECTIONS = 32  # open at once; each holds a thread (the unit's TasksMax is 64)
CHAIN_TTL = 30.0


class AttestError(Exception):
    """A request the service refuses; `status` is the HTTP status of the answer."""

    def __init__(self, status: int, message: str, retry_after: float | None = None):
        super().__init__(message)
        self.status = status
        self.retry_after = retry_after


# --------------------------------------------------------------------------- felts

def parse_felt(value: object) -> int:
    """A felt from a JSON number or a decimal / `0x` string; must be in `[0, P)`."""
    if isinstance(value, bool):
        raise ValueError(f"not a felt: {value!r}")
    if isinstance(value, int):
        felt = value
    elif isinstance(value, str):
        felt = int(value, 0)
    else:
        raise ValueError(f"not a felt: {value!r}")
    if not 0 <= felt < P:
        raise ValueError(f"felt out of range: {value!r}")
    return felt


def parse_outputs(values: object) -> list[int]:
    if not isinstance(values, list) or len(values) != N_OUTPUTS:
        raise ValueError(f"outputs: expected a list of {N_OUTPUTS} felts")
    return [parse_felt(v) for v in values]


def parse_inputs(values: object) -> list[int]:
    """The `Serde` felts of an `Inputs`: `[player, n, (pull_x, pull_y, delay, ability) * n]`."""
    if not isinstance(values, list) or len(values) < 2:
        raise ValueError("inputs: expected the felts of an Inputs")
    felts = [parse_felt(v) for v in values]
    if felts[1] > 5 or len(felts) != 2 + 4 * felts[1]:
        raise ValueError("inputs: expected [player, n, 4 felts per shot] with n <= 5")
    return felts


def parse_key(text: str | None) -> int:
    """`--key`, else `$SLINGFALL_ATTEST_KEY`, else the file `$SLINGFALL_ATTEST_KEY_FILE` names. No
    message quotes the key."""
    source = "--key"
    if text is None and os.environ.get(KEY_ENV):
        if os.environ.get(KEY_FILE_ENV):
            raise SystemExit(f"key: set {KEY_ENV} or {KEY_FILE_ENV}, not both")
        text, source = os.environ[KEY_ENV], KEY_ENV
    elif text is None and os.environ.get(KEY_FILE_ENV):
        source = os.environ[KEY_FILE_ENV]
        try:
            text = Path(source).read_text().strip()
        except OSError as e:
            raise SystemExit(f"key: cannot read {source}: {e.strerror}") from None
    if not text:
        raise SystemExit(f"no key: pass --key, or set {KEY_ENV} or {KEY_FILE_ENV}")
    try:
        key = int(text, 0)
    except ValueError:
        raise SystemExit(f"key ({source}): not a number") from None
    if not 0 < key < vectors.N:
        raise SystemExit(f"key ({source}): out of range (0, N)")
    return key


def short_string(text: str) -> int:
    return int.from_bytes(text.encode("ascii"), "big")


def parse_chain_id(text: str) -> int:
    """`SN_SEPOLIA` (a short string) or a felt."""
    try:
        return int(text, 0)
    except ValueError:
        return short_string(text)


# --------------------------------------------------------------------------- attestation

def attest(secret: int, chain_id: int, contract: int, program_hash: int, epoch: int, expiry: int,
           outputs: list[int]) -> dict:
    """The v2 attestation of `outputs`: message, signature and the `evidence` of `submit` (checked
    as the contract does)."""
    z = vectors.attestation_message(chain_id, contract, program_hash, epoch, expiry, outputs)
    r, s = vectors.sign(secret, z)
    public_key = vectors.pubkey(secret)
    assert vectors.verify(z, public_key, r, s)
    return {"message": hex(z), "evidence": [hex(program_hash), hex(expiry), hex(r), hex(s)],
            "signature": [hex(r), hex(s)], "public_key": hex(public_key), "chain_id": hex(chain_id),
            "contract": hex(contract), "program_hash": hex(program_hash), "epoch": epoch, "expiry": expiry}


# --------------------------------------------------------------------------- chain

def rpc_call(url: str, method: str, params) -> object:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": "slingfall/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        answer = json.loads(response.read())
    if "error" in answer:
        raise RuntimeError(f"RPC {method}: {answer['error']}")
    return answer["result"]


class Chain:
    """What the signed message needs from the chain, read through `rpc(method, params)` and cached
    for `ttl` seconds; fixed values (`--chain-id`, `--program-hash`, `--epoch`) are never read."""

    def __init__(self, contract: int, rpc=None, chain_id: int | None = None, program_hash: int | None = None,
                 epoch: int | None = None, ttl: float = CHAIN_TTL, clock=time.time):
        self.contract, self.rpc, self.ttl, self.clock = contract, rpc, ttl, clock
        self.fixed = {"chain_id": chain_id, "program_hash": program_hash, "epoch": epoch}
        self._cache: dict[str, tuple[float, int]] = {}
        self._lock = threading.Lock()

    def _call(self, entry_point: str) -> int:
        result = self.rpc("starknet_call", {
            "request": {"contract_address": hex(self.contract), "entry_point_selector": hex(encoding.selector(entry_point)),
                        "calldata": []},
            "block_id": "latest",
        })
        return int(result[0], 16)

    def _read(self, name: str) -> int:
        if name == "chain_id":
            return int(self.rpc("starknet_chainId", []), 16)
        if name == "program_hash":
            return self._call("current_program")
        if name == "epoch":
            return self._call("attestation_epoch")
        if name == "now":
            return int(self.rpc("starknet_getBlockWithTxHashes", {"block_id": "latest"})["timestamp"])
        raise KeyError(name)

    def get(self, name: str) -> int:
        if self.fixed.get(name) is not None:
            return self.fixed[name]
        if self.rpc is None:
            if name == "now":
                return int(self.clock())
            raise AttestError(500, f"{name}: no RPC to read it from (--rpc or --{name.replace('_', '-')})")
        with self._lock:
            cached = self._cache.get(name)
            if cached is not None and self.clock() - cached[0] < self.ttl:
                return cached[1]
            try:
                value = self._read(name)
            except Exception as e:  # noqa: BLE001  (any RPC failure refuses the request, never signs stale)
                raise AttestError(503, f"chain: cannot read {name}: {e}") from None
            self._cache[name] = (self.clock(), value)
            return value

    def context(self) -> dict:
        """The fields of the message besides the outputs; `now` for the expiry: the later of the
        latest block's timestamp (a devnet's clock may run ahead) and the wall clock (an idle
        chain's latest block may be old)."""
        ctx = {name: self.get(name) for name in ("chain_id", "program_hash", "epoch", "now")}
        ctx["now"] = max(ctx["now"], int(self.clock()))
        return ctx

    def known(self) -> dict:
        """The last values read (health)."""
        out = {}
        for name in ("chain_id", "program_hash", "epoch"):
            value = self.fixed.get(name)
            if value is None and name in self._cache:
                value = self._cache[name][1]
            out[name] = None if value is None else (value if name == "epoch" else hex(value))
        return out


# --------------------------------------------------------------------------- execution

def fixture_levels() -> dict[str, tuple[int, list[int]]]:
    """`fixtures/levels/<name>.felts.json` by name: (level_hash, felts)."""
    out = {}
    for path in sorted(LEVELS.glob("*.felts.json")):
        doc = json.loads(path.read_text())
        out[path.name[: -len(".felts.json")]] = (
            int(doc["level_hash"], 0), [int(f, 0) if isinstance(f, str) else int(f) for f in doc["felts"]])
    return out


def resolve_level(level: object) -> str:
    """The fixture name of a level given by name or level hash."""
    if not isinstance(level, str):
        raise ValueError("level: a name or a level hash")
    known = fixture_levels()
    if level in known:
        return level
    try:
        wanted = int(level, 0)
    except ValueError:
        raise ValueError(f"level: unknown {level!r}") from None
    for name, (level_hash, _) in known.items():
        if level_hash == wanted:
            return name
    raise ValueError(f"level: unknown {level!r}")


def scarb_replay(level: str, inputs: list[int], replay_dir: Path | None = None) -> list[int]:
    """The 10 outputs of the proof build `main` on a fixture level (`scarb execute`, built), in the
    repository's `crates/slingfall_replay` or in `replay_dir`."""
    import golden  # noqa: PLC0415  (tools/golden: needs scarb, loaded only by --execute)
    if replay_dir is not None:
        golden.MANIFEST = replay_dir / "Scarb.toml"
    _, outputs, _ = golden.run_build(golden.Level(level), inputs, "main")
    return outputs


class Executor:
    """Re-executes a replay natively (as many at once as the `Gate` lets through).
    `run(level_name, inputs) -> outputs`."""

    def __init__(self, run=scarb_replay):
        self.run = run

    def parse(self, request: dict) -> tuple[str, list[int], list[int] | None]:
        """The level, the inputs and the claimed outputs; 400 before any queueing."""
        try:
            level = resolve_level(request.get("level"))
            inputs = parse_inputs(request.get("inputs"))
            claimed = parse_outputs(request["outputs"]) if "outputs" in request else None
        except ValueError as e:
            raise AttestError(400, str(e)) from None
        return level, inputs, claimed

    def outputs(self, request: dict) -> list[int]:
        level, inputs, claimed = self.parse(request)
        try:
            outputs = [v % P for v in self.run(level, inputs)]
        except Exception as e:  # noqa: BLE001  (a failed run refuses, never signs)
            raise AttestError(500, f"execute: {str(e).strip().splitlines()[0] if str(e).strip() else e!r}") from None
        if len(outputs) != N_OUTPUTS:
            raise AttestError(500, f"execute: {len(outputs)} output felts, expected {N_OUTPUTS}")
        if claimed is not None and claimed != outputs:
            i = next(i for i, (a, b) in enumerate(zip(claimed, outputs)) if a != b)
            raise AttestError(422, f"execute: the claimed {OUTPUT_NAMES[i]} {hex(claimed[i])} differs from the "
                                   f"replay's {hex(outputs[i])}")
        return outputs


# --------------------------------------------------------------------------- verification

class Verifier:
    """Runs the verify command on a proof and the claimed outputs, one at a time."""

    def __init__(self, command: str | None, proof_dir: Path | None, timeout: float):
        self.command = command
        self.proof_dir = proof_dir.resolve() if proof_dir else None
        self.timeout = timeout
        self._lock = threading.Lock()

    def argv(self, proof: Path, outputs: Path) -> list[str]:
        parts = shlex.split(self.command or "")
        if any("{proof}" in p or "{outputs}" in p for p in parts):
            return [p.replace("{proof}", str(proof)).replace("{outputs}", str(outputs)) for p in parts]
        return [*parts, str(proof), str(outputs)]

    def proof_file(self, request: dict, tmp: Path) -> Path:
        if "proof" in request:
            try:
                data = base64.b64decode(request["proof"], validate=True)
            except (binascii.Error, TypeError, ValueError) as e:
                raise AttestError(400, f"proof: not base64 ({e})") from None
            path = tmp / "proof.json"
            path.write_bytes(data)
            return path
        if "proof_path" in request:
            if not isinstance(request["proof_path"], str):
                raise AttestError(400, "proof_path: expected a string")
            path = Path(request["proof_path"]).resolve()
            if self.proof_dir and not path.is_relative_to(self.proof_dir):
                raise AttestError(400, f"proof_path: outside {self.proof_dir}")
            if not path.is_file():
                raise AttestError(400, f"proof_path: no such file {path}")
            return path
        raise AttestError(400, "a proof is required: proof_path or proof (base64)")

    def check(self, request: dict, outputs: list[int]) -> bool:
        """`True` when the proof verifies with these outputs; `False` in `--no-verify` mode."""
        if self.command is None:
            return False
        with tempfile.TemporaryDirectory(prefix="attest_") as tmp_dir:
            tmp = Path(tmp_dir)
            proof = self.proof_file(request, tmp)
            outputs_path = tmp / "outputs.json"
            outputs_path.write_text(json.dumps([hex(v) for v in outputs]))
            argv = self.argv(proof, outputs_path)
            with self._lock:
                try:
                    run = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout, check=False)
                except subprocess.TimeoutExpired:
                    raise AttestError(504, f"verify: timeout after {self.timeout:.0f} s") from None
                except OSError as e:
                    raise AttestError(500, f"verify: cannot run {argv[0]}: {e}") from None
        if run.returncode != 0:
            detail = (run.stderr or run.stdout).strip().splitlines()[-1:] or [""]
            raise AttestError(422, f"verify: rejected (exit {run.returncode}) {detail[0]}".rstrip())
        return True


# --------------------------------------------------------------------------- rate limit

class RateLimiter:
    """At most `limit` requests per key within any `window` seconds (a sliding window; `limit` 0:
    no limit). Keys idle for a window are pruned (at most once per `window / 4`), and at most
    `max_keys` are kept (the least recently seen go first), so memory stays bounded."""

    def __init__(self, limit: int, window: float, clock=time.monotonic, max_keys: int = MAX_KEYS):
        self.limit, self.window, self.clock, self.max_keys = limit, window, clock, max_keys
        self._seen: dict[object, deque] = {}
        self._pruned = clock()
        self._lock = threading.Lock()

    def __len__(self) -> int:
        return len(self._seen)

    def wait(self, key: object) -> float:
        """0 and the request counts, or the seconds until `key` may ask again."""
        if self.limit <= 0:
            return 0.0
        now = self.clock()
        with self._lock:
            if now - self._pruned >= self.window / 4:
                self.prune(now)
            seen = self._seen.pop(key, None) or deque()
            self._seen[key] = seen  # most recently seen last
            while seen and now - seen[0] >= self.window:
                seen.popleft()
            if len(seen) >= self.limit:
                return max(seen[0] + self.window - now, 1e-3)
            seen.append(now)
            while len(self._seen) > self.max_keys:
                del self._seen[next(iter(self._seen))]
            return 0.0

    def allow(self, key: object) -> bool:
        return self.wait(key) == 0.0

    def refund(self, key: object) -> None:
        """Gives back the latest request counted for `key`."""
        with self._lock:
            seen = self._seen.get(key)
            if seen:
                seen.pop()

    def prune(self, now: float) -> None:
        """Drops the keys with no request within the window (lock held)."""
        self._seen = {k: s for k, s in self._seen.items() if s and now - s[-1] < self.window}
        self._pruned = now


class Gate:
    """The global cap on replays: at most `concurrent` run at once and at most `queue` more wait;
    beyond, 429 (`queue` None: no cap on the waiting ones)."""

    def __init__(self, concurrent: int = DEFAULT_MAX_CONCURRENT, queue: int | None = DEFAULT_MAX_QUEUE):
        self.concurrent, self.queue = max(1, concurrent), queue
        self._slots = threading.Semaphore(self.concurrent)
        self._lock = threading.Lock()
        self.admitted = 0  # running and waiting
        self.last_duration = 10.0  # seconds; a first guess for Retry-After until a run is timed

    @contextmanager
    def slot(self, on_admit=None):
        """Admits the job (or 429 busy), calls `on_admit()` (the per-player charge, which may refuse
        it in turn), then waits for a running slot."""
        with self._lock:
            if self.queue is not None and self.admitted >= self.concurrent + self.queue:
                waves = self.admitted // self.concurrent
                raise AttestError(429, f"busy: {self.admitted} replays running or queued",
                                  retry_after=max(1.0, waves * self.last_duration))
            self.admitted += 1
        try:
            if on_admit is not None:
                on_admit()
            with self._slots:
                started = time.monotonic()
                try:
                    yield
                finally:
                    self.last_duration = time.monotonic() - started
        finally:
            with self._lock:
                self.admitted -= 1


def client_key(text: str) -> str | None:
    """The per-client key of an address: the address for IPv4 (an IPv4-mapped IPv6 address too),
    its /64 for IPv6; None when `text` is not an IP literal."""
    try:
        ip = ipaddress.ip_address(text)
    except ValueError:
        return None
    if ip.version == 6:
        if ip.ipv4_mapped is not None:
            return str(ip.ipv4_mapped)
        return str(ipaddress.ip_network(f"{ip}/{IPV6_PREFIX}", strict=False))
    return str(ip)


def client_of(peer: str | None, forwarded: list[str] | str | None, proxied: bool = False) -> str | None:
    """The client a request counts against. On the reverse proxy's Unix socket (`proxied`): the
    last `X-Forwarded-For` entry, every header line joined (the last proxy's addition comes last).
    On TCP: the peer address; the header is ignored. None: a local caller (a loopback TCP peer
    whatever it sends, or a Unix-socket caller without a valid IP literal), counted under `LOCAL`."""
    if not proxied:
        try:
            if ipaddress.ip_address(peer or "").is_loopback:
                return None
        except ValueError:
            return None
        return client_key(peer)
    if isinstance(forwarded, list):
        forwarded = ",".join(forwarded)
    if forwarded:
        return client_key(forwarded.split(",")[-1].strip())
    return None


# --------------------------------------------------------------------------- the service

class Attester:
    """One `POST /attest`: the outputs (executed, verified or taken as they are), the rate limit,
    then the signature over the chain's context."""

    def __init__(self, secret: int, chain: Chain, executor: Executor | None = None, verifier: Verifier | None = None,
                 limiter: RateLimiter | None = None, ttl: float = DEFAULT_TTL, clients: RateLimiter | None = None,
                 gate: Gate | None = None, revision: str | None = None, local: RateLimiter | None = None):
        self.secret, self.chain, self.executor, self.ttl = secret, chain, executor, ttl
        self.verifier = verifier or Verifier(None, None, 1)
        self.limiter = limiter if limiter is not None else RateLimiter(DEFAULT_RATE, DEFAULT_RATE_WINDOW)
        self.clients = clients if clients is not None else RateLimiter(DEFAULT_CLIENT_RATE, DEFAULT_RATE_WINDOW)
        self.gate = gate if gate is not None else Gate()
        self.local = local if local is not None else RateLimiter(DEFAULT_LOCAL_RATE, DEFAULT_RATE_WINDOW)
        self.revision = revision
        self.public_key = hex(vectors.pubkey(secret))
        self.started = time.monotonic()

    @property
    def mode(self) -> str:
        if self.executor is not None:
            return "execute"
        return "verify" if self.verifier.command else "none"

    def player_of(self, request: dict) -> int:
        try:
            if self.executor is not None:
                return parse_felt((request.get("inputs") or [None])[0])
            return parse_outputs(request.get("outputs"))[PLAYER_INDEX]
        except (ValueError, TypeError, AttributeError) as e:
            raise AttestError(400, str(e)) from None

    @property
    def max_body(self) -> int:
        return MAX_EXECUTE_BODY if self.executor is not None else MAX_BODY

    def charge_client(self, client: str | None) -> None:
        """The per-client limit (`client` from `client_of`; None: local), charged on every POST
        before its body is read, so a malformed request counts too."""
        if client is None:
            wait = self.local.wait(LOCAL)
            if wait:
                raise AttestError(429, f"rate limit: more than {self.local.limit} requests from local callers "
                                       f"in {self.local.window:.0f} s", retry_after=wait)
        else:
            wait = self.clients.wait(client)
            if wait:
                raise AttestError(429, f"rate limit: more than {self.clients.limit} requests from {client} "
                                       f"in {self.clients.window:.0f} s", retry_after=wait)

    def handle(self, request: dict, info: dict | None = None) -> dict:
        """One request whose client is already charged (`charge_client`); `info` gets the player
        (the log). The player is charged once the request parses and the gate admits it."""
        if not isinstance(request, dict):
            raise AttestError(400, "expected a JSON object")
        player = self.player_of(request)
        if info is not None:
            info["player"] = hex(player)

        def charge_player() -> None:
            wait = self.limiter.wait(player)
            if wait:
                raise AttestError(429, f"rate limit: more than {self.limiter.limit} requests for player "
                                       f"{hex(player)} in {self.limiter.window:.0f} s", retry_after=wait)

        if self.executor is not None:
            self.executor.parse(request)  # a malformed request is refused before it queues or counts
            with self.gate.slot(charge_player):
                outputs = self.executor.outputs(request)
            verified = True
        else:
            try:
                outputs = parse_outputs(request.get("outputs"))
            except ValueError as e:
                raise AttestError(400, str(e)) from None
            if self.verifier.command is None:
                charge_player()
                verified = False
            else:
                with self.gate.slot(charge_player):
                    try:
                        verified = self.verifier.check(request, outputs)
                    except AttestError as e:
                        if e.status == 400:  # a malformed proof field: the player's count is unchanged
                            self.limiter.refund(player)
                        raise
        ctx = self.chain.context()
        expiry = int(ctx["now"] + self.ttl)
        body = attest(self.secret, ctx["chain_id"], self.chain.contract, ctx["program_hash"], ctx["epoch"], expiry, outputs)
        return {**body, "verified": verified, "mode": self.mode, "outputs": [hex(v) for v in outputs]}

    def health(self) -> dict:
        return {"service": SERVICE, "revision": self.revision, "uptime": round(time.monotonic() - self.started, 1),
                "public_key": self.public_key, "mode": self.mode, "verify": self.verifier.command,
                "contract": hex(self.chain.contract), **self.chain.known()}


def read_revision(path: Path = REVISION) -> str | None:
    """The git sha `install.sh` wrote; None in a checkout."""
    try:
        return path.read_text().strip() or None
    except OSError:
        return None


def make_handler(attester: Attester, log=sys.stdout, cors_origin: str = "*", timeout: float = CONNECTION_TIMEOUT):
    class Handler(BaseHTTPRequestHandler):
        server_version = "slingfall-attest/2"
        timeout = None  # set after the class: a stalled header or body read ends the connection

        def peer(self) -> str:
            # A Unix socket's peer has no address ("unix" in the log).
            return self.client_address[0] if isinstance(self.client_address, tuple) else "unix"

        def log_request(self, code="-", size="-"):
            pass  # one line per request, written by `answer`

        def log_message(self, fmt, *args):
            # Errors of the HTTP layer (a malformed request line): never a body.
            print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} attest: {self.peer()} "
                  f"{fmt % args}", file=log, flush=True)

        def setup(self):
            super().setup()
            self.started, self.info = time.monotonic(), {}

        def client(self) -> str | None:
            if not isinstance(self.client_address, tuple):  # the reverse proxy's Unix socket
                return client_of(None, self.headers.get_all("X-Forwarded-For"), proxied=True)
            return client_of(self.client_address[0], None)

        def answer(self, status: int, body: dict, retry_after: float | None = None) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            if retry_after is not None:
                self.send_header("Retry-After", str(max(1, math.ceil(retry_after))))
            self.cors()
            self.end_headers()
            # Logged before the body goes out: once the caller has its answer, the line is written.
            fields = " ".join(f"{k}={v}" for k, v in self.info.items())
            print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {self.command} {self.path} {status} "
                  f"{time.monotonic() - self.started:.3f}s client={self.client() or 'local'} {fields}".rstrip(),
                  file=log, flush=True)
            self.wfile.write(data)

        def cors(self) -> None:
            # The client runs on another origin (the Vite dev server; the web client's subdomain).
            self.send_header("Access-Control-Allow-Origin", cors_origin)
            if cors_origin != "*":
                self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")

        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self.cors()
            print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} OPTIONS {self.path} 204 "
                  f"{time.monotonic() - self.started:.3f}s client={self.client() or 'local'}", file=log, flush=True)
            self.end_headers()

        def do_GET(self):  # noqa: N802
            if self.path != "/health":
                return self.answer(404, {"error": "not found"})
            self.answer(200, attester.health())

        def do_POST(self):  # noqa: N802
            if self.path != "/attest":
                return self.answer(404, {"error": "not found"})
            try:
                attester.charge_client(self.client())
                try:
                    length = int(self.headers.get("Content-Length") or 0)
                except ValueError:
                    raise AttestError(400, "body: bad Content-Length") from None
                if not 0 < length <= attester.max_body:
                    raise AttestError(400 if length <= 0 else 413, "body: missing or too large")
                try:
                    data = self.rfile.read(length)
                except TimeoutError:
                    self.close_connection = True
                    raise AttestError(408, f"body: not received within {timeout:.0f} s") from None
                if len(data) != length:
                    self.close_connection = True
                    raise AttestError(400, "body: shorter than its Content-Length")
                try:
                    request = json.loads(data)
                except ValueError as e:
                    raise AttestError(400, f"body: {e}") from None
                body = attester.handle(request, self.info)
                self.info.update(mode=body["mode"], epoch=body["epoch"], message=body["message"])
                self.answer(200, body)
            except AttestError as e:
                self.info["error"] = json.dumps(str(e)[:200])
                self.answer(e.status, {"error": str(e)}, e.retry_after)

    Handler.timeout = timeout
    return Handler


class Server(ThreadingHTTPServer):
    """One thread per connection, at most `max_connections` open: the next is closed at once
    rather than given a thread (a slow-connection flood cannot exhaust the unit's tasks)."""

    daemon_threads = True
    max_connections = MAX_CONNECTIONS

    def process_request(self, request, client_address):
        if not hasattr(self, "_open"):
            self._open = threading.BoundedSemaphore(self.max_connections)
        if not self._open.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._open.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._open.release()


def systemd_socket(environ=os.environ, fd: int = SD_LISTEN_FDS_START) -> socket.socket:
    """The one listening socket systemd passed (`LISTEN_PID`, `LISTEN_FDS`: socket activation)."""
    if environ.get("LISTEN_PID") != str(os.getpid()) or environ.get("LISTEN_FDS") != "1":
        raise SystemExit("serve: --systemd-socket needs exactly one socket from systemd (LISTEN_PID, LISTEN_FDS)")
    for name in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES"):
        environ.pop(name, None)
    return socket.socket(fileno=fd)


def serve(attester: Attester, host: str, port: int, cors_origin: str = "*", sock: socket.socket | None = None,
          log=sys.stdout, timeout: float = CONNECTION_TIMEOUT, max_connections: int = MAX_CONNECTIONS) -> Server:
    """HTTP on `host:port`, or on a listening socket already bound (systemd's: TCP or Unix)."""
    handler = make_handler(attester, log, cors_origin, timeout)
    if sock is None:
        server = Server((host, port), handler)
    else:
        server = Server(("127.0.0.1", 0), handler, bind_and_activate=False)
        server.socket.close()
        server.socket = sock
        server.address_family = sock.family
        server.server_address = sock.getsockname()
    server.max_connections = max_connections
    return server


def describe(address) -> str:
    """`http://host:port`, or `unix:<path>`."""
    if isinstance(address, tuple):
        return f"http://{address[0]}:{address[1]}"
    return f"unix:{address.decode() if isinstance(address, bytes) else address}"


# --------------------------------------------------------------------------- CLI

def read_outputs(args) -> list[int]:
    if args.outputs:
        doc = json.loads(Path(args.outputs).read_text())
        return parse_outputs(doc["outputs"] if isinstance(doc, dict) else doc)
    return parse_outputs(args.felts)


def make_attester(args) -> Attester:
    secret = parse_key(args.key)
    modes = [bool(args.execute), bool(args.verify_cmd), bool(args.no_verify)]
    if sum(modes) != 1:
        sys.exit("serve: pass exactly one of --execute, --verify-cmd and --no-verify")
    rpc_url = args.rpc or os.environ.get("STARKNET_RPC_URL")
    rpc = (lambda method, params: rpc_call(rpc_url, method, params)) if rpc_url else None
    chain = Chain(int(args.contract, 0), rpc,
                  chain_id=parse_chain_id(args.chain_id) if args.chain_id else None,
                  program_hash=int(args.program_hash, 0) if args.program_hash else None,
                  epoch=args.epoch)
    executor = None
    if args.execute:
        replay_dir = Path(args.replay_dir).resolve() if args.replay_dir else None
        if replay_dir is not None and not (replay_dir / "Scarb.toml").is_file():
            sys.exit(f"serve: no Scarb.toml in --replay-dir {replay_dir}")
        if replay_dir is not None and not args.no_build:
            sys.exit("serve: --replay-dir runs a prebuilt replay: pass --no-build")
        if not args.no_build:
            import golden  # noqa: PLC0415
            print("attest: building the replay (scarb build)", file=sys.stderr, flush=True)
            golden.build()
        executor = Executor(lambda level, inputs: scarb_replay(level, inputs, replay_dir))
    verifier = Verifier(args.verify_cmd, Path(args.proof_dir) if args.proof_dir else None, args.timeout)
    # `--rate 0` (local play) turns off every limit: per player, per client and the queue's.
    unlimited = args.rate <= 0
    clients = RateLimiter(0 if unlimited else args.client_rate, args.client_window)
    local = RateLimiter(0 if unlimited else args.local_rate, args.client_window)
    gate = Gate(args.max_concurrent, None if unlimited else args.max_queue)
    return Attester(secret, chain, executor, verifier, RateLimiter(args.rate, args.rate_window), args.ttl,
                    clients, gate, read_revision(), local)


def cmd_serve(args) -> int:
    attester = make_attester(args)
    if attester.mode == "none":
        print("attest: WARNING --no-verify: signing ANY outputs without a replay or a proof. Devnet only; "
              "never expose this service.", file=sys.stderr)
    if not args.cors_origin:
        sys.exit("serve: --cors-origin is empty (the web client's origin, or *)")
    sock = systemd_socket() if args.systemd_socket else None
    server = serve(attester, args.host, args.port, args.cors_origin, sock)
    print(f"attest: public key {attester.public_key}", file=sys.stderr)
    limits = (f"rate {args.rate} per {args.rate_window:.0f} s per player, {args.client_rate} per "
              f"{args.client_window:.0f} s per client, {args.local_rate} for local callers, "
              f"{attester.gate.concurrent} running + {args.max_queue} queued"
              if args.rate > 0 else "no limits (--rate 0)")
    print(f"attest: listening on {describe(server.server_address)} (mode {attester.mode}, contract {args.contract}, "
          f"revision {attester.revision}, {limits}, CORS {args.cors_origin}"
          f"{', socket from systemd' if sock else ''})", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def cmd_sign(args) -> int:
    body = attest(parse_key(args.key), parse_chain_id(args.chain_id), int(args.contract, 0), int(args.program_hash, 0),
                  args.epoch, args.expiry, read_outputs(args))
    print(json.dumps(body, indent=2))
    return 0


def cmd_pubkey(args) -> int:
    print(hex(vectors.pubkey(parse_key(args.key))))
    return 0


def cmd_request(args) -> int:
    body: dict = {}
    if args.level:
        if not args.inputs:
            sys.exit("request: --level needs --inputs")
        doc = json.loads(Path(args.inputs).read_text())
        body["level"] = args.level
        body["inputs"] = [hex(parse_felt(v)) for v in (doc["inputs"] if isinstance(doc, dict) else doc)]
        if args.outputs or args.felts:
            body["outputs"] = [hex(v) for v in read_outputs(args)]
    else:
        body["outputs"] = [hex(v) for v in read_outputs(args)]
    if args.proof_path:
        body["proof_path"] = args.proof_path
    if args.proof:
        body["proof"] = base64.b64encode(Path(args.proof).read_bytes()).decode()
    request = urllib.request.Request(
        args.url.rstrip("/") + "/attest", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            print(response.read().decode())
            return 0
    except urllib.error.HTTPError as e:
        print(f"attest: {e.code} {e.read().decode()}", file=sys.stderr)
        return 1


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    def outputs_args(p):
        p.add_argument("--outputs", help="JSON file: a list of 10 felts, or {\"outputs\": [...]}")
        p.add_argument("felts", nargs="*", help="the 10 output felts")

    p = sub.add_parser("serve", help="run the HTTP service")
    p.add_argument("--key", help=f"attestation secret (default: ${KEY_ENV})")
    p.add_argument("--execute", action="store_true", help="re-execute the replay (scarb execute) and sign its outputs")
    p.add_argument("--verify-cmd", help="command verifying <proof> <outputs.json> (P1's tools/prove/verify.py)")
    p.add_argument("--no-verify", action="store_true", help="sign without a replay or a proof (devnet only)")
    p.add_argument("--contract", required=True, help="the deployed Slingfall (part of the signed message)")
    p.add_argument("--rpc", help="Starknet RPC (default $STARKNET_RPC_URL): chain id, epoch, program, block time")
    p.add_argument("--chain-id", help="fixed chain id (SN_SEPOLIA or a felt) instead of starknet_chainId")
    p.add_argument("--program-hash", help="the engine release this service runs (default: current_program())")
    p.add_argument("--epoch", type=int, help="fixed attestation epoch instead of attestation_epoch()")
    p.add_argument("--ttl", type=float, default=DEFAULT_TTL, help="seconds until an attestation expires")
    p.add_argument("--rate", type=int, default=DEFAULT_RATE,
                   help="requests per player per window (0: no limit at all, per player, per client or queue)")
    p.add_argument("--rate-window", type=float, default=DEFAULT_RATE_WINDOW, help="seconds")
    p.add_argument("--client-rate", type=int, default=DEFAULT_CLIENT_RATE,
                   help="requests per client address per window (local callers are not counted)")
    p.add_argument("--client-window", type=float, default=DEFAULT_RATE_WINDOW, help="seconds")
    p.add_argument("--local-rate", type=int, default=DEFAULT_LOCAL_RATE,
                   help="requests per --client-window from every local caller together")
    p.add_argument("--cors-origin", default="*", help="the origin browsers may call from (default *: local play)")
    p.add_argument("--max-concurrent", type=int, default=DEFAULT_MAX_CONCURRENT, help="replays running at once")
    p.add_argument("--max-queue", type=int, default=DEFAULT_MAX_QUEUE, help="replays waiting at most; beyond, 429")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8547)
    p.add_argument("--systemd-socket", action="store_true",
                   help="listen on the socket systemd passes (socket activation) instead of --host:--port")
    p.add_argument("--proof-dir", help="proof_path must be inside this directory")
    p.add_argument("--timeout", type=float, default=900.0, help="verify command timeout, seconds")
    p.add_argument("--no-build", action="store_true", help="--execute: the replay is already built")
    p.add_argument("--replay-dir", help="--execute: a writable copy of crates/slingfall_replay, prebuilt "
                                        "(default: the repository's)")
    p.set_defaults(run=cmd_serve)

    p = sub.add_parser("sign", help="sign outputs offline")
    p.add_argument("--key")
    p.add_argument("--chain-id", required=True)
    p.add_argument("--contract", required=True)
    p.add_argument("--program-hash", required=True)
    p.add_argument("--epoch", type=int, required=True)
    p.add_argument("--expiry", type=int, required=True)
    outputs_args(p)
    p.set_defaults(run=cmd_sign)

    p = sub.add_parser("pubkey", help="print the public key to set_attestation_key")
    p.add_argument("--key")
    p.set_defaults(run=cmd_pubkey)

    p = sub.add_parser("request", help="POST /attest to a running service")
    p.add_argument("--url", default="http://127.0.0.1:8547")
    p.add_argument("--level", help="--execute service: the level (name or hash)")
    p.add_argument("--inputs", help="--execute service: JSON file, the Inputs felts or {\"inputs\": [...]}")
    p.add_argument("--proof-path")
    p.add_argument("--proof", help="a proof file sent inline (base64)")
    p.add_argument("--timeout", type=float, default=960.0)
    outputs_args(p)
    p.set_defaults(run=cmd_request)
    return parser


def main(argv: list[str]) -> int:
    args = make_parser().parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
