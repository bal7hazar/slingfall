"""Unit tests of the encoding helpers and the request builder (lot E3a). Offline; from anywhere:

    python3 -m unittest discover -s tools/atlantic -p 'test_*.py'

The fact-chain tests replay the committed runs (`fixtures/proofs/atlantic/<case>.json`: Atlantic's output and
facts, our outputs and arguments) through `encoding.py`.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import atlantic  # noqa: E402
import encoding  # noqa: E402

PROOFS = HERE.parents[1] / "fixtures" / "proofs" / "atlantic"
CASES = ["one_block-miss", "pile10-reference"]

# A verification read on Integrity's Sepolia FactRegistry on 2026-09-26 (event `FactRegistered`
# of tx 0x2abd1c724bad04717dace7c3a43679f7624ce131b54a9b2d332fdb7fba8b438, block 15653468).
ONCHAIN_FACT = 0x28F151C76E4EDA65AE06BA04D2524FAF8F310732E76E4AF43564560D35468A1
ONCHAIN_VERIFICATION = 0x11CCD33719B01F02D7B33AAC564F76126F5C05201E23EB6303D24AA24480E4D
ONCHAIN_ANSWER = [
    1, ONCHAIN_VERIFICATION, 60, encoding.short_string("recursive_with_poseidon"),
    encoding.short_string("keccak_160_lsb"), encoding.short_string("stone6"), encoding.short_string("strict"),
]


def load_case(name: str) -> dict:
    return json.loads((PROOFS / f"{name}.json").read_text())


def felts(values: list[str]) -> list[int]:
    return [int(v, 0) for v in values]


class Keccak(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(encoding.keccak256(b"").hex(),
                         "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    def test_rate_boundary(self):
        # 135 bytes: the padding fits the block; 136 bytes: a second, padding-only block.
        self.assertNotEqual(encoding.keccak256(b"a" * 136), encoding.keccak256(b"a" * 135))
        self.assertEqual(len(encoding.keccak256(b"a" * 300)), 32)

    def test_selectors(self):
        self.assertEqual(encoding.selector("transfer"),
                         0x83AFD3F4CAEDC6EEBF44246FE54E38C95E3179A5EC9EA81740ECA5B482D12E)
        self.assertEqual(encoding.selector("get_all_verifications_for_fact_hash"),
                         0x3731D7667BF026B9960BF90DAEF8B575526345DEB176F45E77FCE4127CB8028)
        # The key of Integrity's `FactRegistered` events (read on Sepolia).
        self.assertEqual(encoding.selector("FactRegistered"),
                         0x21B498A3D76B147FD095B60BBE6BBC014F2890642D9BD64CEF63F8FF5BF3FAB)


class Pedersen(unittest.TestCase):
    def test_points_on_curve(self):
        self.assertTrue(all(encoding._on_curve(p) for p in encoding._POINTS))

    def test_vectors(self):
        self.assertEqual(encoding.pedersen(0, 0), encoding._POINTS[0][0])
        # starkware crypto test vector.
        self.assertEqual(
            encoding.pedersen(0x3D937C035C878245CAF64531A5756109C53068DA139362728FEB561405371CB,
                              0x208A0A10250E382E1E4BBE2880906C2791BF6275695E02FBBC6AEFF9CD8B31A),
            0x30E480BED5FE53FA909CC0F8C4D99B8F9F2C016BE4C41E13A4848797979C662)

    def test_hash_chain_order(self):
        a, b, c = 3, 5, 7
        self.assertEqual(encoding.pedersen_hash_chain([a, b, c]), encoding.pedersen(a, encoding.pedersen(b, c)))

    def test_program_hash_header(self):
        # `[len(chain), version, main, n_builtins, builtins..., data...]`.
        chain = [0, 4, 1, encoding.short_string("output"), 9, 8]
        self.assertEqual(encoding.program_hash_pedersen(["output"], 4, [9, 8]),
                         encoding.pedersen_hash_chain([len(chain), *chain]))


class Hashes(unittest.TestCase):
    def test_fact_hash_is_poseidon_of_program_and_output_hash(self):
        out = [1, 2, 3]
        self.assertEqual(encoding.fact_hash(7, out), encoding.poseidon_many([7, encoding.poseidon_many(out)]))
        self.assertNotEqual(encoding.fact_hash(7, out), encoding.fact_hash(7, [10, *out]))

    def test_bootloader_output(self):
        self.assertEqual(encoding.bootloader_output(0xABC, [5, 6]), [1, 4, 0xABC, 5, 6])
        self.assertEqual(encoding.bootloaded_fact_hash(9, 0xABC, [5, 6]), encoding.fact_hash(9, [1, 4, 0xABC, 5, 6]))

    def test_task_and_atlantic_output(self):
        task = encoding.task_output([11, 12], [7, 8, 9])
        self.assertEqual(task, [0, 2, 11, 12, 3, 7, 8, 9])
        self.assertEqual(encoding.atlantic_output(0xC, task), [0, encoding.pedersen(0, 0), 1, 10, 0xC, *task])

    def test_negative_felts_reduce_mod_p(self):
        self.assertEqual(encoding.poseidon_many([-1]), encoding.poseidon_many([encoding.P - 1]))

    def test_verification_hash_onchain_vector(self):
        config = encoding.verifier_config_hash("recursive_with_poseidon", "keccak_160_lsb", "stone6", "strict")
        self.assertEqual(encoding.verification_hash(ONCHAIN_FACT, config, 60), ONCHAIN_VERIFICATION)


class FactChain(unittest.TestCase):
    """Atlantic's `metadata.json` of each committed run, re-derived from our outputs and arguments."""

    def test_cases(self):
        for name in CASES:
            with self.subTest(case=name):
                case = load_case(name)
                run, atl = case["run"], case["atlantic"]
                child = int(run["child_program_hash"], 16)
                boot = int(atl["bootloader_program_hash"], 16)
                self.assertEqual(boot, encoding.ATLANTIC_BOOTLOADER_PROGRAM_HASH)
                out = encoding.atlantic_output(child, encoding.task_output(felts(case["outputs"]), felts(case["args"])))
                self.assertEqual(out, felts(atl["output"]))
                self.assertEqual(hex(encoding.sharp_fact_hash(boot, out)), atl["sharp_fact_hash"])
                self.assertEqual(hex(encoding.translated_fact_hash(boot, out)), atl["integrity_fact_hash"])
                facts = encoding.slingfall_fact(child, felts(case["outputs"]), felts(case["args"]))
                self.assertEqual(hex(facts["integrity_fact_hash"]), atl["integrity_fact_hash"])

    def test_one_output_felt_changes_the_fact(self):
        case = load_case(CASES[0])
        child = int(case["run"]["child_program_hash"], 16)
        outputs, args = felts(case["outputs"]), felts(case["args"])
        base = encoding.slingfall_fact(child, outputs, args)["integrity_fact_hash"]
        outputs[5] += 1  # the score
        self.assertNotEqual(encoding.slingfall_fact(child, outputs, args)["integrity_fact_hash"], base)


class Strings(unittest.TestCase):
    def test_short_string(self):
        self.assertEqual(encoding.short_string("stone6"), 0x73746F6E6536)
        self.assertEqual(encoding.decode_short_string(0x737472696374), "strict")
        self.assertEqual(encoding.decode_short_string(0x1FF), "0x1ff")
        with self.assertRaises(ValueError):
            encoding.short_string("x" * 32)


class Decode(unittest.TestCase):
    def test_onchain_answer(self):
        [v] = encoding.decode_verifications(ONCHAIN_ANSWER)
        self.assertEqual(v["verification_hash"], hex(ONCHAIN_VERIFICATION))
        self.assertEqual((v["security_bits"], v["layout"], v["hasher"], v["stone_version"], v["memory_verification"]),
                         (60, "recursive_with_poseidon", "keccak_160_lsb", "stone6", "strict"))

    def test_translated_answer(self):
        t = encoding.short_string("translated")
        [v] = encoding.decode_verifications([1, 0, 96, t, t, t, t])
        self.assertEqual((v["security_bits"], v["layout"], v["verification_hash"]), (96, "translated", "0x0"))

    def test_empty_and_malformed(self):
        self.assertEqual(encoding.decode_verifications([0]), [])
        with self.assertRaises(ValueError):
            encoding.decode_verifications([1, 2, 3])
        with self.assertRaises(ValueError):
            encoding.decode_verifications([])


class Submit(unittest.TestCase):
    def args(self, pie: str, size: str = "M") -> argparse.Namespace:
        return argparse.Namespace(size=size, layout="auto", result="PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION",
                                  network="TESTNET", cairo_version="cairo1", mock_fact=False, prover=None,
                                  external_id="case", pie=pie, program=None, input=None)

    def test_dedup_is_deterministic_and_covers_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            pie = Path(tmp) / "pie.zip"
            pie.write_bytes(b"PK\x03\x04 not really a zip")
            a, files = atlantic.submit_fields(self.args(str(pie)))
            b, _ = atlantic.submit_fields(self.args(str(pie)))
            c, _ = atlantic.submit_fields(self.args(str(pie), size="L"))
            self.assertEqual(a["dedupId"], b["dedupId"])
            self.assertNotEqual(a["dedupId"], c["dedupId"])
            self.assertNotIn("sharpProver", a)
            self.assertEqual(files, {"pieFile": pie})

    def test_multipart(self):
        with tempfile.TemporaryDirectory() as tmp:
            pie = Path(tmp) / "pie.zip"
            pie.write_bytes(b"ZIPDATA")
            body, ctype = atlantic.multipart({"layout": "auto"}, {"pieFile": pie})
            boundary = ctype.split("boundary=")[1]
            self.assertTrue(body.startswith(f"--{boundary}\r\n".encode()))
            self.assertTrue(body.endswith(f"--{boundary}--\r\n".encode()))
            self.assertIn(b'name="layout"\r\n\r\nauto\r\n', body)
            self.assertIn(b'name="pieFile"; filename="pie.zip"\r\nContent-Type: application/zip\r\n\r\nZIPDATA\r\n', body)

    def test_c1_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            src, dst = Path(tmp) / "args.json", Path(tmp) / "input.txt"
            src.write_text(json.dumps(["0x2", "0x5", "-0x1"]))
            atlantic.cmd_c1_input(argparse.Namespace(args=str(src), out=str(dst)))
            self.assertEqual(dst.read_text(), f"[2 5 {encoding.P - 1}]\n")


if __name__ == "__main__":
    unittest.main()
