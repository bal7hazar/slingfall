#!/usr/bin/env python3
"""Tests of the P1 tooling (standard library `unittest`):

    python3 tools/prove/test_prove.py                         # decoding tests (no prover needed)
    PROVE_RUN=<dir> python3 tools/prove/test_prove.py         # + tamper tests on a prove.py run

The tamper tests take a whole-level `prove.py` directory (`main.proof.bin`, `outputs.json`):
`verify.py` accepts it, and rejects a copy of `outputs.json` with one output, the program hash or
the level felts changed.
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
import proofdata  # noqa: E402

RUN = os.environ.get("PROVE_RUN")


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


if __name__ == "__main__":
    unittest.main()
