#!/usr/bin/env python3
"""Tests of attest.py: `python3 -m unittest discover -s services/attest` (standard library only).

The golden vector is read from the contract's own fixtures (`src/submit/fixtures.cairo`,
`GOLDEN_ATTEST_*`), so the service signs exactly what `AttestationVerifier` accepts in the Cairo
tests. The chain, the replay and the verify command are fakes."""

from __future__ import annotations

import argparse
import base64
import http.client
import io
import json
import os
import re
import select
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
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
        self.error = OSError("connection refused")  # raised while `down`

    def __call__(self, method: str, params):
        if self.down:
            raise self.error
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

    def test_an_rpc_failure_never_quotes_the_url(self):
        # urllib's errors (and the RPC's own) may quote the configured URL, its key in the path or query.
        rpc = FakeRpc()
        rpc.down = True
        rpc.error = urllib.error.URLError("https://rpc.example/v2/SECRETKEY?k=SECRET: refused")
        with self.assertRaises(attest.AttestError) as e:
            attest.Chain(CONTRACT, rpc, rpc_url="https://rpc.example/v2/SECRETKEY?k=SECRET").get("epoch")
        self.assertEqual((e.exception.status, str(e.exception)), (503, "chain: cannot read epoch"))
        self.assertEqual(e.exception.detail, "URLError rpc=rpc.example")

    def test_rpc_host(self):
        for url, host in [
            ("https://tok123.rpc.example.net/v2/KEY", "*.rpc.example.net"),  # a token in the leftmost label
            ("https://rpc.example/v2/SECRETKEY?k=SECRET", "rpc.example"),
            ("http://user:SECRET@localhost:5050/rpc", "localhost"),
            ("http://10.0.0.1:9545/SECRET", "10.0.0.1"),
            ("http://[::1]:5050", "::1"),
            ("http://[SECRET/v2", "?"),  # urlsplit raises ValueError
            ("SECRET", "?"),
            (None, "?"),
        ]:
            self.assertEqual(attest.rpc_host(url), host, url)


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

    def test_wait_is_the_time_until_the_window_frees(self):
        clock = [0.0]
        limiter = attest.RateLimiter(2, 10, clock=lambda: clock[0])
        limiter.allow("a")
        clock[0] = 4.0
        limiter.allow("a")
        self.assertEqual(limiter.wait("a"), 6.0)  # the first request leaves the window at 10
        clock[0] = 10.0
        self.assertEqual(limiter.wait("a"), 0.0)  # the reset

    def test_idle_keys_are_pruned(self):
        clock = [0.0]
        limiter = attest.RateLimiter(5, 10, clock=lambda: clock[0])
        for key in range(100):
            limiter.allow(key)
        self.assertEqual(len(limiter), 100)
        clock[0] = 10.0  # every key idle for a window; the next request prunes
        limiter.allow("fresh")
        self.assertEqual(len(limiter), 1)

    def test_at_most_max_keys(self):
        limiter = attest.RateLimiter(5, 10, clock=lambda: 0.0, max_keys=3)
        for key in "abcd":
            limiter.allow(key)
        self.assertEqual(len(limiter), 3)
        self.assertNotIn("a", limiter._seen)  # the least recently seen went first


class ClientTest(unittest.TestCase):
    def test_forwarded_for_is_trusted_on_the_proxys_socket_only(self):
        proxied = lambda forwarded: attest.client_of(None, forwarded, proxied=True)  # noqa: E731
        self.assertEqual(proxied("203.0.113.9"), "203.0.113.9")
        # Caddy appends the peer it saw: the last entry; the earlier ones are the caller's own.
        self.assertEqual(proxied("10.0.0.1, 203.0.113.9"), "203.0.113.9")
        # Several header lines: joined, the last line's last entry (the last proxy's addition).
        self.assertEqual(proxied(["203.0.113.9", "198.51.100.7"]), "198.51.100.7")
        self.assertIsNone(proxied(None))  # a local caller
        self.assertIsNone(proxied(" "))
        # On TCP the header is never read: a remote peer counts on its own address, a loopback peer
        # (an agent on the machine) is local whatever it claims.
        self.assertEqual(attest.client_of("198.51.100.7", "203.0.113.9"), "198.51.100.7")
        self.assertIsNone(attest.client_of("127.0.0.1", "203.0.113.9"))
        self.assertIsNone(attest.client_of("127.0.0.5", None))
        self.assertIsNone(attest.client_of("::1", None))

    def test_ipv6_counts_as_its_64(self):
        a = attest.client_of(None, "2001:db8:1:2::1", proxied=True)
        self.assertEqual(a, "2001:db8:1:2::/64")
        self.assertEqual(attest.client_of(None, "2001:db8:1:2:ffff:ffff:ffff:ffff", proxied=True), a)
        self.assertNotEqual(attest.client_of(None, "2001:db8:1:3::1", proxied=True), a)
        self.assertEqual(attest.client_of(None, "::ffff:203.0.113.9", proxied=True), "203.0.113.9")
        self.assertEqual(attest.client_of("2001:db8:1:2::9", None), a)

    def test_only_an_ip_literal_is_a_client(self):
        for bad in ["unknown", "203.0.113.9\r\n 2026-10-02T00:00:00Z POST /attest 200", "203.0.113.9:443", "_hidden"]:
            self.assertIsNone(attest.client_of(None, bad, proxied=True), bad)  # counted as local


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float = 30):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def connection(url: str, timeout: float = 30) -> http.client.HTTPConnection:
    if url.startswith("unix:"):
        return UnixHTTPConnection(url[len("unix:"):], timeout)
    host, port = url[len("http://"):].split(":")
    return http.client.HTTPConnection(host, int(port), timeout=timeout)


class GateTest(unittest.TestCase):
    def test_concurrent_and_queued_then_429(self):
        gate = attest.Gate(concurrent=1, queue=1)
        release, inside = threading.Event(), threading.Event()

        def hold():
            with gate.slot():
                inside.set()
                release.wait(10)

        first = threading.Thread(target=hold)
        first.start()
        inside.wait(10)
        second = threading.Thread(target=hold)  # queued
        second.start()
        deadline = time.monotonic() + 10
        while gate.admitted < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        with self.assertRaises(attest.AttestError) as e:
            with gate.slot():
                pass
        self.assertEqual(e.exception.status, 429)
        self.assertGreaterEqual(e.exception.retry_after, 1)
        release.set()
        first.join(10)
        second.join(10)
        self.assertEqual(gate.admitted, 0)
        with gate.slot():  # free again
            pass

    def test_no_queue_cap(self):
        gate = attest.Gate(concurrent=1, queue=None)
        gate.admitted = 1000
        with gate.slot():
            pass


class SystemdSocketTest(unittest.TestCase):
    def test_serves_on_the_passed_socket(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        fd = os.dup(listener.fileno())
        listener.close()
        environ = {"LISTEN_PID": str(os.getpid()), "LISTEN_FDS": "1"}
        sock = attest.systemd_socket(environ, fd)
        self.assertEqual(environ, {})  # consumed
        chain = attest.Chain(CONTRACT, None, chain_id=CHAIN_ID, program_hash=PROGRAM, epoch=EPOCH)
        server = attest.serve(attest.Attester(CONST["SECRET"], chain), "ignored", 0, sock=sock, log=io.StringIO())
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with urllib.request.urlopen(f"http://127.0.0.1:{sock.getsockname()[1]}/health", timeout=10) as r:
            self.assertEqual(json.loads(r.read())["service"], "slingfall-attest")

    def test_a_unix_socket_from_systemd(self):
        tmp = tempfile.mkdtemp(prefix="attest_sock_")
        path = f"{tmp}/attest.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen()
        self.addCleanup(lambda: (os.unlink(path), os.rmdir(tmp)))
        fd = os.dup(listener.fileno())
        listener.close()
        sock = attest.systemd_socket({"LISTEN_PID": str(os.getpid()), "LISTEN_FDS": "1"}, fd)
        self.assertEqual(sock.family, socket.AF_UNIX)
        chain = attest.Chain(CONTRACT, None, chain_id=CHAIN_ID, program_hash=PROGRAM, epoch=EPOCH)
        server = attest.serve(attest.Attester(CONST["SECRET"], chain), "ignored", 0, sock=sock, log=io.StringIO())
        self.assertEqual(attest.describe(server.server_address), f"unix:{path}")
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        conn = UnixHTTPConnection(path)
        conn.request("GET", "/health")
        self.assertEqual(json.loads(conn.getresponse().read())["service"], "slingfall-attest")
        conn.close()

    def test_refuses_without_systemd(self):
        for environ in [{}, {"LISTEN_PID": "1", "LISTEN_FDS": "1"}, {"LISTEN_PID": str(os.getpid()), "LISTEN_FDS": "2"}]:
            with self.assertRaises(SystemExit):
                attest.systemd_socket(dict(environ), 99)


class KeyTest(unittest.TestCase):
    """`parse_key`: `--key`, `$SLINGFALL_ATTEST_KEY`, `$SLINGFALL_ATTEST_KEY_FILE` (throwaway keys)."""

    def env(self, **values):
        clean = {k: v for k, v in os.environ.items() if k not in (attest.KEY_ENV, attest.KEY_FILE_ENV)}
        return mock.patch.dict(os.environ, {**clean, **values}, clear=True)

    def key_file(self, text: str) -> str:
        f = tempfile.NamedTemporaryFile("w", suffix=".key", delete=False)
        f.write(text)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_sources(self):
        path = self.key_file("0x1234\n")
        with self.env(SLINGFALL_ATTEST_KEY_FILE=path):
            self.assertEqual(attest.parse_key(None), 0x1234)
            self.assertEqual(attest.parse_key("0x99"), 0x99)  # --key first
        with self.env(SLINGFALL_ATTEST_KEY="0x55"):
            self.assertEqual(attest.parse_key(None), 0x55)
        with self.env(SLINGFALL_ATTEST_KEY="0x55", SLINGFALL_ATTEST_KEY_FILE=path):
            with self.assertRaises(SystemExit):
                attest.parse_key(None)
        with self.env():
            with self.assertRaises(SystemExit):
                attest.parse_key(None)

    def test_errors_never_quote_the_key(self):
        secret = "0xnotakey5ec2e7"
        for path in [self.key_file(secret), self.key_file(hex(attest.vectors.N))]:
            with self.env(SLINGFALL_ATTEST_KEY_FILE=path):
                with self.assertRaises(SystemExit) as e:
                    attest.parse_key(None)
                self.assertNotIn("5ec2e7", str(e.exception.code))
                self.assertNotIn(hex(attest.vectors.N)[4:], str(e.exception.code))
        with self.env(SLINGFALL_ATTEST_KEY_FILE="/nonexistent/attest.key"):
            with self.assertRaises(SystemExit):
                attest.parse_key(None)

    def test_pubkey_through_the_file(self):
        path = self.key_file(hex(CONST["SECRET"]))
        out = io.StringIO()
        with self.env(SLINGFALL_ATTEST_KEY_FILE=path), mock.patch("sys.stdout", out):
            attest.main(["pubkey"])
        self.assertEqual(out.getvalue().strip(), hex(CONST["ATTESTATION_KEY"]))


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

    def start(self, command: str | None = None, execute: bool = False, rate: int = 20, client_rate: int = 120,
              revision: str | None = None, local_rate: int = 60, cors_origin: str = "*", unix: bool = False,
              **options) -> str:
        chain = attest.Chain(CONTRACT, self.rpc, clock=lambda: 0.0)
        executor = attest.Executor(self.replay) if execute else None
        self.attester = attest.Attester(CONST["SECRET"], chain, executor, attest.Verifier(command, None, 30),
                                        attest.RateLimiter(rate, 3600), ttl=TTL,
                                        clients=attest.RateLimiter(client_rate, 3600), revision=revision,
                                        local=attest.RateLimiter(local_rate, 3600))
        return self.serve(self.attester, cors_origin, unix, **options)

    def serve(self, attester, cors_origin: str = "*", unix: bool = False, **options) -> str:
        """On 127.0.0.1 (TCP: every caller local), or on a Unix socket like the reverse proxy's
        (`unix`: `X-Forwarded-For` is the client)."""
        self.log = io.StringIO()
        self.cors_origin = cors_origin
        sock = None
        if unix:
            tmp = tempfile.mkdtemp(prefix="attest_sock_")
            self.addCleanup(lambda: (os.path.exists(f"{tmp}/s") and os.unlink(f"{tmp}/s"), os.rmdir(tmp)))
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.bind(f"{tmp}/s")
            sock.listen()
        server = attest.serve(attester, "127.0.0.1", 0, cors_origin, sock=sock, log=self.log, **options)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return attest.describe(server.server_address)

    def post(self, url: str, body, headers=None) -> tuple[int, dict]:
        status, answer, _ = self.post_full(url, body, headers)
        return status, answer

    def post_full(self, url: str, body, headers=None) -> tuple[int, dict, dict]:
        """`headers`: a dict, or a list of (name, value) pairs (a header sent on several lines)."""
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        items = list(headers.items()) if isinstance(headers, dict) else list(headers or [])
        conn = connection(url)
        try:
            conn.putrequest("POST", "/attest")
            for name, value in [("Content-Type", "application/json"), ("Content-Length", str(len(data))), *items]:
                conn.putheader(name, value)
            conn.endheaders(data)
            r = conn.getresponse()
            answer = json.loads(r.read())
            if r.status == 200:
                self.assertEqual(r.getheader("Access-Control-Allow-Origin"), self.cors_origin)
            return r.status, answer, dict(r.getheaders())
        finally:
            conn.close()

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
        answers = [self.post_full(url, {"level": "pile10", "inputs": INPUTS}) for _ in range(3)]
        self.assertEqual([a[0] for a in answers], [200, 200, 429])
        self.assertGreater(int(answers[2][2]["Retry-After"]), 3500)  # the window is 3 600 s
        self.assertEqual(len(self.runs), 2)  # the refused request never ran
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": other})[0], 200)

    def test_rate_limit_per_client_behind_the_proxy(self):
        url = self.start(execute=True, client_rate=2, unix=True)
        players = [[hex(CONST["PLAYER"] + i), *INPUTS[1:]] for i in range(4)]
        a, b = {"X-Forwarded-For": "203.0.113.9"}, {"X-Forwarded-For": "198.51.100.7"}
        answers = [self.post_full(url, {"level": "pile10", "inputs": p}, a) for p in players[:3]]
        self.assertEqual([x[0] for x in answers], [200, 200, 429])  # new players do not help
        self.assertIn("Retry-After", answers[2][2])
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": players[3]}, b)[0], 200)  # another client
        # A caller without the header is local: its own cap (60), not this client's.
        self.assertEqual([self.post(url, {"level": "pile10", "inputs": p})[0] for p in players[3:] * 3], [200] * 3)
        self.assertIn("client=203.0.113.9", self.log.getvalue())
        self.assertIn("client=local", self.log.getvalue())

    def test_a_malformed_request_leaves_the_players_count(self):
        url = self.start(execute=True, rate=1)
        for _ in range(3):
            self.assertEqual(self.post(url, {"level": "nope", "inputs": INPUTS})[0], 400)
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": INPUTS})[0], 200)
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": INPUTS})[0], 429)

    def test_a_malformed_proof_gives_the_charge_back(self):
        url = self.start(TRUE_CMD, rate=1)
        self.assertEqual(self.post(url, {"outputs": GOLDEN, "proof": "not base64!"})[0], 400)
        self.assertEqual(self.post(url, {"outputs": GOLDEN, "proof": base64.b64encode(b"x").decode()})[0], 200)
        self.assertEqual(self.post(url, {"outputs": GOLDEN, "proof": base64.b64encode(b"x").decode()})[0], 429)

    def test_local_callers_share_one_cap(self):
        url = self.start(execute=True, local_rate=2, unix=True)
        players = [[hex(CONST["PLAYER"] + i), *INPUTS[1:]] for i in range(4)]
        answers = [self.post(url, {"level": "pile10", "inputs": p})[0] for p in players[:2]]
        # Not an IP literal: local too.
        answers.append(self.post(url, {"level": "pile10", "inputs": players[2]}, {"X-Forwarded-For": "nope"})[0])
        self.assertEqual(answers, [200, 200, 429])
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": players[3]}, {"X-Forwarded-For": "203.0.113.9"})[0], 200)

    def test_tcp_loopback_callers_are_local_whatever_header(self):
        url = self.start(execute=True, local_rate=2, client_rate=100)
        players = [[hex(CONST["PLAYER"] + i), *INPUTS[1:]] for i in range(3)]
        answers = [self.post(url, {"level": "pile10", "inputs": p}, {"X-Forwarded-For": f"198.51.100.{i}"})[0]
                   for i, p in enumerate(players)]
        self.assertEqual(answers, [200, 200, 429])  # the header did not make them three clients
        self.assertNotIn("client=198.51.100", self.log.getvalue())

    def test_several_forwarded_lines_count_the_last(self):
        url = self.start(execute=True, client_rate=1, unix=True)
        players = [[hex(CONST["PLAYER"] + i), *INPUTS[1:]] for i in range(3)]
        lines = [("X-Forwarded-For", "198.51.100.1"), ("X-Forwarded-For", "203.0.113.9")]
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": players[0]}, lines)[0], 200)
        # The caller's own first line changes: still 203.0.113.9, refused.
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": players[1]},
                                   [("X-Forwarded-For", "198.51.100.2"), lines[1]])[0], 429)
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": players[2]},
                                   [lines[1], ("X-Forwarded-For", "198.51.100.7")])[0], 200)

    def test_every_malformed_post_is_charged_to_its_client(self):
        url = self.start(execute=True, client_rate=2, rate=1, unix=True)
        a = {"X-Forwarded-For": "203.0.113.9"}
        self.assertEqual(self.post(url, {"level": "pile10"}, a)[0], 400)  # no player
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": ["xyz", "0x0"]}, a)[0], 400)  # a bad player
        self.assertEqual(self.post(url, b"{not json", a)[0], 429)  # the client's two are spent
        # The player named by none of them is untouched: one request left, from another client.
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": INPUTS}, {"X-Forwarded-For": "198.51.100.7"})[0], 200)

    def test_a_refusal_before_the_body_is_answered_not_reset(self):
        url = self.start(local_rate=1)
        self.assertEqual(self.post(url, b"{not json")[0], 400)  # the local client's only request
        host, port = url[len("http://"):].split(":")
        with socket.create_connection((host, int(port)), timeout=5) as s:
            s.sendall(b"POST /attest HTTP/1.1\r\nHost: x\r\nContent-Length: 18\r\n\r\n")
            time.sleep(0.2)  # the 429 is decided now; the body arrives after
            s.sendall(b"{not json")
            time.sleep(0.2)  # closed without draining, the first half was answered by a reset
            s.sendall(b"{not json")
            received = b""
            while chunk := s.recv(4096):
                received += chunk
        self.assertTrue(received.startswith(b"HTTP/1.0 429"), received[:40])

    def test_a_body_over_the_drain_limit_is_not_read_for_a_refusal(self):
        url = self.start(local_rate=1, timeout=2.0)
        self.assertEqual(self.post(url, b"{not json")[0], 400)
        started = time.monotonic()
        head = b"POST /attest HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % (attest.DRAIN_LIMIT + 1)
        answer = self.raw(url, head + b"{" * 10)  # the rest never comes
        self.assertTrue(answer.startswith(b"HTTP/1.0 429"), answer[:40])
        self.assertLess(time.monotonic() - started, 1.0)

    def test_a_timed_out_body_is_not_drained(self):
        url = self.serve(attest.Attester(CONST["SECRET"], attest.Chain(CONTRACT, self.rpc)), timeout=1.0)
        started = time.monotonic()
        answer = self.raw(url, b"POST /attest HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n")
        self.assertTrue(answer.startswith(b"HTTP/1.0 408"), answer[:40])
        self.assertLess(time.monotonic() - started, 1.6)  # one idle timeout, not two

    def raw(self, url: str, data: bytes, wait: float = 5.0) -> bytes:
        """Sends `data` on a fresh connection and reads until the server closes it (or `wait`)."""
        host, port = url[len("http://"):].split(":")
        with socket.create_connection((host, int(port)), timeout=wait) as s:
            s.sendall(data)
            received = b""
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    return received
                received += chunk

    def test_a_stalled_connection_is_closed(self):
        url = self.serve(attest.Attester(CONST["SECRET"], attest.Chain(CONTRACT, self.rpc)), timeout=0.5)
        started = time.monotonic()
        answer = self.raw(url, b"POST /attest HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n")  # no body
        self.assertTrue(answer.startswith(b"HTTP/1.0 408"), answer[:40])
        self.assertEqual(self.raw(url, b"POST /attest HTTP/1.1\r\n"), b"")  # headers never end
        self.assertLess(time.monotonic() - started, 4)

    def trickle(self, url: str, head: bytes, data: bytes, every: float, limit: float) -> tuple[bytes, float]:
        """Sends `head` at once, then `data` a byte every `every` s (each within the idle timeout) until
        the server closes the connection; returns what came back and when, or fails after `limit` s."""
        host, port = url[len("http://"):].split(":")
        started = time.monotonic()
        with socket.create_connection((host, int(port)), timeout=limit) as s:
            s.sendall(head)
            for byte in data:
                try:
                    s.sendall(bytes([byte]))
                except OSError:
                    break  # closed by the server
                ready = select.select([s], [], [], every)[0]
                if ready:
                    break
            received = b""
            while chunk := s.recv(4096):
                received += chunk
        return received, time.monotonic() - started

    def test_a_trickling_client_is_cut_at_the_deadline(self):
        attester = attest.Attester(CONST["SECRET"], attest.Chain(CONTRACT, self.rpc))
        url = self.serve(attester, timeout=0.5, deadline=1.0)
        # Headers, a byte every 0.2 s (under the 0.5 s idle timeout): closed once the 1 s deadline passes.
        answer, took = self.trickle(url, b"", b"POST /attest HTTP/1.1\r\nHost: " + b"x" * 200, 0.2, 10)
        self.assertEqual(answer, b"")
        self.assertLess(took, 3)
        # Headers on time, then the body trickled: 408.
        head = b"POST /attest HTTP/1.1\r\nHost: x\r\nContent-Length: 200\r\n\r\n"
        answer, took = self.trickle(url, head, b"{" * 200, 0.2, 10)
        self.assertTrue(answer.startswith(b"HTTP/1.0 408"), answer[:40])
        self.assertLess(took, 3)

    def test_connections_are_capped(self):
        url = self.serve(attest.Attester(CONST["SECRET"], attest.Chain(CONTRACT, self.rpc)), timeout=1.0,
                         max_connections=1)
        host, port = url[len("http://"):].split(":")
        idle = socket.create_connection((host, int(port)))
        self.addCleanup(idle.close)
        time.sleep(0.2)  # accepted: it holds the one connection
        self.assertEqual(self.raw(url, b"GET /health HTTP/1.0\r\n\r\n", wait=0.5), b"")  # closed at once
        time.sleep(1.2)  # the idle one timed out
        self.assertTrue(self.raw(url, b"GET /health HTTP/1.0\r\n\r\n").startswith(b"HTTP/1.0 200"))

    def test_cors_origin(self):
        url = self.start(execute=True, cors_origin="https://play.example")
        _, _, headers = self.post_full(url, {"level": "pile10", "inputs": INPUTS})
        self.assertEqual((headers["Access-Control-Allow-Origin"], headers["Vary"]), ("https://play.example", "Origin"))

    def test_execute_body_is_small(self):
        url = self.start(execute=True)
        big = json.dumps({"level": "pile10", "inputs": INPUTS, "pad": "x" * (16 << 10)}).encode()
        self.assertEqual(self.post(url, big)[0], 413)
        self.assertEqual(self.runs, [])
        url = self.start(TRUE_CMD)  # a verify service takes a proof inline
        self.assertEqual(self.post(url, {"outputs": GOLDEN, "proof": base64.b64encode(b"x" * (32 << 10)).decode()})[0], 200)

    def test_a_busy_answer_leaves_the_players_count(self):
        release = threading.Event()

        def slow(level, inputs):
            release.wait(10)
            return GOLDEN

        chain = attest.Chain(CONTRACT, self.rpc, clock=lambda: 0.0)
        limiter = attest.RateLimiter(1, 3600)
        attester = attest.Attester(CONST["SECRET"], chain, attest.Executor(slow), limiter=limiter, ttl=TTL,
                                   gate=attest.Gate(1, 0))
        url = self.serve(attester)
        other = [hex(CONST["PLAYER"] + 1), *INPUTS[1:]]
        first = threading.Thread(target=lambda: self.post(url, {"level": "pile10", "inputs": INPUTS}))
        first.start()
        deadline = time.monotonic() + 10
        while attester.gate.admitted < 1 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": other})[0], 429)  # busy
        self.assertEqual(len(limiter._seen.get(int(other[0], 16), [])), 0)
        release.set()
        first.join(10)
        self.assertEqual(self.post(url, {"level": "pile10", "inputs": other})[0], 200)  # its one request is intact

    def test_the_global_queue_answers_429(self):
        release = threading.Event()

        def slow(level, inputs):
            release.wait(10)
            return GOLDEN

        chain = attest.Chain(CONTRACT, self.rpc, clock=lambda: 0.0)
        attester = attest.Attester(CONST["SECRET"], chain, attest.Executor(slow), ttl=TTL, gate=attest.Gate(1, 1))
        url = self.serve(attester)
        players = [[hex(CONST["PLAYER"] + i), *INPUTS[1:]] for i in range(3)]
        results = {}
        threads = [threading.Thread(target=lambda i=i: results.__setitem__(i, self.post(url, {"level": "pile10", "inputs": players[i]})))
                   for i in range(2)]
        for th in threads:
            th.start()
        deadline = time.monotonic() + 10
        while attester.gate.admitted < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        status, body, headers = self.post_full(url, {"level": "pile10", "inputs": players[2]})
        self.assertEqual(status, 429, body)
        self.assertIn("busy", body["error"])
        self.assertIn("Retry-After", headers)
        release.set()
        for th in threads:
            th.join(10)
        self.assertEqual([results[0][0], results[1][0]], [200, 200])

    def test_play_sh_flags_serve_every_request(self):
        """`scripts/play.sh`'s flag set (`--rate 0`): many requests from one peer and one player,
        some at once, are all served."""
        args = attest.make_parser().parse_args([
            "serve", "--key", hex(CONST["SECRET"]), "--execute", "--no-build", "--rate", "0", "--contract", hex(CONTRACT),
            "--chain-id", "SN_SEPOLIA", "--program-hash", hex(PROGRAM), "--epoch", str(EPOCH),
            "--host", "127.0.0.1", "--port", "0"])
        attester = attest.make_attester(args)
        attester.executor.run = self.replay
        url = self.serve(attester)
        statuses = []
        lock = threading.Lock()

        def burst():
            for _ in range(15):
                status = self.post(url, {"level": "pile10", "inputs": INPUTS}, {"X-Forwarded-For": "203.0.113.9"})[0]
                with lock:
                    statuses.append(status)

        threads = [threading.Thread(target=burst) for _ in range(8)]
        for th in threads:
            th.start()
        for th in threads:
            th.join(60)
        self.assertEqual(statuses, [200] * 120)
        self.assertEqual(len(self.runs), 120)

    def test_one_log_line_per_request_without_the_body(self):
        url = self.start(execute=True)
        self.post(url, {"level": "pile10", "inputs": INPUTS})
        self.post(url, {"level": "nope", "inputs": INPUTS})
        urllib.request.urlopen(url + "/health", timeout=10).read()
        lines = self.log.getvalue().splitlines()
        self.assertEqual(len(lines), 3, lines)
        self.assertRegex(lines[0], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ POST /attest 200 \d+\.\d{3}s client=local "
                                   rf"player={hex(CONST['PLAYER'])} mode=execute")
        self.assertRegex(lines[1], r" POST /attest 400 .* error=")
        self.assertRegex(lines[2], r" GET /health 200 ")
        self.assertNotIn(hex(CONST["SECRET"]), self.log.getvalue())
        self.assertNotIn(INPUTS[2], self.log.getvalue())  # no body

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

    def test_an_rpc_failure_answers_and_logs_no_secret(self):
        """The answer is fixed; the log keeps the exception's type and the RPC's host, its leftmost label
        masked past two labels, never the URL's path, query or credentials; a malformed URL still 503."""
        for rpc_url, logged in [("https://rpc.example/v2/SECRETKEY?k=SECRET", "rpc=rpc.example"),
                                ("https://tok123.rpc.example.net/v2/KEY", "rpc=*.rpc.example.net"),
                                ("http://[SECRET/v2", "rpc=?")]:
            self.rpc.down = True
            self.rpc.error = urllib.error.URLError(f"{rpc_url}: SECRET connection refused")
            chain = attest.Chain(CONTRACT, self.rpc, clock=lambda: 0.0, rpc_url=rpc_url)
            url = self.serve(attest.Attester(CONST["SECRET"], chain, verifier=attest.Verifier(None, None, 30)))
            status, body = self.post(url, {"outputs": GOLDEN})
            self.assertEqual((status, body), (503, {"error": "chain: cannot read chain_id"}))
            log = self.log.getvalue()
            self.assertIn(f'detail="URLError {logged}"', log)
            for secret in ("SECRET", "tok123", "KEY", "/v2"):
                self.assertNotIn(secret, log)

    def test_malformed_bodies_are_400(self):
        """An object where a list is expected, and JSON nested deeper than the service reads, whatever its depth
        (past the decoder's own recursion limit too): 400, nothing run."""
        deep = lambda n: b"[" * n + b"]" * n  # noqa: E731
        bodies = [{"level": "pile10", "inputs": {"0": "0x1"}}, {"level": "pile10", "inputs": {}},
                  {"level": "pile10", "inputs": "0x1"}, deep(attest.MAX_JSON_DEPTH + 1), deep(500), deep(8000),
                  b'{"level": "pile10", "inputs": ' + deep(200) + b"}"]
        url = self.start(execute=True)
        for body in bodies:
            status, answer = self.post(url, body)
            self.assertEqual(status, 400, (str(body)[:60], answer))
        url = self.start(TRUE_CMD)  # a 64 MiB body: past the decoder's recursion limit
        for body in [{"outputs": {"0": "0x1"}, "proof": ""}, deep(100_000), {"outputs": GOLDEN, "proof": [[[[[[[[[]]]]]]]]]}]:
            self.assertEqual(self.post(url, body)[0], 400, body)
        self.assertEqual(self.runs, [])
        self.assertEqual(self.post(self.start(execute=True), {"level": "pile10", "inputs": INPUTS})[0], 200)

    def test_the_answer_is_written_under_the_idle_timeout(self):
        """N20: the last read leaves the socket's timeout at what was left of the deadline; the answer is
        written under the idle timeout instead."""
        url = self.serve(attest.Attester(CONST["SECRET"], attest.Chain(CONTRACT, self.rpc, clock=lambda: 0.0),
                                         attest.Executor(self.replay)), timeout=5.0, deadline=3.0)
        seen, sendall = [], socket.socket.sendall

        def record(sock, data, *args):
            if threading.current_thread() is not threading.main_thread():
                seen.append(sock.gettimeout())
            return sendall(sock, data, *args)

        with mock.patch.object(socket.socket, "sendall", record):
            status, _ = self.post(url, {"level": "pile10", "inputs": INPUTS})
        self.assertEqual(status, 200)
        self.assertTrue(seen)
        self.assertEqual(set(seen), {5.0})

    def test_health(self):
        url = self.start(TRUE_CMD, revision="29e3e5f")
        self.post(url, {"outputs": GOLDEN, "proof": base64.b64encode(b"x").decode()})
        calls = len(self.rpc.calls)
        with urllib.request.urlopen(url + "/health", timeout=10) as r:
            body = json.loads(r.read())
        self.assertEqual(len(self.rpc.calls), calls)  # no chain call of its own
        self.assertGreaterEqual(body.pop("uptime"), 0)
        self.assertEqual(body, {"service": "slingfall-attest", "revision": "29e3e5f",
                                "public_key": hex(CONST["ATTESTATION_KEY"]), "mode": "verify", "verify": TRUE_CMD,
                                "contract": hex(CONTRACT), "chain_id": hex(CHAIN_ID), "program_hash": hex(PROGRAM),
                                "epoch": EPOCH})

    def test_revision_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "REVISION"
            self.assertIsNone(attest.read_revision(path))
            path.write_text("bbba334\n")
            self.assertEqual(attest.read_revision(path), "bbba334")


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
                    epoch=None, no_build=True, proof_dir=None, timeout=1, rate=1, rate_window=1, ttl=1,
                    client_rate=1, client_window=1, max_concurrent=1, max_queue=1, replay_dir=None, local_rate=1))

    def test_replay_dir_needs_a_manifest_and_no_build(self):
        base = ["serve", "--key", hex(CONST["SECRET"]), "--execute", "--contract", "0x1"]
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):  # no Scarb.toml
                attest.make_attester(attest.make_parser().parse_args([*base, "--no-build", "--replay-dir", tmp]))
            (Path(tmp) / "Scarb.toml").write_text("")
            with self.assertRaises(SystemExit):  # would build
                attest.make_attester(attest.make_parser().parse_args([*base, "--replay-dir", tmp]))
            attester = attest.make_attester(attest.make_parser().parse_args([*base, "--no-build", "--replay-dir", tmp]))
            self.assertEqual(attester.mode, "execute")


if __name__ == "__main__":
    unittest.main()
