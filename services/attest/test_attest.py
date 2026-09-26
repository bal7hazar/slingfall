#!/usr/bin/env python3
"""Tests of attest.py: `python3 -m unittest discover -s services/attest` (standard library only).

The golden vector is read from the contract's own fixtures (`src/submit/fixtures.cairo`), so the
service signs exactly what `StubVerifier` accepts in the Cairo tests."""

from __future__ import annotations

import base64
import io
import json
import re
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import attest  # noqa: E402

FIXTURES = attest.ROOT / "crates" / "slingfall_contract" / "src" / "submit" / "fixtures.cairo"
PILE10 = attest.ROOT / "fixtures" / "levels" / "pile10.felts.json"


def cairo_constants() -> dict[str, int]:
    """`pub const NAME: felt252 = 0x...;` (or a short string) of fixtures.cairo."""
    text = FIXTURES.read_text()
    found = {}
    for name, value in re.findall(r"pub const (\w+): felt252 =\s*([^;]+);", text):
        value = value.strip()
        found[name] = int.from_bytes(value[1:-1].encode(), "big") if value.startswith("'") else int(value, 0)
    return found


CONST = cairo_constants()
PILE10_HASH = int(json.loads(PILE10.read_text())["level_hash"], 16)
# `fixtures::golden_claim()`.
GOLDEN = [1, PILE10_HASH, 0, CONST["PLAYER"], 0xABC, 1650, 1, 2, 431, 0x33]
TRUE_CMD = f"{sys.executable} -c 'import sys; sys.exit(0)'"
FALSE_CMD = f"{sys.executable} -c 'import sys; print(\"outputs differ\", file=sys.stderr); sys.exit(3)'"
# Checks it got `<proof> <outputs.json>`, the outputs as `0x` felts, and a proof with `PROOF`.
CHECK_CMD = (f"{sys.executable} -c 'import json, sys; "
             "proof, outputs = sys.argv[1:]; "
             "assert open(proof).read() == \"PROOF\"; "
             "assert all(v.startswith(\"0x\") for v in json.load(open(outputs))); "
             "sys.exit(0)'")


class GoldenTest(unittest.TestCase):
    def test_attestation_hash_is_the_contracts(self):
        self.assertEqual(attest.attestation_hash(GOLDEN), CONST["GOLDEN_ATTESTATION_HASH"])

    def test_signature_is_the_contracts_golden(self):
        got = attest.attest(CONST["SECRET"], GOLDEN)
        self.assertEqual(got["public_key"], hex(CONST["ATTESTATION_KEY"]))
        self.assertEqual(got["attestation_hash"], hex(CONST["GOLDEN_ATTESTATION_HASH"]))
        self.assertEqual(got["signature"], [hex(CONST["GOLDEN_R"]), hex(CONST["GOLDEN_S"])])

    def test_signature_verifies_and_binds_every_felt(self):
        key = CONST["ATTESTATION_KEY"]
        got = attest.attest(CONST["SECRET"], GOLDEN)
        r, s = (int(v, 16) for v in got["signature"])
        for i in range(len(GOLDEN)):
            other = list(GOLDEN)
            other[i] = (other[i] + 1) % attest.P
            self.assertFalse(attest.vectors.verify(attest.attestation_hash(other), key, r, s), i)


class ParseTest(unittest.TestCase):
    def test_felts(self):
        cases = [("0x10", 16), ("16", 16), (16, 16), (hex(attest.P - 1), attest.P - 1)]
        for text, expected in cases:
            self.assertEqual(attest.parse_felt(text), expected)
        for bad in [hex(attest.P), "-1", -1, "x", None, True, 1.5]:
            with self.assertRaises(ValueError, msg=repr(bad)):
                attest.parse_felt(bad)

    def test_outputs_length(self):
        for bad in [GOLDEN[:9], GOLDEN + [0], "0x1", None]:
            with self.assertRaises(ValueError):
                attest.parse_outputs(bad)


class VerifierTest(unittest.TestCase):
    def test_argv(self):
        v = attest.Verifier("python3 verify.py --quiet", None, 1)
        self.assertEqual(v.argv(Path("/p"), Path("/o")), ["python3", "verify.py", "--quiet", "/p", "/o"])
        v = attest.Verifier("verify --outputs={outputs} {proof}", None, 1)
        self.assertEqual(v.argv(Path("/p"), Path("/o")), ["verify", "--outputs=/o", "/p"])

    def test_proof_dir(self):
        with tempfile.TemporaryDirectory() as allowed, tempfile.NamedTemporaryFile() as outside:
            v = attest.Verifier(TRUE_CMD, Path(allowed), 10)
            with self.assertRaises(attest.AttestError) as e:
                v.check({"proof_path": outside.name}, GOLDEN)
            self.assertEqual(e.exception.status, 400)


class ServiceTest(unittest.TestCase):
    """The HTTP service on an ephemeral port, one per verify command."""

    def start(self, command: str | None) -> str:
        log = io.StringIO()
        handler = attest.make_handler(CONST["SECRET"], attest.Verifier(command, None, 30), log)
        server = attest.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def post(self, url: str, body) -> tuple[int, dict]:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        request = urllib.request.Request(url + "/attest", data=data, method="POST",
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as r:
                self.assertEqual(r.headers["Access-Control-Allow-Origin"], "*")
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_signs_after_the_verify_command(self):
        url = self.start(CHECK_CMD)
        proof = base64.b64encode(b"PROOF").decode()
        status, body = self.post(url, {"outputs": [hex(v) for v in GOLDEN], "proof": proof})
        self.assertEqual(status, 200, body)
        self.assertTrue(body["verified"])
        self.assertEqual(body["signature"], [hex(CONST["GOLDEN_R"]), hex(CONST["GOLDEN_S"])])
        # Decimal felts and a proof path are accepted too.
        with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            f.write("PROOF")
            f.flush()
            status, again = self.post(url, {"outputs": [str(v) for v in GOLDEN], "proof_path": f.name})
        self.assertEqual((status, again["signature"]), (200, body["signature"]))

    def test_rejected_proof_is_422(self):
        url = self.start(FALSE_CMD)
        status, body = self.post(url, {"outputs": GOLDEN, "proof": base64.b64encode(b"x").decode()})
        self.assertEqual(status, 422)
        self.assertIn("outputs differ", body["error"])
        self.assertNotIn("signature", body)

    def test_bad_requests_are_400(self):
        url = self.start(TRUE_CMD)
        cases = [
            {"outputs": GOLDEN},  # no proof
            {"outputs": GOLDEN, "proof": "not base64!"},
            {"outputs": GOLDEN, "proof_path": "/nonexistent/proof.json"},
            {"outputs": GOLDEN[:9], "proof": ""},
            {"outputs": [hex(attest.P)] * 10, "proof": ""},
            [1, 2],
            b"{not json",
        ]
        for body in cases:
            status, answer = self.post(url, body)
            self.assertEqual(status, 400, (body, answer))
            self.assertIn("error", answer)

    def test_no_verify_signs_without_a_proof(self):
        url = self.start(None)
        status, body = self.post(url, {"outputs": GOLDEN})
        self.assertEqual(status, 200)
        self.assertFalse(body["verified"])
        self.assertEqual(body["signature"], [hex(CONST["GOLDEN_R"]), hex(CONST["GOLDEN_S"])])

    def test_health(self):
        url = self.start(TRUE_CMD)
        with urllib.request.urlopen(url + "/health", timeout=10) as r:
            body = json.loads(r.read())
        self.assertEqual(body, {"public_key": hex(CONST["ATTESTATION_KEY"]), "verify": TRUE_CMD})


class CliTest(unittest.TestCase):
    def test_sign_and_pubkey(self):
        out = io.StringIO()
        sys_stdout, sys.stdout = sys.stdout, out
        try:
            attest.main(["sign", "--key", hex(CONST["SECRET"]), *map(hex, GOLDEN)])
            attest.main(["pubkey", "--key", hex(CONST["SECRET"])])
        finally:
            sys.stdout = sys_stdout
        text = out.getvalue()
        signed = json.loads(text[: text.rindex("}") + 1])
        self.assertEqual(signed["signature"], [hex(CONST["GOLDEN_R"]), hex(CONST["GOLDEN_S"])])
        self.assertEqual(text.strip().splitlines()[-1], hex(CONST["ATTESTATION_KEY"]))


if __name__ == "__main__":
    unittest.main()
