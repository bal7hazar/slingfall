#!/usr/bin/env python3
"""Unit tests of levelc (standard library `unittest`): python3 tools/levelc/test_levelc.py"""

import argparse
import sys
import tempfile
import unittest
from decimal import Decimal as D
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import levelc  # noqa: E402
import poseidon  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = sorted((ROOT / "fixtures" / "levels").glob("*.json"))
LEVELS = [p for p in FIXTURES if not p.name.endswith(".felts.json")]
# The levels of `crates/slingfall_level/src/level/fixtures.cairo`: the Cairo unit tests know these
# only; the levels added since (lot G8: tower, bridge, twin) have JSON, felts and goldens
# (`fixtures/golden`), and get their Cairo module the day a crate needs them.
CAIRO_LEVELS = [p for p in LEVELS if p.stem in ("cores3", "one_block", "pile10")]
P = levelc.P


class Scalars(unittest.TestCase):
    def test_round_half_to_even(self):
        half = D(1) / D(2**33)  # exactly half a raw unit
        self.assertEqual(levelc.to_raw(half), 0)  # 0.5 -> 0 (even)
        self.assertEqual(levelc.to_raw(3 * half), 2)  # 1.5 -> 2 (even)
        self.assertEqual(levelc.to_raw(5 * half), 2)  # 2.5 -> 2 (even)
        self.assertEqual(levelc.to_raw(-3 * half), -2)
        self.assertEqual(levelc.to_raw(-5 * half), -2)

    def test_common_values(self):
        self.assertEqual(levelc.to_raw(D("0.5")), 1 << 31)
        self.assertEqual(levelc.to_raw(D("-9.81")), -42133629174)
        self.assertEqual(levelc.to_raw(D("0.02")), 85899346)
        self.assertEqual(levelc.to_raw(3), 3 << 32)

    def test_range(self):
        self.assertEqual(levelc.to_raw(D(2**31 - 1)), (2**31 - 1) << 32)
        with self.assertRaises(levelc.LevelError):
            levelc.to_raw(D(2**31))

    def test_negative_is_p_minus_x(self):
        self.assertEqual(levelc.fixed_felt(-1), P - 1)
        self.assertEqual(levelc.felt_fixed(P - 1), -1)
        for raw in (0, 1, -1, 2**63 - 1, -(2**63)):
            self.assertEqual(levelc.felt_fixed(levelc.fixed_felt(raw)), raw)

    def test_shortest_decimal_round_trips(self):
        for text in ("0.1", "-9.81", "0.02", "0.6", "1234.5", "0.3333333333"):
            raw = levelc.to_raw(D(text))
            self.assertEqual(levelc.to_raw(levelc.from_raw(raw)), raw)
        self.assertEqual(levelc.from_raw(levelc.to_raw(D("0.1"))), D("0.1"))
        self.assertEqual(levelc.from_raw(1 << 31), D("0.5"))

    def test_rotation_multiples_of_90_are_exact(self):
        one = 1 << 32
        self.assertEqual(levelc.rotation_raw(0), (one, 0))
        self.assertEqual(levelc.rotation_raw(90), (0, one))
        self.assertEqual(levelc.rotation_raw(180), (-one, 0))
        self.assertEqual(levelc.rotation_raw(-90), (0, -one))
        self.assertEqual(levelc.rotation_raw(450), (0, one))

    def test_rotation_45_and_30(self):
        re, im = levelc.rotation_raw(45)
        self.assertEqual((re, im), (3037000500, 3037000500))  # round(sqrt(2)/2 * 2^32)
        self.assertEqual(levelc.rotation_raw(30), (3719550787, 1 << 31))
        self.assertEqual(levelc.rotation_raw(60), (1 << 31, 3719550787))


class Poseidon(unittest.TestCase):
    def test_hash_span_matches_the_cairo_goldens(self):
        # `poseidon_hash_span` values checked against Cairo by the `slingfall_level` tests.
        self.assertEqual(
            poseidon.hash_span([0x1234, 1, P - 100, 200, 3, 0]),
            0x4E24633B5C10CDB028CC0754ECEB282D75631FB8A416890DEA0E4EF604E45A0,
        )

    def test_fixture_hashes_are_the_cairo_goldens(self):
        cairo = (ROOT / "crates/slingfall_level/src/level/fixtures.cairo").read_text()
        for path in CAIRO_LEVELS:
            felts = levelc.level_to_felts(levelc.load_level(path))
            golden = f"{path.stem.upper()}_HASH:felt252={hex(poseidon.hash_span(felts))};"
            self.assertIn(golden, "".join(cairo.split()))


class Levels(unittest.TestCase):
    def test_fixtures_check(self):
        for path in LEVELS:
            levelc.check_one(path, strict=False)

    def test_round_trip_is_the_identity(self):
        for path in LEVELS:
            felts = levelc.level_to_felts(levelc.load_level(path))
            level = levelc.felts_to_level(felts)
            self.assertEqual(levelc.level_to_felts(level), felts)
            self.assertEqual(levelc.canonical(level), level)

    def test_serialised_layout(self):
        felts = levelc.level_to_felts(levelc.load_level(ROOT / "fixtures/levels/one_block.json"))
        self.assertEqual(felts[:6], [1, 1, 0, P - 42133629174, 1, 360])
        self.assertEqual(len(felts), 72)

    def test_validation_messages(self):
        base = levelc.load_level(ROOT / "fixtures/levels/one_block.json")
        cases = [
            ({"version": 2}, "level: version"),
            ({"shots": 0, "projectiles": []}, "level: shots"),
            ({"shots": 2}, "level: shots"),
            ({"tick_cap": 361}, "level: tick cap"),
            ({"pull_radius": 1025}, "level: pull radius"),
            ({"bounds": {**base["bounds"], "min_x": D(50)}}, "level: bounds"),
            ({"sling_anchor": {"x": D(99), "y": D(0)}}, "level: bounds"),
        ]
        for patch, message in cases:
            with self.subTest(message=message, patch=patch):
                with self.assertRaisesRegex(levelc.LevelError, message):
                    levelc.validate_felts(levelc.level_to_felts({**base, **patch}))

    def test_pose_forms_agree(self):
        by_angle = {"x": D(1), "y": D(2), "angle_deg": D(90)}
        raw = {"x": D(1), "y": D(2), "re": D(0), "im": D(1)}
        self.assertEqual(levelc.pose_felts(by_angle), levelc.pose_felts(raw))
        with self.assertRaises(levelc.LevelError):
            levelc.pose_felts({**raw, "angle_deg": D(0)})

    def test_cairo_fixtures_are_current(self):
        want = levelc.cairo_fixtures(CAIRO_LEVELS)
        got = (ROOT / "crates/slingfall_level/src/level/fixtures.cairo").read_text()
        self.assertTrue(levelc.same_code(got, want))

    def test_to_cairo_check_flags_a_stale_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "fixtures.cairo"
            args = argparse.Namespace(levels=[str(p) for p in CAIRO_LEVELS], out=str(out), check=True)
            out.write_text("stale\n")
            with self.assertRaises(SystemExit):
                levelc.cmd_to_cairo(args)
            out.write_text(levelc.cairo_fixtures(CAIRO_LEVELS))
            levelc.cmd_to_cairo(args)


if __name__ == "__main__":
    unittest.main()
