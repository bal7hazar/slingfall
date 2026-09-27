#!/usr/bin/env python3
"""Tests of attest.py: `python3 -m unittest discover -s services/attest` (standard library only).

The golden vector is read from the contract's own fixtures (`src/submit/fixtures.cairo`,
`GOLDEN_ATTEST_*`), so the service signs exactly what `AttestationVerifier` accepts in the Cairo
tests. The chain, the replay and the verify command are fakes."""

from __future__ import annotations

import argparse
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
    """`pub const NAME: felt252 | u64 = 0x...;` (or a short string) of fixtures.cairo."""
    text = FIXTURES.read_text()
    found = {}
    for name, value in re.findall(r"pub const (\w+): (?:felt252|u64) =\s*([^;]+);", text):
        value = value.strip()
        found[name] = int.from_bytes(value[1:-1].encode(), "big") if value.startswith("'") else int(value.replace("_", ""), 0)
    return found


CONST = cairo_constants()
PILE10_HASH = int(json.loads(PILE10.read_text())["level_hash"], 16)
# `fixtures::golden_claim()`.
GOLDEN = [1, PILE10_HASH, 0, CONST["PLAYER"], 0xABC, 1650, 1, 2, 431, 0x33]
# The v2 vector's context: chain, contract, program, epoch, expiry.
CHAIN_ID, CONTRACT = CONST["ATTEST_CHAIN_ID"], CONST["MESSAGE_FROM"]
PROGRAM, EPOCH, EXPIRY = CONST["E3A_CHILD_PROGRAM_HASH"], CONST["ATTEST_EPOCH"], CONST["ATTEST_EXPIRY"]
GOLDEN_EVIDENCE = [hex(PROGRAM), hex(EXPIRY), hex(CONST["GOLDEN_ATTEST_R"]), hex(CONST["GOLDEN_ATTEST_S"])]
TTL = 600
# The golden inputs of an --execute request: the player of the claim, one shot.
INPUTS = [hex(CONST["PLAYER"]), "0x1", hex(-604 % attest.P), hex(-392 % attest.P), "0x0", "0x0"]
TRUE_CMD = f"{sys.executable} -c 'import sys; sys.exit(0)'"
FALSE_CMD = f"{sys.executable} -c 'import sys; print(\"outputs differ\", file=sys.stderr); sys.exit(3)'"
# Checks it got `<proof> <outputs.json>`, the outputs as `0x` felts, and a proof with `PROOF`.
CHECK_CMD = (f"{sys.executable} -c 'import json, sys; "
             "proof, outputs = sys.argv[1:]; "
             "assert open(proof).read() == \"PROOF\"; "
             "assert all(v.startswith(\"0x\") for v in json.load(open(outputs))); "
             "sys.exit(0)'")


class FakeRpc:
    """`starknet_chainId`, `starknet_call` (`current_program`, `attestation_epoch`) and the latest
    block's timestamp; counts the calls."""

    def __init__(self):
        self.values = {"current_program": PROGRAM, "attestation_epoch": EPOCH}
        self.now = EXPIRY - TTL
        self.calls: list[str] = []
        self.down = False

    def __call__(self, method: str, params):
        if self.down:
            raise OSError("connection refused")
        if method == "starknet_chainId":
            self.calls.append(method)
            return hex(CHAIN_ID)
        if method == "starknet_getBlockWithTxHashes":
            self.calls.append("now")
            return {"timestamp": self.now}
        assert method == "starknet_call" and params["request"]["contract_address"] == hex(CONTRACT), params
        selector = int(params["request"]["entry_point_selector"], 16)
        name = next(n for n in self.values if attest.encoding.selector(n) == selector)
        self.calls.append(name)
        return [hex(self.values[name])]


class GoldenTest(unittest.TestCase):
    def test_message_and_signature_are_the_contracts_golden(self):
        got = attest.attest(CONST["SECRET"], CHAIN_ID, CONTRACT, PROGRAM, EPOCH, EXPIRY, GOLDEN)
        self.assertEqual(got["public_key"], hex(CONST["ATTESTATION_KEY"]))
        self.assertEqual(got["message"], hex(CONST["GOLDEN_ATTEST_MESSAGE"]))
        self.assertEqual(got["evidence"], GOLDEN_EVIDENCE)
        self.assertEqual(got["signature"], GOLDEN_EVIDENCE[2:])

    def test_every_field_is_committed(self):
        key = CONST["ATTESTATION_KEY"]
        r, s = CONST["GOLDEN_ATTEST_R"], CONST["GOLDEN_ATTEST_S"]
        context = [CHAIN_ID, CONTRACT, PROGRAM, EPOCH, EXPIRY]
        for i in range(len(context)):
            other = list(context)
            other[i] += 1
            z = attest.vectors.attestation_message(*other, GOLDEN)
            self.assertFalse(attest.vectors.verify(z, key, r, s), i)
        for i in range(len(GOLDEN)):
            other = list(GOLDEN)
            other[i] = (other[i] + 1) % attest.P
            self.assertFalse(attest.vectors.verify(attest.vectors.attestation_message(*context, other), key, r, s), i)


class ParseTest(unittest.TestCase):
    def test_felts(self):
        cases = [("0x10", 16), ("16", 16), (16, 16), (hex(attest.P - 1), attest.P - 1)]
        for text, expected in cases:
            self.assertEqual(attest.parse_felt(text), expected)
        for bad in [hex(attest.P), "-1", -1, "x", None, True, 1.5]:
            with self.assertRaises(ValueError, msg=repr(bad)):
                attest.parse_felt(bad)

    def test_outputs_and_inputs(self):
        for bad in [GOLDEN[:9], GOLDEN + [0], "0x1", None]:
            with self.assertRaises(ValueError):
                attest.parse_outputs(bad)
        self.assertEqual(len(attest.parse_inputs(INPUTS)), 6)
        for bad in [INPUTS[:5], [INPUTS[0], "0x6", *["0x0"] * 24], "x", [1]]:
            with self.assertRaises(ValueError):
                attest.parse_inputs(bad)

    def test_chain_id(self):
        self.assertEqual(attest.parse_chain_id("SN_SEPOLIA"), CHAIN_ID)
        self.assertEqual(attest.parse_chain_id(hex(CHAIN_ID)), CHAIN_ID)

    def test_levels_by_name_or_hash(self):
        self.assertEqual(attest.resolve_level("pile10"), "pile10")
        self.assertEqual(attest.resolve_level(hex(PILE10_HASH)), "pile10")
        for bad in ["nope", "0x1", 7]:
            with self.assertRaises(ValueError):
                attest.resolve_level(bad)


class ChainTest(unittest.TestCase):
    def test_reads_and_caches_for_the_ttl(self):
        rpc, clock = FakeRpc(), [0.0]
        chain = attest.Chain(CONTRACT, rpc, clock=lambda: clock[0])
        self.assertEqual(chain.context(), {"chain_id": CHAIN_ID, "program_hash": PROGRAM, "epoch": EPOCH, "now": EXPIRY - TTL})
        self.assertEqual(len(rpc.calls), 4)
        chain.context()
        self.assertEqual(len(rpc.calls), 4)  # cached
        # A rotation (the epoch bumps) is seen once the cache is older than the TTL.
        rpc.values["attestation_epoch"] = EPOCH + 1
        clock[0] = attest.CHAIN_TTL
        self.assertEqual(chain.context()["epoch"], EPOCH + 1)
        self.assertEqual(chain.known(), {"chain_id": hex(CHAIN_ID), "program_hash": hex(PROGRAM), "epoch": EPOCH + 1})

    def test_fixed_values_are_never_read(self):
        rpc = FakeRpc()
        chain = attest.Chain(CONTRACT, rpc, chain_id=CHAIN_ID, program_hash=PROGRAM + 1, epoch=7)
        self.assertEqual(chain.context()["program_hash"], PROGRAM + 1)
        self.assertEqual(rpc.calls, ["now"])

    def test_now_is_the_later_of_the_block_and_the_wall_clock(self):
        rpc = FakeRpc()
        self.assertEqual(attest.Chain(CONTRACT, rpc, clock=lambda: rpc.now + 50).context()["now"], rpc.now + 50)
        self.assertEqual(attest.Chain(CONTRACT, rpc, clock=lambda: 0).context()["now"], rpc.now)

    def test_no_rpc_uses_the_wall_clock_and_needs_fixed_values(self):
        chain = attest.Chain(CONTRACT, None, chain_id=CHAIN_ID, program_hash=PROGRAM, epoch=EPOCH, clock=lambda: 42.9)
        self.assertEqual(chain.context()["now"], 42)
        with self.assertRaises(attest.AttestError) as e:
            attest.Chain(CONTRACT, None).get("epoch")
        self.assertEqual(e.exception.status, 500)

    def test_an_unreachable_rpc_refuses(self):
        rpc = FakeRpc()
        rpc.down = True
        with self.assertRaises(attest.AttestError) as e:
            attest.Chain(CONTRACT, rpc).context()
        self.assertEqual(e.exception.status, 503)


class RateLimiterTest(unittest.TestCase):
    def test_sliding_window_per_key(self):
        clock = [0.0]
        limiter = attest.RateLimiter(2, 10, clock=lambda: clock[0])
        self.assertEqual([limiter.allow(1), limiter.allow(1), limiter.allow(1), limiter.allow(2)], [True, True, False, True])
        clock[0] = 9.9
        self.assertFalse(limiter.allow(1))
        clock[0] = 10.0
        self.assertTrue(limiter.allow(1))
        self.assertTrue(attest.RateLimiter(0, 10).allow(1))  # 0: no limit


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
    """The HTTP service on an ephemeral port over a fake chain; the golden context, so the
    signatures are the golden ones."""

    def setUp(self):
        self.rpc = FakeRpc()
        self.runs: list[tuple] = []
        self.replay_outputs = list(GOLDEN)

    def replay(self, level, inputs):
        self.runs.append((level, inputs))
        return self.replay_outputs

    def start(self, command: str | None = None, execute: bool = False, rate: int = 20) -> str:
        chain = attest.Chain(CONTRACT, self.rpc, clock=lambda: 0.0)
        executor = attest.Executor(self.replay) if execute else None
        attester = attest.Attester(CONST["SECRET"], chain, executor, attest.Verifier(command, None, 30),
                                   attest.RateLimiter(rate, 3600), ttl=TTL)
        server = attest.ThreadingHTTPServer(("127.0.0.1", 0), attest.make_handler(attester, io.StringIO()))
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

    def test_execute_signs_the_replays_outputs(self):
        url = self.start(execute=True)
        status, body = self.post(url, {"level": "pile10", "inputs": INPUTS})
        self.assertEqual(status, 200, body)
        self.assertEqual(self.runs, [("pile10", [int(x, 16) for x in INPUTS])])
        self.assertEqual((body["mode"], body["verified"]), ("execute", True))
        self.assertEqual(body["outputs"], [hex(v) for v in GOLDEN])
        self.assertEqual(body["evidence"], GOLDEN_EVIDENCE)
        self.assertEqual((body["epoch"], body["expiry"], body["chain_id"]), (EPOCH, EXPIRY, hex(CHAIN_ID)))
        # Claimed outputs that match are fine (by level hash too); one differing felt is refused.
        status, _ = self.post(url, {"level": hex(PILE10_HASH), "inputs": INPUTS, "outputs": [hex(v) for v in GOLDEN]})
        self.assertEqual(status, 200)
        claimed = list(GOLDEN)
        claimed[5] = 9999
        status, body = self.post(url, {"level": "pile10", "inputs": INPUTS, "outputs": claimed})
        self.assertEqual(status, 422)
        self.assertIn("score", body["error"])
        self.assertNotIn("evidence", body)

    def test_execute_refusals(self):
        url = self.start(execute=True)
        for body in [{"level": "nope", "inputs": INPUTS}, {"level": "pile10", "inputs": INPUTS[:5]},
                     {"level": "pile10"}, {"inputs": INPUTS}, [1], b"{not json"]:
            status, answer = self.post(url, body)
            self.assertEqual(status, 400, (body, answer))
        self.replay_outputs = GOLDEN[:9]
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": INPUTS})[0], 500)

    def test_the_epoch_and_program_come_from_the_contract(self):
        url = self.start(execute=True)
        self.rpc.values.update(attestation_epoch=EPOCH + 1, current_program=PROGRAM + 5)
        _, body = self.post(url, {"level": "pile10", "inputs": INPUTS})
        self.assertEqual((body["epoch"], body["program_hash"]), (EPOCH + 1, hex(PROGRAM + 5)))
        z = attest.vectors.attestation_message(CHAIN_ID, CONTRACT, PROGRAM + 5, EPOCH + 1, EXPIRY, GOLDEN)
        self.assertEqual(body["message"], hex(z))
        self.assertEqual(body["evidence"][:2], [hex(PROGRAM + 5), hex(EXPIRY)])

    def test_rate_limit_per_player(self):
        url = self.start(execute=True, rate=2)
        other = [hex(CONST["PLAYER"] + 1), *INPUTS[1:]]
        answers = [self.post(url, {"level": "pile10", "inputs": INPUTS})[0] for _ in range(3)]
        self.assertEqual(answers, [200, 200, 429])
        self.assertEqual(len(self.runs), 2)  # the refused request never ran
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": other})[0], 200)

    def test_verify_cmd_signs_after_the_command(self):
        url = self.start(CHECK_CMD)
        proof = base64.b64encode(b"PROOF").decode()
        status, body = self.post(url, {"outputs": [hex(v) for v in GOLDEN], "proof": proof})
        self.assertEqual(status, 200, body)
        self.assertEqual((body["verified"], body["mode"], body["evidence"]), (True, "verify", GOLDEN_EVIDENCE))
        with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            f.write("PROOF")
            f.flush()
            status, again = self.post(url, {"outputs": [str(v) for v in GOLDEN], "proof_path": f.name})
        self.assertEqual((status, again["evidence"]), (200, GOLDEN_EVIDENCE))

    def test_rejected_proof_is_422(self):
        url = self.start(FALSE_CMD)
        status, body = self.post(url, {"outputs": GOLDEN, "proof": base64.b64encode(b"x").decode()})
        self.assertEqual(status, 422)
        self.assertIn("outputs differ", body["error"])

    def test_bad_verify_requests_are_400(self):
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
        self.assertEqual((body["verified"], body["mode"], body["evidence"]), (False, "none", GOLDEN_EVIDENCE))

    def test_an_unreachable_rpc_refuses_503(self):
        url = self.start(None)
        self.rpc.down = True
        status, body = self.post(url, {"outputs": GOLDEN})
        self.assertEqual(status, 503)
        self.assertIn("chain", body["error"])

    def test_health(self):
        url = self.start(TRUE_CMD)
        self.post(url, {"outputs": GOLDEN, "proof": base64.b64encode(b"x").decode()})
        with urllib.request.urlopen(url + "/health", timeout=10) as r:
            body = json.loads(r.read())
        self.assertEqual(body, {"public_key": hex(CONST["ATTESTATION_KEY"]), "mode": "verify", "verify": TRUE_CMD,
                                "contract": hex(CONTRACT), "chain_id": hex(CHAIN_ID), "program_hash": hex(PROGRAM),
                                "epoch": EPOCH})


class CliTest(unittest.TestCase):
    def run_main(self, argv: list[str]) -> str:
        out = io.StringIO()
        sys_stdout, sys.stdout = sys.stdout, out
        try:
            attest.main(argv)
        finally:
            sys.stdout = sys_stdout
        return out.getvalue()

    def test_sign_and_pubkey(self):
        text = self.run_main(["sign", "--key", hex(CONST["SECRET"]), "--chain-id", "SN_SEPOLIA", "--contract", hex(CONTRACT),
                              "--program-hash", hex(PROGRAM), "--epoch", str(EPOCH), "--expiry", str(EXPIRY),
                              *map(hex, GOLDEN)])
        self.assertEqual(json.loads(text)["evidence"], GOLDEN_EVIDENCE)
        self.assertEqual(self.run_main(["pubkey", "--key", hex(CONST["SECRET"])]).strip(), hex(CONST["ATTESTATION_KEY"]))

    def test_serve_needs_exactly_one_mode(self):
        for modes in [[], ["--execute", "--no-verify"], ["--no-verify", "--verify-cmd", "x"]]:
            with self.assertRaises(SystemExit):
                attest.make_attester(argparse.Namespace(
                    key=hex(CONST["SECRET"]), execute="--execute" in modes, verify_cmd="x" if "--verify-cmd" in modes else None,
                    no_verify="--no-verify" in modes, rpc=None, contract="0x1", chain_id=None, program_hash=None,
                    epoch=None, no_build=True, proof_dir=None, timeout=1, rate=1, rate_window=1, ttl=1))


if __name__ == "__main__":
    unittest.main()
