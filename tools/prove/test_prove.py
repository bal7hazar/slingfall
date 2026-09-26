#!/usr/bin/env python3
"""Tests of the P1 / P1b tooling (standard library `unittest`):

    python3 tools/prove/test_prove.py                         # decoding and chain-link tests (no prover)
    PROVE_RUN=<dir> python3 tools/prove/test_prove.py         # + tamper tests on prove.py runs

The tamper tests take a whole-level `prove.py` directory (`main.proof.bin`, `outputs.json`):
`verify.py` accepts it, and rejects a copy of `outputs.json` with one output, the program hash or
the level felts changed.

With `PROVE_RUN`, the chain tamper tests (lot P1b) also prove `one_block-miss` in chunks of
`--k 16` into `<PROVE_RUN>-k16` (unless it holds a run already; `PROVE_CHAIN=<dir>` names another
directory, `PROVE_CHAIN=skip` skips them): `verify.py --run` accepts it, and rejects a copy in
which a middle chunk was proven on a fabricated state (a score of 10 000) and every later proof
was proven honestly from there: valid proofs, consistent outputs, one broken link.
"""

from __future__ import annotations

import bz2
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "tools" / "levelc"))
import poseidon  # noqa: E402
import proofdata  # noqa: E402
import verify  # noqa: E402

RUN = os.environ.get("PROVE_RUN")
CHAIN = os.environ.get("PROVE_CHAIN") or (f"{RUN.rstrip('/')}-k16" if RUN else None)
FABRICATED_SCORE = 10_000


def section(values: list[int], first_id: int = 7) -> bytes:
    b = struct.pack("<Q", len(values))
    for i, v in enumerate(values):
        b += struct.pack("<9I", first_id + i, *proofdata.int_to_limbs(v))
    return b


def fake_proof(program: list[int], output: list[int], present: list[bool]) -> bytes:
    """The bincode prefix of a `CairoProofForRustVerifier` (public memory), then filler."""
    b = section(program)
    b += struct.pack("<4I", 1, 100, 2, 100 + len(output))  # output SegmentRange
    for p in present:
        b += b"\x01" + struct.pack("<4I", 3, 200, 4, 210) if p else b"\x00"
    b += section(output, 1000) + struct.pack("<2I", 5, 6) + b"\xff" * 64
    return bz2.compress(b)


class Decoding(unittest.TestCase):
    def test_binary_public_memory(self):
        program = [0x40780017FFF7FFF, 2**63, proofdata.P - 1, 0]
        output = [3, 0x5C2FACD32B8C47FFD8909D04D73808BBF5967F1BB3A4AE762D2637FBE9E0431, 0, 120]
        present = [False, True, False, True, False, False, False, True, False, False]
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "p.proof.bin"
            path.write_bytes(fake_proof(program, output, present))
            mem = proofdata.read_public_memory(path)
        self.assertEqual(mem["program"], program)
        self.assertEqual(mem["output"], output)
        self.assertEqual(proofdata.returned_felts(output), output[1:])

    def test_json_public_memory(self):
        doc = {"claim": {"public_data": {"public_memory": {
            "program": [[1, proofdata.int_to_limbs(5)]], "output": [[9, proofdata.int_to_limbs(1)], [10, proofdata.int_to_limbs(42)]],
        }}}}
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "p.proof.json"
            path.write_text(json.dumps(doc))
            mem = proofdata.read_public_memory(path)
        self.assertEqual(mem, {"program": [5], "output": [1, 42]})

    def test_bad_option_tag(self):
        b = bz2.decompress(fake_proof([1], [0], [False] * 10))
        b = b[: 8 + 36 + 16] + b"\x02" + b[8 + 36 + 17 :]
        with self.assertRaises(proofdata.ProofDataError):
            proofdata.parse_binary_public_memory(b)

    def test_returned_felts_layout(self):
        with self.assertRaises(proofdata.ProofDataError):
            proofdata.returned_felts([0, 10, 1])  # a panic flag first is not the scarb 2.19 layout
        self.assertEqual(proofdata.returned_felts([0]), [])

    def test_program_hash_encoding(self):
        # Small and large felts take different encodings: the hashes differ and are stable.
        a, b = proofdata.program_hash([1, 2]), proofdata.program_hash([1, 2 + 2**63])
        self.assertNotEqual(a, b)
        self.assertLess(a, proofdata.P)
        self.assertEqual(a, proofdata.program_hash([1, 2]))

    def test_executable_bytecode(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "x.executable.json"
            path.write_text(json.dumps({"program": {"bytecode": ["0x1", "0xa", "-0xc"]}, "entrypoints": []}))
            self.assertEqual(proofdata.executable_bytecode(path), [1, 10, proofdata.P - 12])


class Header(unittest.TestCase):
    def test_split_public_output(self):
        self.assertEqual(proofdata.split_public_output("init", [9, 1, 0]), {"level_hash": 9, "state": [1, 0]})
        self.assertEqual(proofdata.split_public_output("step_chunk", [5, 6, 0, 16, 1]),
                         {"state_in_hash": 5, "inputs_hash": 6, "shot": 0, "k": 16, "state": [1]})
        self.assertEqual(proofdata.split_public_output("outputs", [5, 6, *range(10)]),
                         {"state_in_hash": 5, "inputs_hash": 6, "outputs": list(range(10))})
        self.assertEqual(proofdata.split_public_output("main", list(range(10))), {"outputs": list(range(10))})
        with self.assertRaises(proofdata.ProofDataError):
            proofdata.split_public_output("step_chunk", [1, 2, 3])
        with self.assertRaises(proofdata.ProofDataError):
            proofdata.split_public_output("main_trace", [])

    def test_level_hash_golden(self):
        # `init`'s LEVEL_HASH is Poseidon over the level felts, no length prefix: pile10's is the
        # Cairo golden `PILE10_HASH` (the state hash's golden, `PILE10_INIT_STATE_HASH` in
        # `slingfall_game::chunk::tests`, was computed with this same `poseidon.hash_span`).
        sys.path.insert(0, str(HERE.parents[1] / "tools" / "tracec"))
        import tracec
        felts = tracec.load_level_felts(HERE.parents[1] / "fixtures" / "levels" / "pile10.felts.json")
        self.assertEqual(poseidon.hash_span([v % proofdata.P for v in felts]),
                         0x17876831F245E0EC3D63220F2CB73C429EC93E7C888C2AA916D237CD9C114A3)


def state(shots_used: int, over: int, tick: int, score: int, tail: int) -> list[int]:
    """A stand-in `ChunkState`: its 7-felt header, then one felt for the rest."""
    return [1, shots_used, over, 0, 0, tick, score, tail]


class Chain(unittest.TestCase):
    """`verify.check_chain` on synthetic public outputs (no prover): one shot in two chunks."""

    INPUTS = [0x706C61796572, 1, proofdata.P - 604, proofdata.P - 392, 0, 0]
    LEVEL_HASH = 0x1234

    def links(self, s0=None, s1=None, s2=None, fake_s1=None):
        h, ih = poseidon.hash_span, poseidon.hash_span(self.INPUTS)
        s0 = s0 or state(0, 0, 0, 0, 7)
        s1 = s1 or state(0, 0, 16, 0, 8)
        s2 = s2 or state(1, 0, 20, 50, 9)
        outputs = [1, self.LEVEL_HASH, 0, self.INPUTS[0], ih, s2[6], 0, s2[1], s2[5], 0xF1]
        return [
            ("init", [self.LEVEL_HASH, *s0]),
            ("step_chunk", [h(s0), ih, 0, 16, *s1]),
            ("step_chunk", [h(fake_s1 or s1), ih, 0, 16, *s2]),
            ("outputs", [h(s2), ih, *outputs]),
        ]

    def rejects(self, links, message: str):
        with self.assertRaisesRegex(verify.ChainError, message):
            verify.check_chain(links, self.INPUTS)

    def test_accepts_an_honest_chain(self):
        self.assertEqual(verify.check_chain(self.links(), self.INPUTS)[5], 50)

    def test_rejects_a_middle_chunk_proven_on_a_fabricated_state(self):
        # chunk01 was run on chunk00's state with a score of 10 000: its proof is valid, its
        # STATE_IN_HASH is not chunk00's state's.
        self.rejects(self.links(fake_s1=state(0, 0, 16, 10_000, 8)), "chunk01: STATE_IN_HASH")

    def test_rejects_a_dropped_chunk(self):
        links = self.links()
        self.rejects([links[0], links[2], links[3]], "chunk00: STATE_IN_HASH")

    def test_rejects_outputs_on_another_state(self):
        links = self.links()
        self.rejects([*links[:3], ("outputs", [links[3][1][0] + 1, *links[3][1][1:]])], "outputs: STATE_IN_HASH")

    def test_rejects_other_inputs(self):
        links = self.links()
        name, out = links[1]
        self.rejects([links[0], (name, [out[0], out[1] + 1, *out[2:]]), *links[2:]], "chunk00: INPUTS_HASH")
        with self.assertRaisesRegex(verify.ChainError, "inputs_hash is not the hash"):
            verify.check_chain(links, [*self.INPUTS[:-1], 1])

    def test_rejects_another_shot(self):
        links = self.links()
        name, out = links[1]
        self.rejects([links[0], (name, [*out[:2], 1, *out[3:]]), *links[2:]], "chunk00: shot 1")

    def test_rejects_another_level(self):
        links = self.links()
        self.rejects([("init", [self.LEVEL_HASH + 1, *links[0][1][1:]]), *links[1:]], "LEVEL_HASH")

    def test_rejects_a_chain_that_stops_early(self):
        # Outputs taken on chunk00's state (the shot still in progress), every link honest.
        h, ih = poseidon.hash_span, poseidon.hash_span(self.INPUTS)
        links = self.links()
        s1 = links[1][1][4:]
        outputs = [1, self.LEVEL_HASH, 0, self.INPUTS[0], ih, 0, 0, 0, 16, 0xF1]
        self.rejects([*links[:2], ("outputs", [h(s1), ih, *outputs])], "stops before the level is over")

    def test_rejects_a_misordered_chain(self):
        links = self.links()
        self.rejects(links[1:], "a chain is init")
        self.rejects([links[0], links[3], links[1]], "a chain is init")


@unittest.skipUnless(RUN, "PROVE_RUN=<a whole-level prove.py directory> for the tamper tests")
class Tamper(unittest.TestCase):
    def verify(self, outputs: Path) -> int:
        return subprocess.run([sys.executable, str(HERE / "verify.py"), str(Path(RUN) / "main.proof.bin"),
                               str(outputs)]).returncode

    def tampered(self, change) -> int:
        doc = json.loads((Path(RUN) / "outputs.json").read_text())
        change(doc)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "outputs.json"
            path.write_text(json.dumps(doc))
            return self.verify(path)

    def test_accepts_the_run(self):
        self.assertEqual(self.verify(Path(RUN) / "outputs.json"), 0)

    def test_rejects_a_changed_score(self):
        def change(doc):
            doc["outputs"][5] = hex(int(doc["outputs"][5], 16) + 1)
        self.assertEqual(self.tampered(change), 1)

    def test_rejects_a_changed_program_hash(self):
        def change(doc):
            doc["program_hash"] = hex(int(doc["program_hash"], 16) ^ 1)
        self.assertEqual(self.tampered(change), 1)

    def test_rejects_other_level_felts(self):
        def change(doc):
            doc["level_felts"][-1] = hex(int(doc["level_felts"][-1], 16) + 1)
        self.assertEqual(self.tampered(change), 1)

    def test_rejects_a_truncated_proof(self):
        with tempfile.TemporaryDirectory() as d:
            proof = Path(d) / "main.proof.bin"
            shutil.copy(Path(RUN) / "main.proof.bin", proof)
            proof.write_bytes(proof.read_bytes()[:-4096])
            code = subprocess.run([sys.executable, str(HERE / "verify.py"), str(proof),
                                   str(Path(RUN) / "outputs.json")]).returncode
        self.assertNotEqual(code, 0)


def fabricate(state: list[int], score: int) -> list[int]:
    """`state` with its score set to `score`: the header's (felt 6) and the game's. The game's is
    the felt before `shots_used` and `tick` near the end of `GameState` (`score, shots_used, tick,
    shot_tick, pebble, ...`), found by those three values."""
    tail = len(state) - 16
    at = [j for j in range(tail, len(state) - 2)
          if state[j:j + 3] == [state[6], state[1], state[5]]]
    if len(at) != 1:
        raise AssertionError(f"GameState.score not found unambiguously: {at}")
    out = list(state)
    out[6] = out[at[0]] = score
    return out


@unittest.skipUnless(RUN and CHAIN != "skip", "PROVE_RUN=<dir> for the chain tamper tests")
class ChainTamper(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.run_dir = Path(CHAIN)
        if not (cls.run_dir / "outputs.json").exists():
            subprocess.run([sys.executable, str(HERE / "prove.py"), "--case", "one_block-miss", "--k", "16",
                            "--out", str(cls.run_dir)], check=True)

    def verify_run(self, run: Path) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(HERE / "verify.py"), "--run", str(run)],
                              capture_output=True, text=True)

    def test_accepts_the_chain(self):
        r = self.verify_run(self.run_dir)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("linked by their public headers", r.stdout)

    def test_rejects_a_middle_chunk_proven_on_a_fabricated_state(self):
        import prove
        chunks = verify.run_proofs(self.run_dir)[1:-1]
        self.assertGreaterEqual(len(chunks), 3)
        m = len(chunks) - 2  # a middle chunk: one chunk before it at least, one after
        doc = json.loads((self.run_dir / "outputs.json").read_text())
        inputs = [verify.felt(v) for v in doc["inputs_felts"]]
        with tempfile.TemporaryDirectory() as d:
            run = Path(d)
            for p in [self.run_dir / "init.proof.bin", *chunks[:m]]:
                shutil.copy(p, run / p.name)
            before = verify.public_claims(chunks[m - 1])["returned"]
            state = fabricate(proofdata.split_public_output("step_chunk", before)["state"], FABRICATED_SCORE)
            prover = prove.Prover(run, verify.DEFAULT_BIN, prove.EXECUTABLES, prove.PARAMS)
            i, shot = m, state[1]
            while state[1] == shot and state[2] == 0:
                state = prover.prove(f"chunk{i:02d}", "step_chunk",
                                     [len(state), *state, len(inputs), *inputs, shot, 16, 0])["state"]
                i += 1
            outputs = prover.prove("outputs", "outputs", [len(state), *state, len(inputs), *inputs])["outputs"]
            self.assertEqual(outputs[5], FABRICATED_SCORE)
            (run / "outputs.json").write_text(json.dumps({**doc, "outputs": [hex(v) for v in outputs]}))
            r = self.verify_run(run)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(f"chunk{m:02d}: STATE_IN_HASH is not the hash of the previous proof's state", r.stderr)


if __name__ == "__main__":
    unittest.main()
