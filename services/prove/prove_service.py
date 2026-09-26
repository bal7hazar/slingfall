#!/usr/bin/env python3
"""prove_service: the prover service of the settled tier (lot E3b, `docs/DESIGN.md` D9,
`docs/proving.md` "Atlantic + Integrity"). Python 3 standard library; reuses `tools/atlantic`.

    prove_service.py serve [--host H] [--port N] [--store DIR] [--result R] [--no-submit]
                           [--no-translate] [--translate-grace SECONDS]
    prove_service.py prove (--level NAME|HASH) (--inputs FELT,... | --player FELT --shot PX,PY[,D]...)
                           [--store DIR] [--result R] [--no-submit] [--watch [--interval S]]
    prove_service.py status <job-id> [--store DIR] [--watch [--interval S]] [--no-chain]
    prove_service.py translate <job-id> [--store DIR] [--dry-run]

`serve`: HTTP on `--host:--port` (default 127.0.0.1:8549).

* `POST /prove` `{"level": "<name or level_hash>", "inputs": [felts]}` (the `Serde` felts of the
  `Inputs`): creates (or finds) the job and answers it at once (`202`); a worker builds the PIE
  (`c1main` under `cairo1-run` of the patched fork, as `atlantic.py c1-input` + the E3a
  command), checks the run's outputs, computes the facts (`encoding.slingfall_fact`) and submits
  the PIE to Atlantic (`declaredJobSize` by the run's steps, `dedupId` = the job id). One PIE at a
  time.
* `GET /status/<id>`: the job, Atlantic's status and stages, and the Satellite's answer for its
  facts (`isCairoFactValid` / `isKeccakVerifiedFactHashValid`): `"settleable_poseidon"` (the
  translated fact: the cheap `submit_settled`), `"settleable_keccak"` (the bridged keccak fact
  only: the dearer one) and `"settleable"` (either: `submit_settled(outputs, inputs)` would pass),
  and `"translation"`: what the service does about the Poseidon fact (below).
* `GET /health`.

Translation (lot E3c). Atlantic's `PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION` stalled (E3a, E3b),
so the queries ask for `PROOF_VERIFICATION_ON_L2`, which ends with the keccak fact bridged to the
Satellite. When Atlantic's status is `DONE` and the translated (Poseidon) fact is still absent
after `TRANSLATE_GRACE` seconds (default 600; env or `--translate-grace`), a background thread
of `serve` calls the Satellite's permissionless `translateFactHash` itself (`atlantic.translate`,
one transaction from the account of the environment: `STARKNET_ACCOUNT_ADDRESS` +
`STARKNET_PRIVATE_KEY` + `STARKNET_RPC_URL`, or `SLINGFALL_*`; at most 3 attempts, 10 minutes
apart). Without an account (or with `--no-translate`) the service only reports
`settleable_keccak`. `translate <job>` translates one job now, grace or not.

The job id is `sha256(level_hash, inputs, child program, result)`: the same attempt maps to the
same job and the same Atlantic query (retries are idempotent). Jobs live in `--store`
(`<store>/<id>/job.json`, the PIE and the run's input next to it); a restarted service resumes
the jobs whose PIE was not submitted yet.

`prove` runs the same pipeline in the foreground (the Sepolia deployment's first settled submit);
`status` reads a stored job. `--no-submit` stops after the PIE and the facts (tests, dry runs).

Environment (never printed): `ATLANTIC_API_KEY` (submit, status), `STARKNET_RPC_URL` (the
Satellite's reads), the account of the translations (above). Paths: `PROVE_CAIRO1_RUN` (default the fork build of `docs/proving.md`,
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

P = encoding.P
LEVELS = ROOT / "fixtures" / "levels"
DEFAULT_STORE = ROOT / "services" / "prove" / "out"
DEFAULT_CAIRO1_RUN = ROOT / "tools" / "atlantic" / "out" / "starkware-cairo-vm" / "target" / "release" / "cairo1-run"
DEFAULT_SIERRA = ROOT / "tools" / "atlantic" / "c1main" / "target" / "dev" / "c1main.sierra.json"
# The result that completes today (E3a); `..._WITH_TRANSLATION` stalled after trace generation on
# 2026-09-26 (`docs/proving.md`) and is accepted by `--result`.
DEFAULT_RESULT = "PROOF_VERIFICATION_ON_L2"
RESULTS = ("PROOF_VERIFICATION_ON_L2", "PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION")
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
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


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
    * `waiting`: Atlantic is not `DONE`, or the keccak fact is not on the Satellite yet;
    * `grace`: keccak fact bridged, Atlantic's own translation may still come (`done_at` + `grace`);
    * `no-account`: due, but there is no account to send the transaction from (keccak path only);
    * `gave-up`: `TRANSLATE_ATTEMPTS` transactions failed;
    * `backoff`: the last attempt is less than `TRANSLATE_RETRY` seconds old;
    * `translate`: send `translateFactHash` now."""
    translation = translation or {}
    if not chain or "isCairoFactValid" not in chain:
        return "unknown"
    if chain["isCairoFactValid"]:
        return "translated"
    if atlantic_status != "DONE" or not chain["isKeccakVerifiedFactHashValid"]:
        return "waiting"
    if done_at is None or now - done_at < grace:
        return "grace"
    if not has_account:
        return "no-account"
    if translation.get("attempts", 0) >= TRANSLATE_ATTEMPTS:
        return "gave-up"
    if now - translation.get("last_attempt", -TRANSLATE_RETRY) < TRANSLATE_RETRY:
        return "backoff"
    return "translate"


def declared_size(steps: int) -> str:
    return "M" if steps + BOOTLOADER_OVERHEAD <= SIZE_M_MAX else "L"


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
                 translator=None, grace: float = DEFAULT_TRANSLATE_GRACE, clock=time.time):
        """`translator(sharp_fact, output) -> dict` sends `translateFactHash` (None: no account, the
        service only reports the keccak path); `grace` in seconds; `clock` is injectable for tests."""
        self.store, self.runner, self.result, self.submit, self.chain = store, runner, result, submit, chain
        self.submitter, self.status_of, self.facts_of = submitter, status_of, facts_of
        self.translator, self.grace, self.clock = translator, grace, clock
        self.translate_lock = threading.Lock()
        self.queue: queue.Queue[str] = queue.Queue()

    def create(self, level: object, inputs: object) -> tuple[dict, bool]:
        """(job, created). The job is queued when new or not yet submitted."""
        try:
            name, level_hash, felts = resolve_level(level)
            inputs = parse_inputs(inputs)
        except ValueError as e:
            raise ProveError(400, str(e)) from None
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

    def resume(self) -> int:
        """Queues the stored jobs that stopped before their submission (a restart)."""
        n = 0
        for job in self.store.all():
            if self.pending(job):
                self.queue.put(job["id"])
                n += 1
        return n

    def pending(self, job: dict) -> bool:
        """The job still has work: its run, or its submission (a `built` job, submitting now)."""
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

    def status(self, jid: str) -> dict:
        job = self.store.load(jid)
        if job is None:
            raise ProveError(404, "unknown job")
        answer = dict(job)
        answer.update({"settleable": False, "settleable_poseidon": False, "settleable_keccak": False})
        atl, chain = self.observe(job)
        if atl is not None:
            answer["atlantic_status"] = atl
        if chain is not None:
            answer["chain"] = chain
            if "isCairoFactValid" in chain:
                answer["settleable_poseidon"] = chain["isCairoFactValid"]
                answer["settleable_keccak"] = chain["isKeccakVerifiedFactHashValid"]
                answer["settleable"] = chain["isCairoFactValid"] or chain["isKeccakVerifiedFactHashValid"]
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
                    return self.answer(200, {"result": service.result, "submit": service.submit,
                                             "queued": service.queue.qsize()})
                if self.path.startswith("/status/"):
                    return self.answer(200, service.status(self.path[len("/status/"):]))
                self.answer(404, {"error": "not found"})
            except ProveError as e:
                self.answer(e.status, {"error": str(e)})

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
                job, created = service.create(request.get("level"), request.get("inputs"))
                self.answer(202 if created else 200, job)
            except ProveError as e:
                self.answer(e.status, {"error": str(e)})

    return Handler


# --------------------------------------------------------------------------- CLI

def make_service(args) -> Service:
    runner = Runner(Path(os.environ.get("PROVE_CAIRO1_RUN", DEFAULT_CAIRO1_RUN)),
                    Path(os.environ.get("PROVE_SIERRA", DEFAULT_SIERRA)))
    grace = getattr(args, "translate_grace", None)
    if grace is None:
        grace = float(os.environ.get("TRANSLATE_GRACE", DEFAULT_TRANSLATE_GRACE))
    # A translator only with an account (`atlantic.account_env`), else the keccak path alone.
    translator = send_translation if atlantic.account_env() and not getattr(args, "no_translate", False) else None
    return Service(Store(Path(args.store)), runner, args.result, submit=not args.no_submit,
                   chain=not getattr(args, "no_chain", False), translator=translator, grace=grace)


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
    if service.translator is not None:
        threading.Thread(target=service.translator_loop, daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(service))
    print(f"prove: listening on http://{args.host}:{server.server_address[1]} (store {args.store}, "
          f"result {args.result}, submit {not args.no_submit}, {resumed} job(s) resumed, translation "
          f"{'after ' + str(int(service.grace)) + ' s' if service.translator else 'off (no account or --no-translate)'})",
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

    p = sub.add_parser("serve", parents=[common], help="run the HTTP service")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8549)
    p.add_argument("--no-translate", action="store_true", help="never send translateFactHash (keccak path only)")
    p.add_argument("--translate-grace", type=float, help=f"seconds to wait for Atlantic's translation "
                   f"(default $TRANSLATE_GRACE or {int(DEFAULT_TRANSLATE_GRACE)})")
    p.set_defaults(run=cmd_serve)

    p = sub.add_parser("prove", parents=[common], help="one job in the foreground")
    p.add_argument("--level", required=True, help="a fixtures/levels name or a level hash")
    p.add_argument("--inputs", help="the Inputs felts, comma-separated")
    p.add_argument("--player", default="0x706c61796572")
    p.add_argument("--shot", type=parse_shot, action="append", default=[])
    p.add_argument("--watch", action="store_true")
    p.add_argument("--interval", type=float, default=300)
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

    args = parser.parse_args(argv)
    if args.cmd == "prove" and not args.inputs and not args.shot:
        parser.error("prove: --inputs or at least one --shot")
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
