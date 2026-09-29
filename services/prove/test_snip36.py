"""Unit tests of the SNIP-36 path (`snip36.py`) and of the service's proven tier: the message rule,
the facts' layout on recorded prover answers, both provers, the scheduler on a modelled chain, the
pipeline (resumable) and `POST /prove`'s `tier`. Python 3 standard library.

    python3 -m unittest discover -s services/prove -v
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prove_service as ps  # noqa: E402
import snip36  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
CHAIN = 0xC4A1
PILE10 = 0x17876831F245E0EC3D63220F2CB73C429EC93E7C888C2AA916D237CD9C114A3


def recorded(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())["answer"]


class MessagesAndFacts(unittest.TestCase):
    def test_message_hash_is_the_contracts(self):
        # `verifier::tests::test_message_hash_is_golden` (contract v3): from 0x5afe, the golden claim.
        payload = [1, PILE10, 0, snip36.short_string("player"), 0xABC, 1650, 1, 2, 431, 0x33]
        self.assertEqual(snip36.message_hash(0x5AFE, snip36.MARKER, payload),
                         0x743C2D89F0290E5C22AE2CE6D52430D15361A740D330187E43F4BFE65EAEA2F)

    def test_bundle_of_the_pins(self):
        pins = snip36.pinned_hashes()
        self.assertTrue(set(snip36.BUNDLE_CLASSES) <= set(pins), pins)
        bundle = snip36.bundle_hash(pins)
        self.assertEqual(bundle, snip36.own_bundle())
        self.assertEqual(bundle, ps.encoding.poseidon_many([pins[n] for n in snip36.BUNDLE_CLASSES]))
        swapped = dict(pins, BuildClass=pins["SettleClass"], SettleClass=pins["BuildClass"])
        self.assertNotEqual(snip36.bundle_hash(swapped), bundle)  # the order is part of the bundle
        # Cairo computes the same bundle (`hashes::bundle_hash()`, checked against `BUNDLE_HASH` by
        # the crate's `test_pinned_class_hashes`, lot B6).
        cairo = re.search(r"pub const BUNDLE_HASH: felt252 =\s*(0x[0-9a-fA-F]+);", snip36.HASHES.read_text())
        self.assertEqual(bundle, int(cairo[1], 16))

    def test_one_list_of_classes(self):
        # Lot H3: `classes.json` is the one list; the build, the harness, the pins and the client's
        # copy are derived from it (`classes.py`). Fails when one is out of date.
        script = snip36.ROOT / "crates" / "slingfall_split" / "scripts" / "classes.py"
        run = subprocess.run([sys.executable, str(script), "--check"], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(snip36.BUNDLE_CLASSES), len(set(snip36.BUNDLE_CLASSES)))
        self.assertNotIn("SolverClass", snip36.BUNDLE_CLASSES)

    def test_protocol_layout_accepted(self):
        result = recorded("prove-0.14.4-layout.json")["result"]
        snip36.check_facts([int(x, 16) for x in result["proof_facts"]], result["l2_to_l1_messages"], base_block=20)

    def test_devnet_layout_refused(self):
        # starknet-devnet 0.10.0's own answer: the header is right, index 7 is not the message count.
        result = recorded("devnet-prove-0.10.0.json")["result"]
        with self.assertRaisesRegex(snip36.Snip36Error, "index 7 is the message count"):
            snip36.check_facts([int(x, 16) for x in result["proof_facts"]], result["l2_to_l1_messages"])

    def test_tampered_facts_refused(self):
        result = recorded("prove-0.14.4-layout.json")["result"]
        facts, messages = [int(x, 16) for x in result["proof_facts"]], result["l2_to_l1_messages"]
        cases = {
            "fewer than": facts[:7],
            "virtual-OS header": [snip36.short_string("PROOF3"), *facts[1:]],
            "message 0": [*facts[:8], facts[8] + 1],
            "n_l2_to_l1_messages": [*facts[:7], 2, facts[8]],
        }
        for why, bad in cases.items():
            with self.subTest(why), self.assertRaisesRegex(snip36.Snip36Error, why):
                snip36.check_facts(bad, messages)
        with self.assertRaisesRegex(snip36.Snip36Error, "base block"):
            snip36.check_facts(facts, messages, base_block=21)
        other = [dict(messages[0], payload=messages[0]["payload"][:1])]
        with self.assertRaisesRegex(snip36.Snip36Error, "message 0"):
            snip36.check_facts(facts, other)


class FakeRpc:
    """Blocks (number, hash) that `devnet_createBlock` advances."""

    def __init__(self, number: int = 20):
        self.number, self.calls = number, []

    def block(self, block_id="latest") -> dict:
        return {"block_number": self.number, "block_hash": hex(0xB10C00 + self.number), "timestamp": 1_000}

    def __call__(self, method: str, params) -> object:
        self.calls.append(method)
        if method == "devnet_createBlock":
            self.number += 1
            return {}
        raise AssertionError(method)


class ModelRunner:
    """A chain in miniature: the state is `[tick]`; shot `s` lasts `shots[s]` ticks and the level is over
    after `over_after` shots; tick `t` costs `tick_gas(t)` L2 gas, `init` 100, `outputs` 10. A call past
    `step_cap` stops like a node out of steps; a transaction past `block_cap` exceeds the block."""

    def __init__(self, shots, tick_gas, over_after=None, step_cap=None, block_cap=None):
        self.shots, self.tick_gas = shots, tick_gas
        self.over_after = len(shots) if over_after is None else over_after
        self.step_cap, self.block_cap, self.simulations = step_cap, block_cap, 0

    def shot_end(self, shot: int) -> int:
        return sum(self.shots[: shot + 1])

    def run(self, call: dict) -> tuple[list[int], int]:
        data = call["calldata"]
        if call["entrypoint"] == "init":
            return [0], 100
        state_len = data[0]
        tick = data[1]
        if call["entrypoint"] == "outputs":
            played = sum(1 for s in range(len(self.shots)) if tick >= self.shot_end(s))
            if played < self.over_after:
                raise snip36.SimulationReverted("0x73706c69743a206e6f742066696e6973686564 ('split: not finished')")
            return [1, PILE10, 0, 7, 8, 5200, 1, played, tick, 9], 10
        shot, k = data[-2], data[-1]
        assert 1 + state_len + 1 + data[1 + state_len] + 2 == len(data)
        end = self.shot_end(shot)
        stepped = min(k, end - tick)
        gas = sum(self.tick_gas(t) for t in range(tick, tick + stepped))
        if self.step_cap and gas > self.step_cap:
            raise snip36.SimulationReverted("Could not reach the end of the program. RunResources has no remaining steps.")
        return [tick + stepped, stepped, int(tick + stepped == end)], gas

    def simulate(self, calls: list[dict], block_id="latest") -> dict:
        self.simulations += 1
        results, messages, gas = [], [], 0
        for call in calls:
            ret, g = self.run(call)
            results.append([len(ret), *ret])
            messages.append([{"from_address": hex(CHAIN), "to_address": hex(snip36.MARKER),
                              "payload": [hex(call["calldata"][1] if call["calldata"] else 0), hex(len(call["calldata"])), hex(g)]}])
            gas += g
        if self.block_cap and len(calls) > 1 and gas > self.block_cap:
            raise snip36.Snip36Error("RPC starknet_simulateTransactions: Transaction size exceeds the maximum block capacity")
        return {"results": results, "messages": messages, "l2_gas": gas}


INPUTS = [0x9147, 1, 5, 6, 0, 0]
LEVEL = [1, 2, 3]


def cheap_then_dear(t: int) -> int:
    """Flight ticks cost 10, impact ticks (60..90) 70, the rest 20."""
    return 70 if 60 <= t < 90 else (10 if t < 60 else 20)


class Schedule(unittest.TestCase):
    def check_plan(self, plan: dict, runner: ModelRunner, budget: int) -> None:
        self.assertEqual([c["kind"] for c in plan["calls"]][0], snip36.KIND_INIT)
        self.assertEqual(plan["calls"][-1]["kind"], snip36.KIND_OUTPUTS)
        self.assertEqual(sorted(i for tx in plan["txs"] for i in tx["calls"]), list(range(len(plan["calls"]))))
        order = [i for tx in plan["txs"] for i in tx["calls"]]
        self.assertEqual(order, sorted(order), "calls stay in order across transactions")
        for tx in plan["txs"]:
            self.assertLessEqual(tx["l2_gas"], budget)
        self.assertEqual(plan["ticks"], sum(runner.shots[: runner.over_after]))

    def test_one_shot_packed_under_the_budget(self):
        runner = ModelRunner([107], cheap_then_dear)
        plan = snip36.schedule(runner, CHAIN, LEVEL, INPUTS, budget=1000)
        self.check_plan(plan, runner, 1000)
        # 60 x 10 + 30 x 70 + 17 x 20 = 3,040 L2 gas of ticks, 100 + 10 for init and outputs: 4 transactions.
        self.assertEqual(len(plan["txs"]), 4)
        steps = [c for c in plan["calls"] if c["kind"] == snip36.KIND_STEP]
        self.assertTrue(all(c["shot"] == 0 and c["stepped"] >= 1 for c in steps))
        self.assertEqual(plan["outputs"][5], hex(5200))
        self.assertEqual(plan["level_hash"], hex(ps.encoding.poseidon_many(LEVEL)))

    def test_next_shot_when_the_level_goes_on(self):
        runner = ModelRunner([30, 40, 50], lambda t: 5, over_after=2)
        inputs = [0x9147, 3, *[5, 6, 0, 0] * 3]
        plan = snip36.schedule(runner, CHAIN, LEVEL, inputs, budget=10_000)
        self.check_plan(plan, runner, 10_000)
        self.assertEqual(sorted({c["shot"] for c in plan["calls"] if c["kind"] == snip36.KIND_STEP}), [0, 1])
        self.assertEqual(len(plan["txs"]), 1)

    def test_every_shot_played_and_not_finished(self):
        runner = ModelRunner([10], lambda t: 5, over_after=2)
        with self.assertRaisesRegex(snip36.Snip36Error, "every shot played"):
            snip36.schedule(runner, CHAIN, LEVEL, INPUTS, budget=10_000)

    def test_out_of_steps_halves_k(self):
        runner = ModelRunner([107], cheap_then_dear, step_cap=600)
        plan = snip36.schedule(runner, CHAIN, LEVEL, INPUTS, budget=1000)
        self.check_plan(plan, runner, 1000)

    def test_block_capacity_splits_a_transaction(self):
        runner = ModelRunner([107], cheap_then_dear, block_cap=700)
        plan = snip36.schedule(runner, CHAIN, LEVEL, INPUTS, budget=1000)
        self.check_plan(plan, runner, 1000)
        self.assertTrue(all(tx["l2_gas"] <= 700 or len(tx["calls"]) == 1 for tx in plan["txs"]))

    def test_a_tick_over_the_budget(self):
        runner = ModelRunner([10], lambda t: 2000)
        with self.assertRaisesRegex(snip36.Snip36Error, "one tick"):
            snip36.schedule(runner, CHAIN, LEVEL, INPUTS, budget=1000)

    def test_budget_over_the_protocol_cap(self):
        with self.assertRaisesRegex(snip36.Snip36Error, "over the protocol"):
            snip36.schedule(ModelRunner([1], lambda t: 1), CHAIN, LEVEL, INPUTS, budget=snip36.PROTOCOL_CAP + 1)


def small_plan() -> tuple[dict, ModelRunner]:
    runner = ModelRunner([107], cheap_then_dear)
    return snip36.schedule(runner, CHAIN, LEVEL, INPUTS, budget=1000), runner


class Provers(unittest.TestCase):
    def test_fake_prover_lays_the_facts_out(self):
        plan, runner = small_plan()
        rpc = FakeRpc(42)
        prover = snip36.FakeProver(rpc, runner)
        proof = prover.prove(plan, 0)
        facts = [int(x, 16) for x in proof["proof_facts"]]
        self.assertEqual(facts[:8], [snip36.PROOF_VERSIONS[1], snip36.VIRTUAL_SNOS, snip36.DEVNET_VIRTUAL_OS, snip36.VIRTUAL_SNOS0,
                                     42, 0xB10C00 + 42, snip36.DEVNET_OS_CONFIG_HASH, len(plan["txs"][0]["calls"])])
        snip36.check_facts(facts, proof["messages"], base_block=42)
        doc = snip36.proof_doc(plan, 0, proof)
        self.assertEqual([m["kind"] for m in doc["messages"]], [plan["calls"][i]["kind"] for i in plan["txs"][0]["calls"]])
        prover.ripen(42)
        self.assertEqual((rpc.number, rpc.calls.count("devnet_createBlock")), (52, 10))

    def test_snip36_prover_on_recorded_answers(self):
        plan, _ = small_plan()
        posted, signed = [], []

        def sign(calls, block):
            signed.append((calls, block))
            return {"type": "INVOKE", "signed_at": block}

        for name, error in (("prove-0.14.4-layout.json", None), ("devnet-prove-0.10.0.json", "index 7 is the message count")):
            answer = recorded(name)
            prover = snip36.Snip36Prover("http://prover", FakeRpc(20), sign, post=lambda url, body, a=answer: posted.append(body) or a)
            with self.subTest(name):
                if error:
                    with self.assertRaisesRegex(snip36.Snip36Error, error):
                        prover.prove(plan, 0)
                    continue
                proof = prover.prove(plan, 0)
                self.assertEqual(proof["base_block"], 20)
                self.assertEqual(proof["proof"], answer["result"]["proof"])
                self.assertEqual(len(proof["messages"]), 1)
        self.assertEqual(posted[0]["method"], "starknet_proveTransaction")
        self.assertEqual(posted[0]["params"], {"block_id": {"block_number": 20}, "transaction": {"type": "INVOKE", "signed_at": 20}})
        self.assertEqual(signed[0][0], snip36.tx_calls(plan, 0))

    def test_snip36_prover_errors(self):
        plan, _ = small_plan()
        for answer, error in (({"jsonrpc": "2.0", "id": 1, "error": {"code": -1, "message": "proving failed"}}, "proving failed"),
                              ({"jsonrpc": "2.0", "id": 1, "result": {"proof": "x"}}, "expected proof")):
            prover = snip36.Snip36Prover("http://prover", FakeRpc(), lambda c, b: {}, post=lambda u, b, a=answer: a)
            with self.subTest(error), self.assertRaisesRegex(snip36.Snip36Error, error):
                prover.prove(plan, 0)

    def test_snip36_prover_waits_for_the_block_buffer(self):
        rpc = FakeRpc(20)
        prover = snip36.Snip36Prover("http://prover", rpc, lambda c, b: {}, poll=0, timeout=0)
        with self.assertRaisesRegex(snip36.Snip36Error, "not 10 blocks old"):
            prover.ripen(20)
        rpc.number = 30
        prover.ripen(20)

    def test_proof_doc_checks_the_messages(self):
        plan, runner = small_plan()
        proof = snip36.FakeProver(FakeRpc(), runner).prove(plan, 0)
        bad = json.loads(json.dumps(proof))
        bad["messages"][0]["payload"][0] = "0x1234"
        with self.assertRaisesRegex(snip36.Snip36Error, "differs from the planned"):
            snip36.proof_doc(plan, 0, bad)
        with self.assertRaisesRegex(snip36.Snip36Error, "messages for"):
            snip36.proof_doc(plan, 0, dict(proof, messages=proof["messages"][:-1]))
        bad = json.loads(json.dumps(proof))
        bad["messages"][0]["from_address"] = "0x1"
        with self.assertRaisesRegex(snip36.Snip36Error, "not the chain's"):
            snip36.proof_doc(plan, 0, bad)


class FakeChain:
    """`NodeChain`'s transactions, recorded."""

    address = "0x9e1a7"

    def __init__(self, bundle: int, tier: int = 0):
        self.bundle, self.tiers, self.submitted, self.finalized = bundle, [tier], [], []

    def tier(self, level_hash, player, inputs_hash) -> int:
        return self.tiers[0]

    def submit_proof(self, doc: dict) -> dict:
        self.submitted.append(doc)
        return {"transaction_hash": hex(0x7000 + len(self.submitted)), "level_validated": [], "gas": {"l2Gas": 78_000_000}}

    def finalize(self, plan: dict) -> dict:
        self.finalized.append(plan)
        return {"transaction_hash": "0xf1", "gas": {"l2Gas": 5_600_000},
                "level_validated": [{"proven": True, "settled": True, "programHash": hex(self.bundle)}]}


class FlakyProver(snip36.FakeProver):
    """Fails once on transaction `fail`, then proves."""

    def __init__(self, *args, fail: int | None = None, **kwargs):
        super().__init__(*args, **kwargs)
        self.fail, self.proved = fail, []

    def prove(self, plan, index):
        if index == self.fail:
            self.fail = None
            raise snip36.Snip36Error("prover down")
        self.proved.append(index)
        return super().prove(plan, index)


def view(match: bool = True, bundle: int = 0xB0) -> dict:
    return {"chain": hex(CHAIN), "bundle_hash": hex(bundle if match else bundle + 1), "own_bundle_hash": hex(bundle),
            "chain_valid_until": 2**64 - 1, "now": 1_000, "chain_match": match}


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = ps.Store(Path(self.tmp.name))
        self.runner = ModelRunner([107], cheap_then_dear)
        self.chain = FakeChain(0xB0)
        self.view = view()
        self.prover = FlakyProver(FakeRpc(), self.runner)
        # The chain is modelled; the level is pile10's (the plan's level hash must be the job's).
        self.proven = snip36.Snip36(self.runner, self.prover, self.chain, lambda: self.view, 0xB0,
                                    level_felts=lambda name: ps.resolve_level(name)[2], budget=1000, parallel=2, ttl=0)
        self.service = ps.Service(self.store, ps.Runner(Path("/none"), Path("/none")), proven=self.proven)

    def tearDown(self):
        self.tmp.cleanup()

    def inputs(self) -> list[str]:
        return [hex(x) for x in INPUTS]

    def test_proven_end_to_end_then_status(self):
        job, created = self.service.create("pile10", self.inputs(), "proven")
        self.assertTrue(created)
        self.assertEqual((job["tier"], job["state"]), ("proven", "queued"))
        done = self.service.work_proven(job["id"])
        self.assertEqual(done["state"], "proven", done.get("error"))
        n = len(done["proofs"])
        self.assertEqual(n, done["plan"]["transactions"])
        self.assertEqual([p["state"] for p in done["proofs"]], ["submitted"] * n)
        self.assertEqual(len(self.chain.submitted), n)
        self.assertEqual(done["finalize"]["program_hash"], hex(0xB0))
        status = self.service.status(job["id"])
        self.assertEqual((status["tier"], status["proven"], status["chain_match"], status["settleable"]), ("proven", True, True, False))
        # Asked again: the same job, nothing more sent.
        again, created = self.service.create("pile10", self.inputs(), "proven")
        self.assertFalse(created)
        self.assertEqual(again["id"], job["id"])

    def test_a_failed_proof_resumes(self):
        self.prover.fail = 1
        job, _ = self.service.create("pile10", self.inputs(), "proven")
        failed = self.service.work_proven(job["id"])
        self.assertEqual(failed["state"], "failed")
        self.assertIn("prover down", failed["error"])
        self.assertEqual(self.chain.submitted, [])
        simulations = self.runner.simulations
        self.service.create("pile10", self.inputs(), "proven")  # asked again: re-queued
        done = self.service.work_proven(job["id"])
        self.assertEqual(done["state"], "proven", done.get("error"))
        self.assertEqual(sorted(self.prover.proved).count(0), 1, "a stored proof is not proven again")
        self.assertLess(self.runner.simulations - simulations, 10, "the stored plan is reused")

    def test_already_proven_or_settled(self):
        self.chain.tiers = [snip36.PROVEN]
        job, _ = self.service.create("pile10", self.inputs(), "proven")
        done = self.service.work_proven(job["id"])
        self.assertEqual((done["state"], done["finalize"]["by"]), ("proven", "someone else"))
        self.assertEqual(self.chain.submitted, [])
        other = [hex(x) for x in [0x9148, *INPUTS[1:]]]
        self.chain.tiers = [snip36.SETTLED]
        job, _ = self.service.create("pile10", other, "proven")
        self.assertIn("already settled", self.service.work_proven(job["id"])["error"])

    def test_chain_mismatch_refused(self):
        self.view = view(match=False)
        with self.assertRaises(ps.ProveError) as e:
            self.service.create("pile10", self.inputs(), "proven")
        self.assertEqual(e.exception.status, 409)
        self.assertIn("chain mismatch", str(e.exception))
        self.assertEqual(e.exception.extra["own_bundle_hash"], hex(0xB0))

    def test_tiers(self):
        with self.assertRaises(ps.ProveError) as e:
            self.service.create("pile10", self.inputs(), "sharp")
        self.assertEqual(e.exception.status, 400)
        settled_only = ps.Service(self.store, ps.Runner(Path("/none"), Path("/none")))
        with self.assertRaises(ps.ProveError) as e:
            settled_only.create("pile10", self.inputs(), "proven")
        self.assertIn("no SNIP-36 path", str(e.exception))

    def test_health(self):
        health = self.proven.health()
        self.assertEqual((health["available"], health["prover"], health["chain_match"]), (True, "fake", True))
        self.view = view(match=False)
        self.assertFalse(self.proven.health()["available"])

        def down():
            raise snip36.Snip36Error("RPC down")

        unread = snip36.Snip36(self.runner, self.prover, self.chain, down, 0xB0, level_felts=lambda n: LEVEL)
        self.assertEqual((unread.health()["available"], unread.health()["chain_match"]), (True, None))


if __name__ == "__main__":
    unittest.main()
