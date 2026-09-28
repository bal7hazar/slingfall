#!/usr/bin/env python3
"""prove_service: the prover service of the settled tier (lot E3b, `docs/DESIGN.md` D9,
`docs/proving.md` "Atlantic + Integrity"). Python 3 standard library; reuses `tools/atlantic`.

    prove_service.py serve [--host H] [--port N] [--store DIR] [--result R] [--no-submit]
                           [--no-translate] [--translate-grace SECONDS] [--relay]
    prove_service.py prove (--level NAME|HASH) (--inputs FELT,... | --player FELT --shot PX,PY[,D]...)
                           [--store DIR] [--result R] [--no-submit] [--watch [--interval S]]
    prove_service.py status <job-id> [--store DIR] [--watch [--interval S]] [--no-chain]
    prove_service.py translate <job-id> [--store DIR] [--dry-run]
    prove_service.py relay <job-id> [--store DIR]
    (every command) [--snip36 fake|snip36 [--prover-url URL] [--budget L2GAS] [--parallel N]]
    prove_service.py prove --tier proven --snip36 fake|snip36 ...

The SNIP-36 path (lot W3, contract v3's *proven* tier; `snip36.py`, `docs/proving.md` "SNIP-36"),
beside Atlantic's, with `--snip36`: `POST /prove` with `"tier": "proven"` plans the attempt as the
chain of the contract's `current_chain()` (layout (e): `init`, `step_chunk` x n, `outputs`, each
virtual transaction under `--budget` L2 gas), proves every transaction in parallel through the
prover (`fake`: the devnet's execution, facts laid out as the protocol does; `snip36`:
`starknet_proveTransaction` of `--prover-url`), sends one Invoke per proof (`submit_chunk` per
message) and `finalize`, all from the account of the environment (a relay: the record is
`inputs.player`'s). It refuses (409) unless `chain_bundle(current_chain())` is this service's bundle
and `chain_valid_until` is in the future. `/status/<id>` of such a job says `"tier": "proven"`, its
`state` (`queued`, `planning`, `proving`, `submitting`, `finalizing`, `proven`, `failed`), `plan`
(transactions, their L2 gas), each proof's state in `proofs`, `finalize` and the chain check;
`/health` carries `"tiers"` and `"proven"` (the prover, the chain, `chain_match`, `available`).

`serve`: HTTP on `--host:--port` (default 127.0.0.1:8549).

* `POST /prove` `{"level": "<name or level_hash>", "inputs": [felts]}` (the `Serde` felts of the
  `Inputs`): creates (or finds) the job and answers it at once (`202`); a worker builds the PIE
  (`c1main` under `cairo1-run` of the patched fork, as `atlantic.py c1-input` + the E3a
  command), checks the run's outputs, computes the facts (`encoding.slingfall_fact`) and submits
  the PIE to Atlantic (`declaredJobSize` by the run's steps, `dedupId` = the job id). One PIE at a
  time. **M6** (contract v2's program set, `docs/contract-v2.md` "Programs"): before any of that,
  once this service's own `child_program_hash` is known (a run has computed it), the deployed
  contract (`SLINGFALL_ADDRESS`, else `deploy/sepolia.json`'s `address`) is asked
  `program_valid_until(hash)`; unless it is after the latest block's timestamp (the current
  program, or a former one still in its grace period), the contract will refuse the proof, and the
  service answers `409` with `program_hash`, `contract_program_hash` (`current_program()`) and
  `program_valid_until` instead of spending an hour on it. The check never blocks on an
  unreachable RPC or before the service's first run (`--no-program-check` disables it).
* `GET /status/<id>`: the job, Atlantic's status and stages, and the Satellite's answer for its
  facts (`isCairoFactValid` / `isKeccakVerifiedFactHashValid`): `"settleable_poseidon"` (the
  translated fact: the cheap `submit_settled`), `"settleable_keccak"` (the bridged keccak fact
  only: the dearer one) and `"settleable"` (either: `submit_settled(outputs, inputs)` would pass);
  all three are also gated on `"program_match"` (M6: the job's `"program_hash"` is valid on the
  contract now, `program_valid_until > now`; `null` when unknown), since a fact that exists on the
  Satellite still cannot settle once its program is past its grace period or revoked
  (`"program_valid_until"`, and the contract's `"contract_program_hash"` beside it). The Satellite
  read is the one of the contract's `satellite_config()` (Herodotus's on Sepolia, the devnet's
  `FakeSatellite`). `"translation"`: what the service does about the Poseidon fact (below);
  `"relay"` / `"relayed"` / `"relay_transaction_hash"`: what the relay did (below).
* `GET /health`: also carries `"program_hash"` / `"contract_program_hash"` / `"program_match"` /
  `"program_valid_until"` and `"relay"` (the relay account, or `null`).

Relay (contract v2, QA S10; `relay.py`), off by default: with `serve --relay` and an account in the
environment (the one of the translations), a background thread sends `submit_settled(outputs, args,
child_program_hash)` for `claim.player` once a job is `settleable`, the attempt is not settled yet
(`attempt(...)`) and a simulation of the transaction succeeds; at most 3 attempts, 5 minutes apart.
`/status` then reports `"relayed": true` and the transaction hash. The player can still settle
themselves (the relay then records `"state": "settled"` and sends nothing). `relay <job>` runs one
relay pass for a job now (backoff ignored).

Translation (lot E3c). Atlantic's `PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION` stalled (E3a, E3b),
so the queries ask for `PROOF_VERIFICATION_ON_L2`, which ends with the keccak fact bridged to the
Satellite. When Atlantic's status is `DONE` and the translated (Poseidon) fact is still absent
after `TRANSLATE_GRACE` seconds (default 600; env or `--translate-grace`), a background thread
of `serve` calls the Satellite's permissionless `translateFactHash` itself (`atlantic.translate`,
one transaction from the account of the environment: `STARKNET_ACCOUNT_ADDRESS` +
`STARKNET_PRIVATE_KEY` + `STARKNET_RPC_URL`, or `SLINGFALL_*`; at most 3 attempts, 10 minutes
apart). Without an account (or with `--no-translate`) `"translation"` reports `"off"` from the
first status read (m13: not `"grace"` for ten minutes and then a dead end), and the service only
ever reports `settleable_keccak`. `translate <job>` translates one job now, grace or not.

The job id is `sha256(level_hash, inputs, child program, result)`: the same attempt maps to the
same job and the same Atlantic query (retries are idempotent). Jobs live in `--store`
(`<store>/<id>/job.json`, the PIE and the run's input next to it); a restarted service resumes
the jobs whose PIE was not submitted yet.

`prove` runs the same pipeline in the foreground (the Sepolia deployment's first settled submit);
`status` reads a stored job. `--no-submit` stops after the PIE and the facts (tests, dry runs).

Environment (never printed): `ATLANTIC_API_KEY` (submit, status), `STARKNET_RPC_URL` (the
Satellite's reads, and M6's program reads), the account of the translations and of the relay
(above). `SLINGFALL_ADDRESS`: the deployed `Slingfall` (v2) whose programs, Satellite and records
the service reads and relays to (default `deploy/sepolia.json`'s `address`). Paths: `PROVE_CAIRO1_RUN` (default the fork build of `docs/proving.md`,
`tools/atlantic/out/starkware-cairo-vm/target/release/cairo1-run`), `PROVE_SIERRA` (default
`tools/atlantic/c1main/target/dev/c1main.sierra.json`, built by `scarb --manifest-path
tools/atlantic/c1main/Scarb.toml build`).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import zipfile
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "atlantic"))
import atlantic  # noqa: E402
import encoding  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import relay as relaying  # noqa: E402
import snip36  # noqa: E402

P = encoding.P
LEVELS = ROOT / "fixtures" / "levels"
DEFAULT_STORE = ROOT / "services" / "prove" / "out"
DEFAULT_CAIRO1_RUN = ROOT / "tools" / "atlantic" / "out" / "starkware-cairo-vm" / "target" / "release" / "cairo1-run"
DEFAULT_SIERRA = ROOT / "tools" / "atlantic" / "c1main" / "target" / "dev" / "c1main.sierra.json"
# M6: the deployment whose programs a proof must match; `deploy/sepolia.json` is the only
# Satellite deployment today (read only: this service never writes to it).
DEFAULT_SEPOLIA_CONFIG = ROOT / "deploy" / "sepolia.json"
# The result that completes today (E3a); `..._WITH_TRANSLATION` stalled after trace generation on
# 2026-09-26 (`docs/proving.md`) and is accepted by `--result`.
DEFAULT_RESULT = "PROOF_VERIFICATION_ON_L2"
RESULTS = ("PROOF_VERIFICATION_ON_L2", "PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION")
# `POST /prove`'s `tier`: Atlantic + the Satellite (contract v2's settled tier), or SNIP-36 (v3's proven).
TIERS = ("settled", "proven")
N_OUTPUTS = 10
# Translation (E3c): the wait for Atlantic's own translation, the retries of a failed transaction,
# the pause of the background thread.
DEFAULT_TRANSLATE_GRACE = 600.0
TRANSLATE_ATTEMPTS = 3
TRANSLATE_RETRY = 600.0
TRANSLATE_INTERVAL = 120.0
# Job sizes (E3a: S is OOM-killed at 6.3M bootloaded steps, M holds one_block, L holds pile10's
# 12.7M). The bootloader adds ~3.6M steps (Pedersen over the program) to the run's own steps.
BOOTLOADER_OVERHEAD = 3_600_000
SIZE_M_MAX = 8_000_000
MAX_BODY = 1 << 20


class ProveError(Exception):
    def __init__(self, status: int, message: str, **extra: object):
        super().__init__(message)
        self.status = status
        # M6: `POST /prove`'s 409 carries both program hashes alongside the message.
        self.extra = extra


# --------------------------------------------------------------------------- inputs

def parse_felt(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError(f"not a felt: {value!r}")
    felt = int(value, 0) if isinstance(value, str) else value
    if not -P < felt < P:
        raise ValueError(f"felt out of range: {value!r}")
    return felt % P


def levels() -> dict[str, dict]:
    """`fixtures/levels/<name>.felts.json` by name: `{"level_hash", "felts"}`."""
    out = {}
    for path in sorted(LEVELS.glob("*.felts.json")):
        doc = json.loads(path.read_text())
        out[path.name[: -len(".felts.json")]] = {
            "level_hash": int(doc["level_hash"], 0),
            "felts": [int(f, 0) if isinstance(f, str) else int(f) for f in doc["felts"]],
        }
    return out


def resolve_level(level: object) -> tuple[str, int, list[int]]:
    """(name, level_hash, felts) of a fixture level given by name or level hash."""
    if not isinstance(level, str):
        raise ValueError("level: a name or a level hash")
    known = levels()
    if level in known:
        return level, known[level]["level_hash"], known[level]["felts"]
    try:
        wanted = int(level, 0)
    except ValueError:
        raise ValueError(f"level: unknown {level!r}") from None
    for name, doc in known.items():
        if doc["level_hash"] == wanted:
            return name, wanted, doc["felts"]
    raise ValueError(f"level: unknown {level!r}")


def parse_inputs(values: object) -> list[int]:
    """The `Serde` felts of an `Inputs`: `[player, n, (pull_x, pull_y, delay, ability) * n]`."""
    if not isinstance(values, list) or len(values) < 2:
        raise ValueError("inputs: expected the felts of an Inputs")
    felts = [parse_felt(v) for v in values]
    if felts[1] > 5 or len(felts) != 2 + 4 * felts[1]:
        raise ValueError("inputs: expected [player, n, 4 felts per shot] with n <= 5")
    return felts


def run_args(level: list[int], inputs: list[int]) -> list[int]:
    """`c1main`'s argument: `[len(level), level..., len(inputs), inputs...]`."""
    return [len(level), *level, len(inputs), *inputs]


def job_id(level_hash: int, inputs: list[int], child_program: str, result: str) -> str:
    digest = hashlib.sha256(json.dumps([hex(level_hash), [hex(x) for x in inputs], child_program, result]).encode())
    return digest.hexdigest()[:32]


def job_output(job: dict) -> list[int]:
    """Atlantic's output of a built job (what `translateFactHash` re-hashes on the Satellite)."""
    _, _, level = resolve_level(job["level"])
    args = run_args(level, [int(x, 16) for x in job["inputs"]])
    return encoding.run_output(int(job["run"]["child_program_hash"], 16), [int(x, 16) for x in job["outputs"]], args)


def parse_time(stamp: object) -> float | None:
    """Epoch seconds of an ISO 8601 timestamp (Atlantic's `completedAt`), or None."""
    if not isinstance(stamp, str):
        return None
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def translation_decision(atlantic_status: str | None, done_at: float | None, chain: dict | None, now: float,
                         grace: float, has_account: bool, translation: dict | None = None) -> str:
    """What the service does about the Poseidon fact of a submitted job:

    * `translated`: the translated fact is on the Satellite (Atlantic's or ours): nothing to do;
    * `unknown`: no chain answer (the reads failed or are off);
    * `off`: no account (or `--no-translate`): translation will never happen, reported at once
      (m13: not `grace` for ten minutes on a service that can never translate);
    * `waiting`: Atlantic is not `DONE`, or the keccak fact is not on the Satellite yet;
    * `grace`: keccak fact bridged, Atlantic's own translation may still come (`done_at` + `grace`);
    * `gave-up`: `TRANSLATE_ATTEMPTS` transactions failed;
    * `backoff`: the last attempt is less than `TRANSLATE_RETRY` seconds old;
    * `translate`: send `translateFactHash` now."""
    translation = translation or {}
    if not chain or "isCairoFactValid" not in chain:
        return "unknown"
    if chain["isCairoFactValid"]:
        return "translated"
    if not has_account:
        return "off"
    if atlantic_status != "DONE" or not chain["isKeccakVerifiedFactHashValid"]:
        return "waiting"
    if done_at is None or now - done_at < grace:
        return "grace"
    if translation.get("attempts", 0) >= TRANSLATE_ATTEMPTS:
        return "gave-up"
    if now - translation.get("last_attempt", -TRANSLATE_RETRY) < TRANSLATE_RETRY:
        return "backoff"
    return "translate"


def declared_size(steps: int) -> str:
    return "M" if steps + BOOTLOADER_OVERHEAD <= SIZE_M_MAX else "L"


def contract_address() -> int | None:
    """The deployed `Slingfall` whose programs are checked (M6): `SLINGFALL_ADDRESS`, else
    `deploy/sepolia.json`'s `address` (read only). `None`: the check is skipped."""
    env = os.environ.get("SLINGFALL_ADDRESS")
    if env:
        return int(env, 0)
    if DEFAULT_SEPOLIA_CONFIG.is_file():
        return int(json.loads(DEFAULT_SEPOLIA_CONFIG.read_text())["address"], 0)
    return None


def contract_program(contract: int, program_hash: int) -> dict:
    """Contract v2's view of a program (`STARKNET_RPC_URL`): `program_valid_until(hash)`,
    `current_program()` and the latest block's timestamp (the contract's `now`)."""
    [valid_until] = atlantic.starknet_call(contract, "program_valid_until", [program_hash])
    [current] = atlantic.starknet_call(contract, "current_program", [])
    block = atlantic.rpc("starknet_getBlockWithTxHashes", {"block_id": "latest"})
    return {"current_program": hex(current), "valid_until": valid_until, "now": int(block["timestamp"])}


def contract_satellite(contract: int) -> int:
    """The Satellite of `satellite_config()` (v2: `atlantic_bootloader_hash, sharp_bootloader_hash,
    satellite_address`)."""
    return atlantic.starknet_call(contract, "satellite_config", [])[2]


# --------------------------------------------------------------------------- the run

def c1_input_text(args: list[int]) -> str:
    """`atlantic.py c1-input`: the one-array argument of `cairo1-run --args_file`."""
    return "[" + " ".join(str(x % P) for x in args) + "]\n"


_OUTPUT = re.compile(r"Program Output\s*:\s*(.*)", re.S)


def parse_program_output(text: str) -> list[int]:
    """The felts `cairo1-run --print_output` prints (`Program Output : [a b c]` or one per line)."""
    match = _OUTPUT.search(text)
    if not match:
        raise ProveError(500, "cairo1-run: no 'Program Output' in its output")
    return [int(x) % P for x in re.findall(r"-?\d+", match.group(1))]


def pie_steps(pie: Path) -> int:
    with zipfile.ZipFile(pie) as z:
        return int(json.loads(z.read("execution_resources.json"))["n_steps"])


class Runner:
    """Builds the PIE of one run and its facts. `child_program` is the Sierra's SHA-256 (the job
    key); the bootloader's Pedersen hash of the program is computed once per Sierra file."""

    def __init__(self, cairo1_run: Path, sierra: Path):
        self.cairo1_run = cairo1_run
        self.sierra = sierra
        self._child_hash: dict[str, int] = {}

    def child_program(self) -> str:
        if not self.sierra.is_file():
            raise ProveError(500, f"no Sierra at {self.sierra}: scarb --manifest-path tools/atlantic/c1main/Scarb.toml build")
        return hashlib.sha256(self.sierra.read_bytes()).hexdigest()

    def known_child_program_hash(self) -> int | None:
        """The current Sierra's `child_program_hash`, if a run of this process has already computed
        it (M6): `None` before the first run (the hash comes from a built PIE's program bytes, not
        from the Sierra alone) or when the Sierra is missing."""
        if not self.sierra.is_file():
            return None
        return self._child_hash.get(hashlib.sha256(self.sierra.read_bytes()).hexdigest())

    def child_program_hash(self, pie: Path) -> int:
        key = self.child_program()
        if key not in self._child_hash:
            builtins, main, data = encoding.pie_program(str(pie))
            self._child_hash[key] = encoding.program_hash_pedersen(builtins, main, data)
        return self._child_hash[key]

    def run(self, job_dir: Path, args: list[int]) -> dict:
        """cairo1-run on `c1main`: the PIE, the 10 outputs, the steps and the facts."""
        input_path = job_dir / "input.txt"
        input_path.write_text(c1_input_text(args))
        pie = job_dir / "pie.zip"
        argv = [str(self.cairo1_run), str(self.sierra), "--layout", "all_cairo", "--append_return_values",
                "--cairo_pie_output", str(pie), "--args_file", str(input_path), "--print_output"]
        started = time.time()
        try:
            run = subprocess.run(argv, capture_output=True, text=True, timeout=1800, check=False)
        except OSError as e:
            raise ProveError(500, f"cairo1-run: cannot run {argv[0]}: {e}") from None
        if run.returncode != 0:
            tail = (run.stderr or run.stdout).strip().splitlines()[-3:]
            raise ProveError(500, f"cairo1-run: exit {run.returncode}: {' | '.join(tail)}")
        # `--print_output` prints the returned array; the public output the PIE commits to is
        # `[0, 10, outputs..., len(args), args...]` (`encoding.task_output`, checked by E3a).
        outputs = parse_program_output(run.stdout)
        if len(outputs) != N_OUTPUTS:
            raise ProveError(500, f"cairo1-run: {len(outputs)} output felts, expected {N_OUTPUTS}")
        child = self.child_program_hash(pie)
        facts = encoding.slingfall_fact(child, outputs, args)
        return {
            "outputs": [hex(x) for x in outputs],
            "steps": pie_steps(pie),
            "pie_bytes": pie.stat().st_size,
            "run_seconds": round(time.time() - started, 1),
            "child_program_hash": hex(child),
            "integrity_fact_hash": hex(facts["integrity_fact_hash"]),
            "sharp_fact_hash": hex(facts["sharp_fact_hash"]),
        }


# --------------------------------------------------------------------------- Atlantic, Satellite

def submit_pie(pie: Path, size: str, result: str, dedup_id: str, external_id: str) -> dict:
    """`POST /atlantic-query` (the fields of E3a's successful queries); idempotent by `dedupId`."""
    fields = {"declaredJobSize": size, "layout": "auto", "result": result, "network": "TESTNET",
              "cairoVersion": "cairo1", "cairoVm": "rust", "mockFactHash": "false",
              "externalId": external_id, "dedupId": dedup_id}
    body, ctype = atlantic.multipart(fields, {"pieFile": pie})
    status, data = atlantic._request("POST", atlantic.API + "/atlantic-query", body,
                                     {"api-key": atlantic._env("ATLANTIC_API_KEY"), "Content-Type": ctype}, timeout=1800)
    answer = json.loads(data or b"{}")
    if status == 201:
        return {"query_id": answer["atlanticQueryId"], "reused": False, "fields": fields}
    if answer.get("message") == "ATLANTIC_QUERY_WITH_DEDUP_ID_ALREADY_EXISTS":
        found = atlantic.api_get(f"/atlantic-query-by-dedup-id?dedupId={dedup_id}")
        return {"query_id": found["atlanticQuery"]["id"], "reused": True, "fields": fields}
    raise ProveError(502, f"atlantic submit: HTTP {status}: {data[:300].decode(errors='replace')}")


def atlantic_status(query_id: str) -> dict:
    info = atlantic.summary(atlantic.query_state(query_id))
    return {k: info.get(k) for k in ("status", "step", "jobSize", "integrityFactHash", "sharpFactHash",
                                     "errorReason", "createdAt", "completedAt", "totalSeconds", "stages")}


def satellite_facts(integrity_fact: int, sharp_fact: int, satellite: int = atlantic.SATELLITE_SEPOLIA) -> dict:
    """The two reads `SatelliteVerifier` makes."""
    cairo = atlantic.is_cairo_fact_valid(integrity_fact, satellite)
    keccak = atlantic.is_keccak_fact_valid(sharp_fact, satellite)
    return {"satellite": hex(satellite), "isCairoFactValid": cairo, "isKeccakVerifiedFactHashValid": keccak}


def send_translation(sharp_fact: int, output: list[int]) -> dict:
    """The translator of a service with an account: `atlantic.translate` (checks, one transaction)."""
    return atlantic.translate(sharp_fact, output)


# --------------------------------------------------------------------------- jobs

class Store:
    """`<root>/<id>/job.json`; writes are atomic (rename)."""

    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def dir(self, jid: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{32}", jid):
            raise ProveError(404, "unknown job")
        return self.root / jid

    def load(self, jid: str) -> dict | None:
        path = self.dir(jid) / "job.json"
        return json.loads(path.read_text()) if path.is_file() else None

    def save(self, job: dict) -> dict:
        with self._lock:
            d = self.dir(job["id"])
            d.mkdir(parents=True, exist_ok=True)
            job["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            tmp = d / "job.json.tmp"
            tmp.write_text(json.dumps(job, indent=2) + "\n")
            tmp.replace(d / "job.json")
        return job

    def all(self) -> list[dict]:
        return [json.loads(p.read_text()) for p in sorted(self.root.glob("*/job.json"))]


class Service:
    """Job creation, the worker (one PIE at a time) and the status."""

    def __init__(self, store: Store, runner: Runner, result: str = DEFAULT_RESULT, submit: bool = True,
                 chain: bool = True, submitter=submit_pie, status_of=atlantic_status, facts_of=satellite_facts,
                 translator=None, grace: float = DEFAULT_TRANSLATE_GRACE, clock=time.time,
                 program_of=None, program_ttl: float = 30.0, relayer=None, proven=None):
        """`translator(sharp_fact, output) -> dict` sends `translateFactHash` (None: no account, the
        service only reports the keccak path); `grace` in seconds; `clock` is injectable for tests.
        `program_of(hash) -> {"current_program", "valid_until", "now"}` reads the deployed
        contract's view of a program (`contract_program`; M6; `None`: no contract configured, the
        check never runs), cached for `program_ttl` seconds. `relayer`: a `relay.NodeRelay` (or a
        fake with `address`, `tier`, `simulate`, `send`); `None`: the relay is off. `proven`: a
        `snip36.Snip36`, the SNIP-36 path (contract v3's proven tier); `None`: settled tier only."""
        self.store, self.runner, self.result, self.submit, self.chain = store, runner, result, submit, chain
        self.submitter, self.status_of, self.facts_of = submitter, status_of, facts_of
        self.translator, self.grace, self.clock = translator, grace, clock
        self.program_of, self.program_ttl, self.relayer = program_of, program_ttl, relayer
        self.proven = proven
        self._program_cache: dict[int, tuple[float, dict]] = {}
        self.translate_lock = threading.Lock()
        self.relay_lock = threading.Lock()
        self.queue: queue.Queue[str] = queue.Queue()
        # The SNIP-36 jobs have their own worker: a chain's minutes never wait behind a PIE.
        self.proven_queue: queue.Queue[str] = queue.Queue()

    def program_state(self, program_hash: int | None) -> dict:
        """M6 for one program: `{"contract_program_hash", "program_valid_until", "program_match"}`,
        `program_match` being `valid_until > now` on the contract (the current program, or a former
        one in its grace period). `None` values when unknown: no program yet, no contract
        configured, or the read failed with nothing cached (fail open: only a *known* invalid
        program refuses); a failed read keeps the last known answer."""
        unknown = {"contract_program_hash": None, "program_valid_until": None, "program_match": None}
        if program_hash is None or self.program_of is None:
            return unknown
        now = self.clock()
        cached = self._program_cache.get(program_hash)
        if cached is None or now - cached[0] >= self.program_ttl:
            try:
                self._program_cache[program_hash] = cached = (now, self.program_of(program_hash))
            except Exception:  # noqa: BLE001  (an unreachable RPC never blocks on its own)
                if cached is None:
                    return unknown
        view = cached[1]
        return {"contract_program_hash": view["current_program"], "program_valid_until": view["valid_until"],
                "program_match": view["valid_until"] > view["now"]}

    def check_program_match(self) -> None:
        """M6: refuse a proof the contract will not accept because this service's `c1main` is not
        valid there (re-pinned away past the grace period, or revoked; `docs/proving.md` "Program
        hash history"). Skipped when the service's own hash is not known yet (its very first job) or
        the contract cannot be read: never blocks on uncertainty, only on a confirmed refusal."""
        own = self.runner.known_child_program_hash()
        state = self.program_state(own)
        if state["program_match"] is False:
            raise ProveError(409, f"prove: program mismatch (this service proves {hex(own)}, which the contract "
                                  f"no longer accepts; its current program is {state['contract_program_hash']})",
                             program_hash=hex(own), **state)

    def create(self, level: object, inputs: object, tier: object = "settled") -> tuple[dict, bool]:
        """(job, created). The job is queued when new or not yet submitted. `tier`: `settled`
        (Atlantic, the Satellite) or `proven` (SNIP-36, `snip36`)."""
        if tier not in TIERS:
            raise ProveError(400, f"tier: one of {', '.join(TIERS)}")
        try:
            name, level_hash, felts = resolve_level(level)
            inputs = parse_inputs(inputs)
        except ValueError as e:
            raise ProveError(400, str(e)) from None
        if tier == "proven":
            return self.create_proven(name, level_hash, inputs)
        self.check_program_match()
        jid = job_id(level_hash, inputs, self.runner.child_program(), self.result)
        job = self.store.load(jid)
        if job is not None:
            if self.pending(job) and job["state"] == "built":
                self.queue.put(jid)
            return job, False
        job = self.store.save({
            "id": jid, "state": "queued", "level": name, "level_hash": hex(level_hash),
            "inputs": [hex(x) for x in inputs], "result": self.result, "error": None,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        self.queue.put(jid)
        return job, True

    def create_proven(self, name: str, level_hash: int, inputs: list[int]) -> tuple[dict, bool]:
        """A SNIP-36 job: refused (409) unless the contract's current chain is this service's bundle
        and valid now (the proven tier's program check)."""
        if self.proven is None:
            raise ProveError(400, "tier proven: this service has no SNIP-36 path (serve --snip36 fake|snip36)")
        try:
            view = self.proven.check()
        except snip36.ChainMismatch as e:
            raise ProveError(409, str(e), **e.view) from None
        jid = job_id(level_hash, inputs, self.proven.job_id_key(), "PROVEN")
        job = self.store.load(jid)
        if job is not None:
            if job["state"] == "failed":  # asked again: resume from the stored plan and proofs
                job.update({"state": "queued", "error": None})
                self.proven_queue.put(self.store.save(job)["id"])
            return job, False
        job = self.store.save({
            "id": jid, "tier": "proven", "state": "queued", "level": name, "level_hash": hex(level_hash),
            "inputs": [hex(x) for x in inputs], "chain": view.get("chain"), "error": None,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        self.proven_queue.put(jid)
        return job, True

    def work_proven(self, jid: str) -> dict:
        """Runs one SNIP-36 job to `proven` (or `failed`); resumable from its stored plan and proofs."""
        job = self.store.load(jid)
        if job is None or not self.pending(job):
            return job
        try:
            return self.proven.work(self.store, job, self.store.save)
        except (snip36.Snip36Error, ProveError) as e:
            job = self.store.load(jid) or job
            job["state"], job["error"] = "failed", str(e)
            return self.store.save(job)

    def proven_worker(self) -> None:
        while True:
            jid = self.proven_queue.get()
            try:
                self.work_proven(jid)
            except Exception as e:  # noqa: BLE001  (a worker never dies)
                job = self.store.load(jid) or {"id": jid}
                job["state"], job["error"] = "failed", f"internal: {e}"
                self.store.save(job)
            finally:
                self.proven_queue.task_done()

    def resume(self) -> int:
        """Queues the stored jobs that stopped before their submission (a restart)."""
        n = 0
        for job in self.store.all():
            if self.pending(job):
                if job.get("tier") == "proven":
                    if self.proven is None:
                        continue
                    self.proven_queue.put(job["id"])
                else:
                    self.queue.put(job["id"])
                n += 1
        return n

    def pending(self, job: dict) -> bool:
        """The job still has work: its run, or its submission (a `built` job, submitting now); a
        SNIP-36 job until it is `proven`."""
        if job.get("tier") == "proven":
            return job["state"] in snip36.PENDING
        return job["state"] in ("queued", "running") or (job["state"] == "built" and self.submit)

    def work(self, jid: str) -> dict:
        job = self.store.load(jid)
        if job is None or not self.pending(job):
            return job
        try:
            if job["state"] != "built":
                job["state"] = "running"
                self.store.save(job)
                _, _, level = resolve_level(job["level"])
                args = run_args(level, [int(x, 16) for x in job["inputs"]])
                job["run"] = self.runner.run(self.store.dir(jid), args)
                job["outputs"] = job["run"].pop("outputs")
                if int(job["outputs"][1], 16) != int(job["level_hash"], 16):
                    raise ProveError(500, "the run's level_hash is not the level's")
            if not self.submit:
                job["state"] = "built"
                return self.store.save(job)
            size = declared_size(job["run"]["steps"])
            job["atlantic"] = self.submitter(self.store.dir(jid) / "pie.zip", size, job["result"],
                                             f"slingfall-{jid}", f"slingfall-{job['level']}-{jid[:8]}")
            job["state"] = "submitted"
        except ProveError as e:
            job["state"], job["error"] = "failed", str(e)
        except atlantic.AtlanticError as e:
            job["state"], job["error"] = "failed", f"atlantic: {e}"
        return self.store.save(job)

    def worker(self) -> None:
        while True:
            jid = self.queue.get()
            try:
                self.work(jid)
            except Exception as e:  # noqa: BLE001  (a worker never dies)
                job = self.store.load(jid) or {"id": jid}
                job["state"], job["error"] = "failed", f"internal: {e}"
                self.store.save(job)
            finally:
                self.queue.task_done()

    def observe(self, job: dict) -> tuple[dict | None, dict | None]:
        """(Atlantic's status, the Satellite's answer) of a job; None where unavailable."""
        atl = chain = None
        query = (job.get("atlantic") or {}).get("query_id")
        if query:
            try:
                atl = self.status_of(query)
            except atlantic.AtlanticError as e:
                atl = {"error": str(e)}
        if self.chain and "run" in job:
            try:
                chain = self.facts_of(int(job["run"]["integrity_fact_hash"], 16), int(job["run"]["sharp_fact_hash"], 16))
            except atlantic.AtlanticError as e:
                chain = {"error": str(e)}
        return atl, chain

    def decide(self, job: dict, atl: dict | None, chain: dict | None) -> str:
        """`translation_decision` of a job: Atlantic's `completedAt` starts the grace period (the
        first sighting of a `DONE` query without one)."""
        atl = atl or {}
        now = self.clock()
        done_at = parse_time(atl.get("completedAt")) or (job.get("translation") or {}).get("seen_at")
        return translation_decision(atl.get("status"), done_at, chain, now, self.grace,
                                    self.translator is not None, job.get("translation"))

    def translate_job(self, jid: str, force: bool = False) -> dict:
        """Translates the job's fact if due (`force`: whatever the grace period, the backoff and the
        attempts; the translator still checks that the fact is bridged and not translated). One transaction at most; the
        attempt is recorded in `job["translation"]`. Returns the stored job."""
        with self.translate_lock:
            job = self.store.load(jid)
            if job is None or "run" not in job or (self.translator is None and not force):
                return job
            atl, chain = self.observe(job)
            state = job.get("translation") or {}
            if (atl or {}).get("status") == "DONE" and "seen_at" not in state and not parse_time(atl.get("completedAt")):
                state["seen_at"] = self.clock()
            decision = self.decide({**job, "translation": state}, atl, chain)
            if chain and chain.get("isCairoFactValid") and not state.get("translated"):
                state["translated"] = True
            if decision == "translate" or (force and decision != "translated"):
                if self.translator is None:
                    raise ProveError(500, "translate: no account (STARKNET_ACCOUNT_ADDRESS, STARKNET_PRIVATE_KEY, STARKNET_RPC_URL)")
                state["attempts"] = state.get("attempts", 0) + 1
                state["last_attempt"] = self.clock()
                try:
                    result = self.translator(int(job["run"]["sharp_fact_hash"], 16), job_output(job))
                except (atlantic.AtlanticError, ProveError) as e:
                    state["error"] = str(e)
                else:
                    state.pop("error", None)
                    tx = result.get("transaction") or {}
                    state.update({"translated": bool(result.get("isCairoFactValid", True)), "transaction_hash": tx.get("transaction_hash"),
                                  "gas": tx.get("gas")})
            if state or job.get("translation"):
                job["translation"] = state
                self.store.save(job)
            return job

    def translate_due(self) -> int:
        """One pass of the background thread over the submitted jobs whose fact is not translated yet;
        returns the number of transactions attempted."""
        sent = 0
        for job in self.store.all():
            if job.get("state") != "submitted" or (job.get("translation") or {}).get("translated"):
                continue
            before = (job.get("translation") or {}).get("attempts", 0)
            try:
                after = (self.translate_job(job["id"]) or {}).get("translation") or {}
            except Exception as e:  # noqa: BLE001  (a bad job does not stop the others)
                print(f"prove: translate {job['id']}: {e}", file=sys.stderr, flush=True)
                continue
            sent += after.get("attempts", 0) > before
        return sent

    def translator_loop(self, interval: float = TRANSLATE_INTERVAL) -> None:
        while True:
            try:
                self.translate_due()
            except Exception as e:  # noqa: BLE001  (a thread never dies)
                print(f"prove: translator: {e}", file=sys.stderr, flush=True)
            time.sleep(interval)

    def relay_job(self, jid: str, force: bool = False) -> dict | None:
        """One relay pass over a job (S10): once it is `settleable` and its attempt not settled
        yet, simulate `submit_settled` and send it for `claim.player` (`force`: whatever the
        backoff and the attempts). Recorded in `job["relay"]`: `state` `relayed` (with
        `transaction_hash`, `gas`), `settled` (someone, the player most likely, settled first),
        `gave-up`, or the last `error`. Returns the stored job."""
        with self.relay_lock:
            job = self.store.load(jid)
            if job is None or self.relayer is None or job.get("state") != "submitted" or "run" not in job:
                return job
            state = job.get("relay") or {}
            if state.get("state") in ("relayed", "settled"):
                return job
            if not self.status(jid)["settleable"]:
                return job
            now = self.clock()
            if not force:
                if state.get("attempts", 0) >= relaying.RELAY_ATTEMPTS:
                    return job
                if now - state.get("last_attempt", -relaying.RELAY_RETRY) < relaying.RELAY_RETRY:
                    return job
            stage = "attempt"
            try:
                if self.relayer.tier(job) == relaying.SETTLED:
                    state.update({"state": "settled", "error": None})
                else:
                    state.update({"attempts": state.get("attempts", 0) + 1, "last_attempt": now,
                                  "relayer": self.relayer.address})
                    stage = "simulate"
                    self.relayer.simulate(job)
                    stage = "send"
                    result = self.relayer.send(job)
                    state.update({"state": "relayed", "error": None, "transaction_hash": result.get("transaction_hash"),
                                  "gas": result.get("gas")})
            except relaying.RelayError as e:
                state["error"] = f"{stage}: {e}"
                if state.get("attempts", 0) >= relaying.RELAY_ATTEMPTS:
                    state["state"] = "gave-up"
            job["relay"] = state
            return self.store.save(job)

    def relay_due(self) -> int:
        """One pass of the relay thread over the submitted jobs; returns the transactions sent."""
        sent = 0
        for job in self.store.all():
            if job.get("tier") == "proven" or job.get("state") != "submitted" or (job.get("relay") or {}).get("state") in ("relayed", "settled", "gave-up"):
                continue
            try:
                after = (self.relay_job(job["id"]) or {}).get("relay") or {}
            except Exception as e:  # noqa: BLE001  (a bad job does not stop the others)
                print(f"prove: relay {job['id']}: {e}", file=sys.stderr, flush=True)
                continue
            sent += after.get("state") == "relayed"
        return sent

    def relay_loop(self, interval: float = relaying.RELAY_INTERVAL) -> None:
        while True:
            try:
                self.relay_due()
            except Exception as e:  # noqa: BLE001  (a thread never dies)
                print(f"prove: relay: {e}", file=sys.stderr, flush=True)
            time.sleep(interval)

    def status(self, jid: str) -> dict:
        job = self.store.load(jid)
        if job is None:
            raise ProveError(404, "unknown job")
        if job.get("tier") == "proven":
            if self.proven is None:
                return {**job, "proven": job.get("state") == "proven", "settleable": False}
            return self.proven.status(job)
        answer = dict(job)
        answer["tier"] = "settled"
        answer.update({"settleable": False, "settleable_poseidon": False, "settleable_keccak": False})
        # M6: the job's own program (as proven) must be valid on the contract now; `None`
        # ("unknown") never blocks settling, only a *confirmed* refusal does.
        program_hash = (job.get("run") or {}).get("child_program_hash")
        state = self.program_state(int(program_hash, 16) if program_hash else None)
        program_match = state["program_match"]
        answer["program_hash"] = program_hash
        answer.update(state)
        relay = job.get("relay") or {}
        answer["relay"] = {**relay, "state": relay.get("state", "waiting" if self.relayer else "off")}
        answer["relayed"] = relay.get("state") == "relayed"
        answer["relay_transaction_hash"] = relay.get("transaction_hash")
        atl, chain = self.observe(job)
        if atl is not None:
            answer["atlantic_status"] = atl
        if chain is not None:
            answer["chain"] = chain
            if "isCairoFactValid" in chain:
                gate = program_match is not False
                answer["settleable_poseidon"] = chain["isCairoFactValid"] and gate
                answer["settleable_keccak"] = chain["isKeccakVerifiedFactHashValid"] and gate
                answer["settleable"] = (chain["isCairoFactValid"] or chain["isKeccakVerifiedFactHashValid"]) and gate
                answer["translation"] = {**(job.get("translation") or {}), "state": self.decide(job, atl, chain)}
        return answer


# --------------------------------------------------------------------------- HTTP

def make_handler(service: Service, log=sys.stderr):
    class Handler(BaseHTTPRequestHandler):
        server_version = "slingfall-prove/1"

        def log_message(self, fmt, *args):
            print(f"prove: {self.address_string()} {fmt % args}", file=log)

        def answer(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.cors()
            self.end_headers()
            self.wfile.write(data)

        def cors(self) -> None:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")

        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self.cors()
            self.end_headers()

        def do_GET(self):  # noqa: N802
            try:
                if self.path == "/health":
                    own = service.runner.known_child_program_hash()
                    return self.answer(200, {
                        "result": service.result, "submit": service.submit, "queued": service.queue.qsize(),
                        "program_hash": hex(own) if own is not None else None, **service.program_state(own),
                        "relay": service.relayer.address if service.relayer else None,
                        "tiers": ["settled", "proven"] if service.proven else ["settled"],
                        "proven": service.proven.health() if service.proven else None,
                    })
                if self.path.startswith("/status/"):
                    return self.answer(200, service.status(self.path[len("/status/"):]))
                self.answer(404, {"error": "not found"})
            except ProveError as e:
                self.answer(e.status, {"error": str(e), **e.extra})

        def do_POST(self):  # noqa: N802
            if self.path != "/prove":
                return self.answer(404, {"error": "not found"})
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if not 0 < length <= MAX_BODY:
                    raise ProveError(400 if length <= 0 else 413, "body: missing or too large")
                try:
                    request = json.loads(self.rfile.read(length))
                except ValueError as e:
                    raise ProveError(400, f"body: {e}") from None
                if not isinstance(request, dict):
                    raise ProveError(400, "body: expected a JSON object")
                job, created = service.create(request.get("level"), request.get("inputs"), request.get("tier", "settled"))
                self.answer(202 if created else 200, job)
            except ProveError as e:
                self.answer(e.status, {"error": str(e), **e.extra})

    return Handler


# --------------------------------------------------------------------------- CLI

def make_service(args) -> Service:
    runner = Runner(Path(os.environ.get("PROVE_CAIRO1_RUN", DEFAULT_CAIRO1_RUN)),
                    Path(os.environ.get("PROVE_SIERRA", DEFAULT_SIERRA)))
    grace = getattr(args, "translate_grace", None)
    if grace is None:
        grace = float(os.environ.get("TRANSLATE_GRACE", DEFAULT_TRANSLATE_GRACE))
    # A translator only with an account (`atlantic.account_env`), else the keccak path alone.
    account = atlantic.account_env()
    translator = send_translation if account and not getattr(args, "no_translate", False) else None
    # M6: the program check, unless disabled or no contract can be resolved.
    contract = contract_address()
    checked = None if getattr(args, "no_program_check", False) else contract
    program_of = (lambda h: contract_program(checked, h)) if checked is not None else None
    # The Satellite of the contract's `satellite_config()` (read once), else Herodotus's on Sepolia.
    satellite: list[int] = []

    def facts_of(integrity: int, sharp: int) -> dict:
        if not satellite:
            satellite.append(contract_satellite(contract) if contract is not None else atlantic.SATELLITE_SEPOLIA)
        return satellite_facts(integrity, sharp, satellite[0])

    relayer = None
    if getattr(args, "relay", False):
        if account is None or contract is None:
            sys.exit("prove: --relay needs an account (STARKNET_ACCOUNT_ADDRESS, STARKNET_PRIVATE_KEY, "
                     "STARKNET_RPC_URL) and a contract (SLINGFALL_ADDRESS)")
        relayer = relaying.NodeRelay(contract, account)
    return Service(Store(Path(args.store)), runner, args.result, submit=not args.no_submit,
                   chain=not getattr(args, "no_chain", False), facts_of=facts_of, translator=translator,
                   grace=grace, program_of=program_of, relayer=relayer, proven=make_proven(args, account, contract))


def make_proven(args, account: dict | None, contract: int | None) -> snip36.Snip36 | None:
    """The SNIP-36 path (`--snip36 fake|snip36`): the account of the environment simulates the chain,
    sends the proofs and `finalize` (a relay); the contract's `current_chain()` is the chain proven."""
    kind = getattr(args, "snip36", None)
    if kind is None:
        return None
    if account is None or contract is None:
        sys.exit("prove: --snip36 needs an account (STARKNET_ACCOUNT_ADDRESS, STARKNET_PRIVATE_KEY, "
                 "STARKNET_RPC_URL) and a contract (SLINGFALL_ADDRESS)")
    rpc = snip36.Rpc(account["STARKNET_RPC"])
    runner = snip36.ChainRunner(rpc, int(account["SLINGFALL_ACCOUNT_ADDRESS"], 16))
    chain = snip36.NodeChain(contract, account)
    if kind == "fake":
        prover = snip36.FakeProver(rpc, runner)
    else:
        url = args.prover_url or os.environ.get("PROVE_SNIP36_URL")
        if not url:
            sys.exit("prove: --snip36 snip36 needs --prover-url (or PROVE_SNIP36_URL): a starknet_proveTransaction endpoint")
        prover = snip36.Snip36Prover(url, rpc, chain.sign_virtual)
    bundle = snip36.own_bundle()
    return snip36.Snip36(runner, prover, chain, lambda: snip36.chain_state(rpc, contract, bundle), bundle,
                         level_felts=lambda name: resolve_level(name)[2], budget=args.budget, parallel=args.parallel)


def watch(service: Service, jid: str, interval: float) -> dict:
    """Polls until the fact is on the Satellite or Atlantic fails."""
    while True:
        status = service.status(jid)
        atl = status.get("atlantic_status") or {}
        stages = ", ".join(f"{s['job']} {s['status']}" for s in atl.get("stages") or [])
        print(f"{time.strftime('%H:%M:%S')} {status['state']} atlantic {atl.get('status')} [{stages}] "
              f"settleable {status['settleable']} (poseidon {status['settleable_poseidon']}, "
              f"keccak {status['settleable_keccak']})", file=sys.stderr, flush=True)
        if status["settleable"] or status["state"] in ("failed", "built") or atl.get("status") == "FAILED":
            return status
        time.sleep(interval)


def cmd_serve(args) -> int:
    service = make_service(args)
    resumed = service.resume()
    threading.Thread(target=service.worker, daemon=True).start()
    if service.proven is not None:
        threading.Thread(target=service.proven_worker, daemon=True).start()
    if service.translator is not None:
        threading.Thread(target=service.translator_loop, daemon=True).start()
    if service.relayer is not None:
        threading.Thread(target=service.relay_loop, daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(service))
    print(f"prove: listening on http://{args.host}:{server.server_address[1]} (store {args.store}, "
          f"result {args.result}, submit {not args.no_submit}, {resumed} job(s) resumed, translation "
          f"{'after ' + str(int(service.grace)) + ' s' if service.translator else 'off (no account or --no-translate)'}, "
          f"program check {'against ' + hex(contract_address()) if service.program_of else 'off (--no-program-check or no contract configured)'}, "
          f"relay {'from ' + service.relayer.address if service.relayer else 'off'}, "
          f"SNIP-36 {'prover ' + service.proven.prover.name if service.proven else 'off'})",
          file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def cmd_prove(args) -> int:
    service = make_service(args)
    if args.inputs:
        inputs = args.inputs.split(",")
    else:
        from_shots = [felt % P for felt in [int(args.player, 0), len(args.shot)]]
        for px, py, delay in args.shot:
            from_shots += [px % P, py % P, delay, 0]
        inputs = [hex(x) for x in from_shots]
    if args.tier == "proven":
        job, _ = service.create(args.level, inputs, "proven")
        if service.pending(job):
            service.work_proven(job["id"])
        status = service.status(job["id"])
        print(json.dumps(status, indent=2))
        return 0 if status["state"] == "proven" else 1
    job, _ = service.create(args.level, inputs)
    job = service.work(job["id"]) if service.pending(job) else job
    print(json.dumps(job, indent=2))
    if job["state"] == "failed":
        return 1
    if args.watch:
        print(json.dumps(watch(service, job["id"], args.interval), indent=2))
    return 0


def cmd_status(args) -> int:
    service = make_service(args)
    status = watch(service, args.job, args.interval) if args.watch else service.status(args.job)
    print(json.dumps(status, indent=2))
    return 0


def cmd_translate(args) -> int:
    service = make_service(args)
    if args.dry_run:
        job = service.store.load(args.job)
        if job is None or "run" not in job:
            raise ProveError(404, "unknown or unbuilt job")
        result = atlantic.translate(int(job["run"]["sharp_fact_hash"], 16), job_output(job), send=False)
    else:
        if service.translator is None:
            print("prove: translate: no account (STARKNET_ACCOUNT_ADDRESS, STARKNET_PRIVATE_KEY, STARKNET_RPC_URL)", file=sys.stderr)
            return 1
        job = service.translate_job(args.job, force=True)
        result = (job or {}).get("translation") or {}
        if result.get("error"):
            print(json.dumps(result, indent=2))
            return 1
    print(json.dumps(result, indent=2))
    return 0


def cmd_relay(args) -> int:
    args.relay = True
    service = make_service(args)
    job = service.relay_job(args.job, force=True)
    if job is None:
        raise ProveError(404, "unknown job")
    status = service.status(args.job)
    print(json.dumps({"relay": status["relay"], "relayed": status["relayed"], "settleable": status["settleable"],
                      "program_match": status["program_match"]}, indent=2))
    return 0 if status["relay"]["state"] in ("relayed", "settled") else 1


def parse_shot(text: str) -> tuple[int, int, int]:
    parts = [int(p) for p in text.split(",")]
    if len(parts) not in (2, 3):
        raise argparse.ArgumentTypeError(f"shot {text!r}: PX,PY[,DELAY]")
    return parts[0], parts[1], parts[2] if len(parts) == 3 else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--store", default=str(DEFAULT_STORE))
    common.add_argument("--result", default=DEFAULT_RESULT, choices=RESULTS)
    common.add_argument("--no-submit", action="store_true", help="build the PIE and the facts only")
    common.add_argument("--no-program-check", action="store_true",
                        help="skip the satellite_config() match check against the deployed contract (M6)")
    common.add_argument("--snip36", choices=("fake", "snip36"),
                        help="the SNIP-36 path (contract v3's proven tier) with this prover: fake (devnet) or snip36")
    common.add_argument("--prover-url", help="starknet_proveTransaction endpoint of --snip36 snip36 (or PROVE_SNIP36_URL)")
    common.add_argument("--budget", type=int, default=snip36.DEFAULT_BUDGET,
                        help=f"L2 gas per proven transaction (default {snip36.DEFAULT_BUDGET:,})")
    common.add_argument("--parallel", type=int, default=4, help="proofs in flight (default 4)")

    p = sub.add_parser("serve", parents=[common], help="run the HTTP service")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8549)
    p.add_argument("--no-translate", action="store_true", help="never send translateFactHash (keccak path only)")
    p.add_argument("--translate-grace", type=float, help=f"seconds to wait for Atlantic's translation "
                   f"(default $TRANSLATE_GRACE or {int(DEFAULT_TRANSLATE_GRACE)})")
    p.add_argument("--relay", action="store_true", help="send submit_settled for the player once settleable "
                   "(the account of the environment pays)")
    p.set_defaults(run=cmd_serve)

    p = sub.add_parser("prove", parents=[common], help="one job in the foreground")
    p.add_argument("--level", required=True, help="a fixtures/levels name or a level hash")
    p.add_argument("--inputs", help="the Inputs felts, comma-separated")
    p.add_argument("--player", default="0x706c61796572")
    p.add_argument("--shot", type=parse_shot, action="append", default=[])
    p.add_argument("--watch", action="store_true")
    p.add_argument("--interval", type=float, default=300)
    p.add_argument("--tier", choices=TIERS, default="settled", help="proven: the SNIP-36 path (needs --snip36)")
    p.set_defaults(run=cmd_prove)

    p = sub.add_parser("status", parents=[common], help="a stored job, Atlantic and the Satellite")
    p.add_argument("job")
    p.add_argument("--watch", action="store_true")
    p.add_argument("--interval", type=float, default=300)
    p.add_argument("--no-chain", action="store_true", help="skip the Satellite reads")
    p.set_defaults(run=cmd_status)

    p = sub.add_parser("translate", parents=[common], help="translate one job's fact on the Satellite now")
    p.add_argument("job")
    p.add_argument("--dry-run", action="store_true", help="check only, send nothing")
    p.set_defaults(run=cmd_translate)

    p = sub.add_parser("relay", parents=[common], help="relay one job's submit_settled now")
    p.add_argument("job")
    p.set_defaults(run=cmd_relay)

    args = parser.parse_args(argv)
    if args.cmd == "prove" and not args.inputs and not args.shot:
        parser.error("prove: --inputs or at least one --shot")
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
