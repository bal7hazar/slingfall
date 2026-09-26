#!/usr/bin/env python3
"""atlantic: prove a Slingfall run with Herodotus Atlantic, get its fact onto Starknet Sepolia, read the
fact back (lot E3a, `docs/proving.md` "Atlantic + Integrity"). Python 3 standard library.

    atlantic.py c1-input --args ARGS.json --out INPUT.txt
    atlantic.py submit (--pie PIE.zip | --program P.json [--input I.txt]) [--layout auto] [--size S]
                       [--result PROOF_VERIFICATION_ON_L2] [--network TESTNET]
                       [--prover stwo] [--record FILE] [--json]
    atlantic.py status <query-id> [--watch [--interval 30]] [--json]
    atlantic.py fact <query-id> [--golden fixtures/golden/<case>.json --args ARGS.json] [--json]
    atlantic.py check-fact <fact-hash> [--keccak SHARP_FACT] [--registry both|fact-registry|satellite]
                           [--min-bits 96] [--json]
    atlantic.py program-hash --pie PIE.zip [--json]
    atlantic.py fact-hash --golden GOLDEN.json --args ARGS.json --child-hash H [--json]

`c1-input` turns `tracec.py args` felts into the one-array input text of `cairo1-run` (the program is
`tools/atlantic/c1main`, the PIE comes from `cairo1-run --append_return_values --cairo_pie_output`).
`fact` reads the query and its `metadata.json` (program hashes, output, facts) and re-derives both
facts from them (`encoding.py`); with `--golden` / `--args` it also checks that the proven output is
our run's. `check-fact` reads Integrity's FactRegistry and Herodotus's Satellite (the registry Atlantic
writes to) with `starknet_call`: verifications (security bits, settings), `isCairoFactValid`, and the
bridged keccak fact. `program-hash` recomputes the bootloader's (Pedersen) hash of a PIE's program.

Environment (never printed): `ATLANTIC_API_KEY` (header `api-key`) for `submit` / `status` / `fact`;
`STARKNET_RPC_URL` for `check-fact` (JSON-RPC 0.8+; a `User-Agent` is always sent, the public node
answers 403 without one). No transaction is ever sent: `check-fact` only calls view functions.

`submit` is idempotent: the `dedupId` is derived from the files' SHA-256 and the request fields, so a
second identical submit returns the first query id (`ATLANTIC_QUERY_WITH_DEDUP_ID_ALREADY_EXISTS`).
`--record FILE` writes the request fields (never the key) and the query id as JSON.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import encoding  # noqa: E402

API = "https://atlantic.api.herodotus.cloud"
USER_AGENT = "slingfall/1.0"
# Integrity `deployed_contracts.md` / `src/lib_utils.cairo` (main, 2026-09-26), Starknet Sepolia.
FACT_REGISTRY_SEPOLIA = 0x4CE7851F00B6C3289674841FD7A1B96B6FD41ED1EDC248FACCD672C26371B8C
SATELLITE_SEPOLIA = 0x00421CD95F9DDABDD090DB74C9429F257CB6BC1CCC339278D1DB1DE39156676E
SECURITY_BITS_MIN = 96  # docs/DESIGN.md D9, research 01 §2; the Satellite's ALLOWED_SECURITY_BITS


class AtlanticError(Exception):
    pass


# --------------------------------------------------------------------------- HTTP

def _env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise AtlanticError(f"{name} is not set")
    return value


def _request(method: str, url: str, body: bytes | None = None, headers: dict | None = None,
             timeout: float = 600) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, method=method, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()


def api_get(path: str) -> dict:
    status, data = _request("GET", API + path, headers={"api-key": _env("ATLANTIC_API_KEY")}, timeout=60)
    if status != 200:
        raise AtlanticError(f"GET {path}: HTTP {status}: {data[:500].decode(errors='replace')}")
    return json.loads(data)


def multipart(fields: dict[str, str], files: dict[str, Path]) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    for name, path in files.items():
        mime = {".zip": "application/zip", ".json": "application/json"}.get(path.suffix, "text/plain")
        head = (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{path.name}"\r\n'
                f"Content-Type: {mime}\r\n\r\n").encode()
        parts += [head, path.read_bytes(), b"\r\n"]
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def rpc(method: str, params) -> object:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    status, data = _request("POST", _env("STARKNET_RPC_URL"), body, {"Content-Type": "application/json"}, 60)
    if status != 200:
        raise AtlanticError(f"RPC {method}: HTTP {status}: {data[:300].decode(errors='replace')}")
    answer = json.loads(data)
    if "error" in answer:
        raise AtlanticError(f"RPC {method}: {answer['error']}")
    return answer["result"]


def starknet_call(contract: int, entry_point: str, calldata: list[int]) -> list[int]:
    result = rpc("starknet_call", {
        "request": {"contract_address": hex(contract), "entry_point_selector": hex(encoding.selector(entry_point)),
                    "calldata": [hex(x) for x in calldata]},
        "block_id": "latest",
    })
    return [int(x, 16) for x in result]


# --------------------------------------------------------------------------- submit / status

def submit_fields(args) -> tuple[dict[str, str], dict[str, Path]]:
    fields = {
        "declaredJobSize": args.size,
        "layout": args.layout,
        "result": args.result,
        "network": args.network,
        "cairoVersion": args.cairo_version,
        "cairoVm": "rust",
        "mockFactHash": "true" if args.mock_fact else "false",
    }
    if args.prover:
        fields["sharpProver"] = args.prover
    if args.external_id:
        fields["externalId"] = args.external_id
    files: dict[str, Path] = {}
    if args.pie:
        files["pieFile"] = Path(args.pie)
    else:
        files["programFile"] = Path(args.program)
        if args.input:
            files["inputFile"] = Path(args.input)
    digest = hashlib.sha256()
    for name in sorted(files):
        digest.update(name.encode() + hashlib.sha256(files[name].read_bytes()).digest())
    digest.update(json.dumps(fields, sort_keys=True).encode())
    fields["dedupId"] = "slingfall-" + digest.hexdigest()[:40]
    return fields, files


def cmd_submit(args) -> dict:
    fields, files = submit_fields(args)
    body, ctype = multipart(fields, files)
    status, data = _request("POST", API + "/atlantic-query", body,
                            {"api-key": _env("ATLANTIC_API_KEY"), "Content-Type": ctype}, timeout=1800)
    answer = json.loads(data or b"{}")
    reused = False
    if status == 201:
        query_id = answer["atlanticQueryId"]
    elif answer.get("message") == "ATLANTIC_QUERY_WITH_DEDUP_ID_ALREADY_EXISTS":
        query_id = api_get(f"/atlantic-query-by-dedup-id?dedupId={fields['dedupId']}")["atlanticQuery"]["id"]
        reused = True
    else:
        raise AtlanticError(f"submit: HTTP {status}: {data[:800].decode(errors='replace')}")
    record = {
        "atlanticQueryId": query_id,
        "reused": reused,
        "request": {"endpoint": "POST /atlantic-query (multipart/form-data, header api-key)", "fields": fields,
                    "files": {k: {"name": v.name, "bytes": v.stat().st_size,
                                  "sha256": hashlib.sha256(v.read_bytes()).hexdigest()} for k, v in files.items()}},
        "submittedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if args.record:
        Path(args.record).write_text(json.dumps(record, indent=2) + "\n")
    return record


def query_state(query_id: str) -> dict:
    query = api_get(f"/atlantic-query/{query_id}")
    jobs = api_get(f"/atlantic-query-jobs/{query_id}")
    return {"query": query["atlanticQuery"], "metadataUrls": query.get("metadataUrls", []),
            "jobs": jobs.get("jobs", []), "steps": jobs.get("steps", [])}


def _seconds(start: str | None, end: str | None) -> float | None:
    if not start or not end:
        return None
    parse = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))  # noqa: E731
    return round((parse(end) - parse(start)).total_seconds(), 1)


def stages(state: dict) -> list[dict]:
    return [{"job": j["jobName"], "status": j["status"], "createdAt": j["createdAt"], "completedAt": j["completedAt"],
             "seconds": _seconds(j["createdAt"], j["completedAt"])}
            for j in sorted(state["jobs"], key=lambda j: j["createdAt"])]


def summary(state: dict) -> dict:
    q = state["query"]
    keys = ["id", "status", "step", "steps", "layout", "chain", "network", "sharpProver", "cairoVersion", "jobSize",
            "declaredJobSize", "isJobSizeValid", "programHash", "integrityFactHash", "sharpFactHash",
            "isFactMocked", "isProofMocked", "transactionId", "errorReason", "createdAt", "completedAt"]
    return {**{k: q.get(k) for k in keys}, "totalSeconds": _seconds(q.get("createdAt"), q.get("completedAt")),
            "stages": stages(state)}


def cmd_status(args) -> dict:
    seen: dict[str, str] = {}
    while True:
        info = summary(query_state(args.query))
        if args.watch and not args.json:
            for st in info["stages"]:
                if seen.get(st["job"]) != st["status"]:
                    seen[st["job"]] = st["status"]
                    stamp = st["completedAt"] or st["createdAt"]
                    print(f"{stamp}  {st['job']:<36} {st['status']:<12} {st['seconds'] or ''}", flush=True)
        if not args.watch or info["status"] in ("DONE", "FAILED"):
            return info
        time.sleep(args.interval)


# --------------------------------------------------------------------------- facts

def _load_felts(path: str) -> list[int]:
    return [int(x, 0) if isinstance(x, str) else int(x) for x in json.loads(Path(path).read_text())]


def _metadata(state: dict) -> tuple[dict | None, list[dict]]:
    files, meta = [], None
    for url in state["metadataUrls"]:
        name = url.split("?")[0].rsplit("/", 1)[-1]
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                size = int(resp.headers.get("Content-Length") or 0) or None
        except urllib.error.URLError:
            size = None
        files.append({"name": name, "bytes": size})
        if name == "metadata.json":
            status, data = _request("GET", url, timeout=120)
            meta = json.loads(data) if status == 200 else None
    return meta, files


def cmd_fact(args) -> dict:
    state = query_state(args.query)
    q = state["query"]
    info = {k: q.get(k) for k in ("id", "status", "layout", "chain", "network", "sharpProver", "jobSize",
                                  "programHash", "integrityFactHash", "sharpFactHash", "isFactMocked",
                                  "transactionId")}
    meta, info["files"] = _metadata(state)
    if meta is None:
        return info
    out = [int(x, 16) for x in meta["output"]]
    boot, child = int(meta["program_hash"], 16), int(meta["child_program_hash"], 16)
    info.update({"bootloader_program_hash": hex(boot), "child_program_hash": hex(child),
                 "bootloaded_steps": meta["execution_resources"]["n_steps"], "output_felts": len(out),
                 "optimal_layouts": meta.get("optimal_layouts")})
    checks = {
        "sharp_fact = keccak(bootloader, keccak(output))":
            hex(encoding.sharp_fact_hash(boot, out)) == meta["sharp_fact_hash"],
        "integrity_fact = bootloaded(SHARP_BOOTLOADER, bootloader, output)":
            hex(encoding.translated_fact_hash(boot, out)) == meta["integrity_fact_hash"],
        "bootloader = ATLANTIC_BOOTLOADER_PROGRAM_HASH": boot == encoding.ATLANTIC_BOOTLOADER_PROGRAM_HASH,
    }
    if args.golden and args.args:
        outputs = [int(x, 16) for x in json.loads(Path(args.golden).read_text())["outputs"]]
        expected = encoding.atlantic_output(child, encoding.task_output(outputs, _load_felts(args.args)))
        checks["output = [0, pedersen(0,0), 1, n+2, child, 0, 10, outputs, len(args), args]"] = out == expected
    info["checks"] = checks
    return info


def _verifications(contract: int, fact: int, mocked: list[int]) -> list[dict]:
    felts = starknet_call(contract, "get_all_verifications_for_fact_hash", [fact, *mocked])
    out = encoding.decode_verifications(felts)
    for v in out:
        if v["layout"] != "translated":
            config = encoding.verifier_config_hash(v["layout"], v["hasher"], v["stone_version"], v["memory_verification"])
            v["verification_hash_recomputed"] = hex(encoding.verification_hash(fact, config, v["security_bits"]))
    return out


def cmd_check_fact(args) -> dict:
    fact = int(args.fact_hash, 0)
    result: dict = {"fact_hash": hex(fact), "registries": {}}
    if args.registry in ("both", "fact-registry"):
        result["registries"]["fact_registry"] = {
            "address": hex(FACT_REGISTRY_SEPOLIA), "verifications": _verifications(FACT_REGISTRY_SEPOLIA, fact, [])}
    if args.registry in ("both", "satellite"):
        sat = {"address": hex(SATELLITE_SEPOLIA), "is_mocked": False,
               "verifications": _verifications(SATELLITE_SEPOLIA, fact, [0]),
               "isCairoFactValid": starknet_call(SATELLITE_SEPOLIA, "isCairoFactValid", [fact, 0]) == [1]}
        if args.keccak:
            k = int(args.keccak, 0)
            sat["isKeccakVerifiedFactHashValid"] = starknet_call(
                SATELLITE_SEPOLIA, "isKeccakVerifiedFactHashValid", [k & ((1 << 128) - 1), k >> 128]) == [1]
        result["registries"]["satellite"] = sat
    best = max((v["security_bits"] for r in result["registries"].values() for v in r["verifications"]), default=0)
    result["max_security_bits"] = best
    result["ok"] = best >= args.min_bits
    return result


def cmd_program_hash(args) -> dict:
    builtins, main, data = encoding.pie_program(args.pie)
    return {"program_hash_pedersen": hex(encoding.program_hash_pedersen(builtins, main, data)),
            "builtins": builtins, "main": main, "data_felts": len(data)}


def cmd_fact_hash(args) -> dict:
    outputs = [int(x, 16) for x in json.loads(Path(args.golden).read_text())["outputs"]]
    facts = encoding.slingfall_fact(int(args.child_hash, 0), outputs, _load_felts(args.args))
    return {k: hex(v) for k, v in facts.items()}


def cmd_c1_input(args) -> dict:
    felts = _load_felts(args.args)
    Path(args.out).write_text("[" + " ".join(str(x % encoding.P) for x in felts) + "]\n")
    return {"felts": len(felts), "out": args.out}


# --------------------------------------------------------------------------- CLI

def _print(value: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, indent=2))
        return
    for key, val in value.items():
        if isinstance(val, (list, dict)):
            print(f"{key}:")
            for item in (val if isinstance(val, list) else [f"{k}: {v}" for k, v in val.items()]):
                print(f"  {item}")
        else:
            print(f"{key}: {val}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("c1-input", help="tracec.py args felts -> cairo1-run input text")
    p.add_argument("--args", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_c1_input)
    p = sub.add_parser("submit", help="submit a PIE (or program + input) to Atlantic")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--pie")
    src.add_argument("--program")
    p.add_argument("--input")
    p.add_argument("--layout", default="auto")
    p.add_argument("--size", default="M", choices=["XS", "S", "M", "L"])
    # `..._WITH_TRANSLATION` stalled after trace generation on 2026-09-26 (docs/proving.md).
    p.add_argument("--result", default="PROOF_VERIFICATION_ON_L2")
    p.add_argument("--network", default="TESTNET", choices=["TESTNET", "MAINNET"])
    p.add_argument("--cairo-version", default="cairo1", choices=["cairo0", "cairo1"])
    p.add_argument("--prover", help="sharpProver (omitted: Atlantic's default, stwo)")
    p.add_argument("--mock-fact", action="store_true")
    p.add_argument("--external-id")
    p.add_argument("--record")
    p.set_defaults(func=cmd_submit)
    p = sub.add_parser("status", help="query status and stage timings")
    p.add_argument("query")
    p.add_argument("--watch", action="store_true")
    p.add_argument("--interval", type=float, default=30)
    p.set_defaults(func=cmd_status)
    p = sub.add_parser("fact", help="program hashes, output and facts of a query, re-derived")
    p.add_argument("query")
    p.add_argument("--golden", help="fixtures/golden/<case>.json: the run's 10 outputs")
    p.add_argument("--args", help="the run's argument felts (tracec.py args)")
    p.set_defaults(func=cmd_fact)
    p = sub.add_parser("check-fact", help="read a fact's verifications on Sepolia (FactRegistry, Satellite)")
    p.add_argument("fact_hash")
    p.add_argument("--keccak", help="the SHARP (keccak) fact bridged to the Satellite")
    p.add_argument("--registry", default="both", choices=["both", "fact-registry", "satellite"])
    p.add_argument("--min-bits", type=int, default=SECURITY_BITS_MIN)
    p.set_defaults(func=cmd_check_fact)
    p = sub.add_parser("program-hash", help="the bootloader's Pedersen program hash of a PIE's program")
    p.add_argument("--pie", required=True)
    p.set_defaults(func=cmd_program_hash)
    p = sub.add_parser("fact-hash", help="the facts of a run of c1main, computed offline")
    p.add_argument("--golden", required=True)
    p.add_argument("--args", required=True)
    p.add_argument("--child-hash", required=True)
    p.set_defaults(func=cmd_fact_hash)
    for sp in sub.choices.values():
        sp.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = args.func(args)
    except AtlanticError as error:
        sys.exit(f"atlantic: {error}")
    _print(result, args.json)
    if args.cmd == "check-fact" and not result["ok"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
