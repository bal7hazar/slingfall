#!/usr/bin/env python3
"""attest: the attestation service of the `StubVerifier` path (docs/DESIGN.md D9, research 01 §4
rank 2). Python 3 standard library only.

    attest.py serve [--key HEX] (--verify-cmd CMD | --no-verify) [--host H] [--port N]
                    [--proof-dir DIR] [--timeout S]
    attest.py sign [--key HEX] (--outputs FILE | FELT...)
    attest.py pubkey [--key HEX]
    attest.py request --url URL (--outputs FILE | FELT...) [--proof-path PATH | --proof FILE]

The key is the attestation secret (a Stark-curve scalar); without `--key` it is read from the
environment variable `SLINGFALL_ATTEST_KEY` (a command line is visible to every user of the
machine). The contract checks the signature with the public key the admin set
(`set_attestation_key`, `attest.py pubkey`).

`serve`: HTTP on `--host:--port` (default 127.0.0.1:8547).

* `POST /attest` `{"outputs": [10 felts], "proof_path": "..."}` (or `"proof": "<base64>"`): runs the
  verify command on the proof and the claimed outputs; when it exits 0, signs
  `attestation_hash = poseidon_hash_span(outputs)` (the contract's `verifier::attestation_hash`)
  and answers `{"attestation_hash", "signature": [r, s], "public_key", "verified"}`: `[r, s]` is the
  `evidence` of `submit`. A failed verification answers 422, a malformed request 400.
* `GET /health`: `{"public_key", "verify"}`.

The verify command is P1's `tools/prove/verify.py`: `<CMD> <proof> <outputs.json>` (the outputs
written as a JSON array of `0x` felts), exit 0 when the proof verifies and its public output is the
claimed outputs. `{proof}` / `{outputs}` in CMD place the two paths explicitly. One verification
runs at a time. `--no-verify` signs whatever it is sent (a devnet without a prover): it warns at
start and every answer says `"verified": false`. Never expose a `--no-verify` service.

`proof_path` names a file on the service's machine (the MVP proves and attests on one machine);
`--proof-dir` restricts it to one directory. Felts are read as decimal or `0x` hexadecimal.

`sign` prints the hash and the signature of the given outputs (offline attestation); `request`
posts to a running service and prints its answer (the client of `deploy/e2e.sh`).
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import shlex
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "crates" / "slingfall_contract" / "tools"))
import vectors  # noqa: E402  (Stark curve, ECDSA, and Poseidon of tools/levelc)

P = vectors.P
N_OUTPUTS = 10  # the felts of `Outputs` (docs/DESIGN.md D4)
KEY_ENV = "SLINGFALL_ATTEST_KEY"
MAX_BODY = 64 << 20  # a base64 proof; P1's proofs are a few MB


class AttestError(Exception):
    """A request the service refuses; `status` is the HTTP status of the answer."""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


# --------------------------------------------------------------------------- attestation

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


def parse_key(text: str | None) -> int:
    text = text if text is not None else os.environ.get(KEY_ENV)
    if not text:
        raise SystemExit(f"no key: pass --key or set {KEY_ENV}")
    key = int(text, 0)
    if not 0 < key < vectors.N:
        raise SystemExit("key: out of range (0, N)")
    return key


def attestation_hash(outputs: list[int]) -> int:
    """`verifier::attestation_hash`: `poseidon_hash_span(outputs felts)`."""
    return vectors.hash_span(outputs)


def attest(secret: int, outputs: list[int]) -> dict:
    """The attestation of `outputs`: hash, signature `[r, s]` (checked as the contract does)."""
    z = attestation_hash(outputs)
    r, s = vectors.sign(secret, z)
    public_key = vectors.pubkey(secret)
    assert vectors.verify(z, public_key, r, s)
    return {"attestation_hash": hex(z), "signature": [hex(r), hex(s)], "public_key": hex(public_key)}


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


# --------------------------------------------------------------------------- HTTP

def make_handler(secret: int, verifier: Verifier, log=sys.stderr):
    public_key = hex(vectors.pubkey(secret))

    class Handler(BaseHTTPRequestHandler):
        server_version = "slingfall-attest/1"

        def log_message(self, fmt, *args):
            print(f"attest: {self.address_string()} {fmt % args}", file=log)

        def answer(self, status: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.cors()
            self.end_headers()
            self.wfile.write(data)

        def cors(self) -> None:
            # The client runs on another origin (the Vite dev server).
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")

        def do_OPTIONS(self):  # noqa: N802
            self.send_response(204)
            self.cors()
            self.end_headers()

        def do_GET(self):  # noqa: N802
            if self.path != "/health":
                return self.answer(404, {"error": "not found"})
            self.answer(200, {"public_key": public_key, "verify": verifier.command})

        def do_POST(self):  # noqa: N802
            if self.path != "/attest":
                return self.answer(404, {"error": "not found"})
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if not 0 < length <= MAX_BODY:
                    raise AttestError(400 if length <= 0 else 413, "body: missing or too large")
                try:
                    request = json.loads(self.rfile.read(length))
                    if not isinstance(request, dict):
                        raise ValueError("expected a JSON object")
                    outputs = parse_outputs(request.get("outputs"))
                except ValueError as e:
                    raise AttestError(400, str(e)) from None
                verified = verifier.check(request, outputs)
                body = {**attest(secret, outputs), "verified": verified}
                print(f"attest: signed {body['attestation_hash']} (verified {verified})", file=log)
                self.answer(200, body)
            except AttestError as e:
                print(f"attest: refused ({e.status}): {e}", file=log)
                self.answer(e.status, {"error": str(e)})

    return Handler


def serve(secret: int, verifier: Verifier, host: str, port: int) -> ThreadingHTTPServer:
    return ThreadingHTTPServer((host, port), make_handler(secret, verifier))


# --------------------------------------------------------------------------- CLI

def read_outputs(args) -> list[int]:
    if args.outputs:
        doc = json.loads(Path(args.outputs).read_text())
        return parse_outputs(doc["outputs"] if isinstance(doc, dict) else doc)
    return parse_outputs(args.felts)


def cmd_serve(args) -> int:
    secret = parse_key(args.key)
    if args.no_verify == bool(args.verify_cmd):
        sys.exit("serve: pass exactly one of --verify-cmd and --no-verify")
    if args.no_verify:
        print("attest: WARNING --no-verify: signing ANY outputs without a proof. Devnet only; "
              "never expose this service.", file=sys.stderr)
    verifier = Verifier(args.verify_cmd, Path(args.proof_dir) if args.proof_dir else None, args.timeout)
    server = serve(secret, verifier, args.host, args.port)
    host, port = server.server_address[:2]
    print(f"attest: public key {hex(vectors.pubkey(secret))}", file=sys.stderr)
    print(f"attest: listening on http://{host}:{port} (verify: {args.verify_cmd or 'NONE'})", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def cmd_sign(args) -> int:
    print(json.dumps(attest(parse_key(args.key), read_outputs(args)), indent=2))
    return 0


def cmd_pubkey(args) -> int:
    print(hex(vectors.pubkey(parse_key(args.key))))
    return 0


def cmd_request(args) -> int:
    body: dict = {"outputs": [hex(v) for v in read_outputs(args)]}
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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    def outputs_args(p):
        p.add_argument("--outputs", help="JSON file: a list of 10 felts, or {\"outputs\": [...]}")
        p.add_argument("felts", nargs="*", help="the 10 output felts")

    p = sub.add_parser("serve", help="run the HTTP service")
    p.add_argument("--key", help=f"attestation secret (default: ${KEY_ENV})")
    p.add_argument("--verify-cmd", help="command verifying <proof> <outputs.json> (P1's tools/prove/verify.py)")
    p.add_argument("--no-verify", action="store_true", help="sign without a proof (devnet only)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8547)
    p.add_argument("--proof-dir", help="proof_path must be inside this directory")
    p.add_argument("--timeout", type=float, default=900.0, help="verify command timeout, seconds")
    p.set_defaults(run=cmd_serve)

    p = sub.add_parser("sign", help="sign outputs offline")
    p.add_argument("--key")
    outputs_args(p)
    p.set_defaults(run=cmd_sign)

    p = sub.add_parser("pubkey", help="print the public key to set_attestation_key")
    p.add_argument("--key")
    p.set_defaults(run=cmd_pubkey)

    p = sub.add_parser("request", help="POST /attest to a running service")
    p.add_argument("--url", default="http://127.0.0.1:8547")
    p.add_argument("--proof-path")
    p.add_argument("--proof", help="a proof file sent inline (base64)")
    p.add_argument("--timeout", type=float, default=960.0)
    outputs_args(p)
    p.set_defaults(run=cmd_request)

    args = parser.parse_args(argv)
    return args.run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
