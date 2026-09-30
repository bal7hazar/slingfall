"""Unit test of `prove_local.confirmed` (lot H4): a transaction without a receipt fails as the error its
caller handles. For the relay that is `RelayError`: `relay_job` records it (`simulate`/`send` stage),
backs off and reaches `gave-up`; any other exception would escape it and be retried for ever
unrecorded. Run: `python3 -m unittest scripts/play/test_prove_local.py`."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parents[1] / "services" / "prove")]
import prove_local as pl  # noqa: E402
import test_prove_service as tps  # noqa: E402

ps, snip36 = pl.ps, pl.snip36


class FakeNode:
    """`snip36.Rpc` of a devnet that knows the `known` transaction hashes (and closes a block on demand)."""

    def __init__(self, known=(), blocks_fail=False):
        self.known, self.calls, self.blocks_fail = set(known), [], blocks_fail

    def __call__(self, method, params):
        self.calls.append(method)
        if method == "devnet_createBlock":
            if self.blocks_fail:
                raise snip36.Snip36Error("RPC devnet_createBlock: refused")
            return {}
        if params["transaction_hash"] not in self.known:
            raise snip36.Snip36Error('RPC starknet_getTransactionReceipt: {"code": 29, "message": "Transaction hash not found"}')
        return {"execution_status": "SUCCEEDED"}


def patched(node):
    return mock.patch.object(snip36, "Rpc", lambda url, timeout=0: node), mock.patch.object(pl.time, "sleep", lambda s: None)


class Confirmed(unittest.TestCase):
    def run_confirmed(self, node, send, **kw):
        rpc_patch, sleep_patch = patched(node)
        with rpc_patch, sleep_patch:
            return pl.confirmed(send, "http://devnet", "settle", timeout=0.05, **kw)()

    def test_a_transaction_with_a_receipt_passes_through(self):
        result = self.run_confirmed(FakeNode(known=["0xa"]), lambda: {"transaction_hash": "0xa", "gas": 1})
        self.assertEqual(result, {"transaction_hash": "0xa", "gas": 1})

    def test_a_result_without_a_hash_is_returned_untouched(self):
        self.assertEqual(self.run_confirmed(FakeNode(), lambda: {"rejected": "x"}), {"rejected": "x"})

    def test_a_missing_receipt_asks_for_one_block_then_fails_with_the_callers_error(self):
        node = FakeNode()
        with self.assertRaises(snip36.Snip36Error) as e:
            self.run_confirmed(node, lambda: {"transaction_hash": "0xb"})
        self.assertIn("settle 0xb: no receipt on http://devnet", str(e.exception))
        self.assertEqual(node.calls.count("devnet_createBlock"), 1)

    def test_the_relay_error_class_and_a_refused_block(self):
        with self.assertRaises(pl.relaying.RelayError):
            self.run_confirmed(FakeNode(), lambda: {"transaction_hash": "0xb"}, fail=pl.relaying.RelayError)
        with self.assertRaises(pl.relaying.RelayError) as e:
            self.run_confirmed(FakeNode(blocks_fail=True), lambda: {"transaction_hash": "0xb"}, fail=pl.relaying.RelayError)
        self.assertIn("refused", str(e.exception))


class RelayWithoutReceipt(unittest.TestCase):
    """`Service.relay_job` with the local settle wrapper: no receipt is recorded, backs off, gives up."""

    programs = tps.Service.programs
    tearDown = tps.Service.tearDown

    def setUp(self):
        tps.Service.setUp(self)
        self.relayer = tps.FakeRelay()
        self.service.relayer = self.relayer
        self.node = FakeNode()
        self.sends = 0
        inner = self.relayer.send

        def send(job):
            self.sends += 1
            result = inner(job)
            self.relayer.tier_value = 0  # the transaction was never included: the attempt is not settled
            return {**result, "transaction_hash": "0xdead"}

        self.relayer.send = send

    submitted = tps.Relay.submitted

    def test_the_failure_is_recorded_and_the_relay_gives_up(self):
        rpc_patch, sleep_patch = patched(self.node)
        with rpc_patch, sleep_patch:
            self.relayer.send = pl.confirmed(self.relayer.send, "http://devnet", "settle", timeout=0.01, fail=pl.relaying.RelayError)
            jid = self.submitted()
            self.on_chain["isKeccakVerifiedFactHashValid"] = True
            self.service.relay_job(jid)
            state = self.service.status(jid)["relay"]
            self.assertEqual(state["attempts"], 1)
            self.assertRegex(state["error"], r"^send: settle 0xdead: no receipt on http://devnet")
            for _ in range(ps.relaying.RELAY_ATTEMPTS - 1):
                self.now += ps.relaying.RELAY_RETRY
                self.service.relay_job(jid)
            state = self.service.status(jid)["relay"]
            self.assertEqual((state["state"], state["attempts"]), ("gave-up", ps.relaying.RELAY_ATTEMPTS))
            self.now += ps.relaying.RELAY_RETRY
            self.service.relay_job(jid)  # given up: nothing more is sent
            self.assertEqual(self.sends, ps.relaying.RELAY_ATTEMPTS)


if __name__ == "__main__":
    unittest.main()
