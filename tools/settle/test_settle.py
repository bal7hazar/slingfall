#!/usr/bin/env python3
"""Unit tests of the settle tool that need no Cairo (`python3 tools/settle/test_settle.py`), and the
round trip through the replay executables when asked: `SETTLE_ROUND_TRIP=fixtures/levels/tower.json
python3 tools/settle/test_settle.py` (settling an already settled level moves no pose)."""

import json
import os
import sys
import unittest
from decimal import Decimal
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import settle  # noqa: E402  (puts tools/levelc on the path)
import levelc  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def level(*bodies) -> dict:
    ground = {"kind": "static", "shape": {"type": "half_space", "normal": {"x": 0, "y": 1}},
              "pose": {"x": 0, "y": 0, "angle_deg": 0}, "material": 0}
    return levelc.canonical(levelc.parse_json(json.dumps({
        "version": 1, "level_id": 1, "seed": 0, "gravity_y": -9.81, "shots": 1, "tick_cap": 200,
        "bounds": {"min_x": -10, "min_y": -10, "max_x": 50, "max_y": 40}, "sling_anchor": {"x": 3, "y": 2.5},
        "pull_radius": 1024, "launch_scale": 0.02, "projectiles": [0],
        "materials": [{"density": 1, "friction": 0.6, "restitution": 0.1, "hp": 100, "force_threshold": 40,
                       "damage_per_impulse_dt": 1, "score": 50}],
        "bodies": [ground, *bodies],
    })))


def block(x, y, hx=0.5, hy=0.5, angle=0, kind="block") -> dict:
    return {"kind": kind, "shape": {"type": "cuboid", "hx": hx, "hy": hy},
            "pose": {"x": x, "y": y, "angle_deg": angle}, "material": 0}


def ball(x, y, r=0.4) -> dict:
    return {"kind": "core", "shape": {"type": "ball", "radius": r}, "pose": {"x": x, "y": y, "angle_deg": 0},
            "material": 0}


class Geometry(unittest.TestCase):
    def test_boxes(self):
        lv = level(block(10, 0.5), ball(10, 1.4), block(20, 1, 1, 0.5, 90))
        self.assertEqual(settle.box_of(lv["bodies"][1]), tuple(map(Fraction, ("9.5", 0, "10.5", 1))))
        self.assertEqual(settle.box_of(lv["bodies"][2]), tuple(map(Fraction, ("9.6", 1, "10.4", "1.8"))))
        self.assertEqual(settle.box_of(lv["bodies"][3]), tuple(map(Fraction, ("19.5", 0, "20.5", 2))))  # a 2 x 1 block turned upright

    def test_piles_group_touching_bodies_and_order_them_left_to_right(self):
        lv = level(block(30, 0.5), block(30, 1.5), block(10, 0.5), ball(10, 1.4), block(20, 0.5))
        self.assertEqual(settle.piles(lv), [[3, 4], [5], [1, 2]])

    def test_a_gap_over_two_centimetres_separates_piles(self):
        self.assertEqual(len(settle.piles(level(block(10, 0.5), block(11.03, 0.5)))), 2)
        self.assertEqual(len(settle.piles(level(block(10, 0.5), block(11.01, 0.5)))), 1)

    def test_wake_touches_the_leftmost_body_reaching_the_ground(self):
        lv = level(block(10, 0.5), block(9.5, 1.5), block(11, 0.5))
        pile = settle.piles(lv)[0]
        self.assertEqual(settle.wake_position(lv, pile), (Fraction(37, 4), Fraction(1, 4)))

    def test_no_flat_ground_needs_a_wake_position(self):
        lv = level(block(10, 0.5))
        lv["bodies"][0]["kind"] = "block"
        with self.assertRaises(settle.SettleError):
            settle.ground_level(lv)


class Snap(unittest.TestCase):
    ONE = 1 << 32

    def raw(self, v) -> int:
        return levelc.to_raw(Decimal(str(v)))

    def test_rounds_to_the_step_and_to_a_tenth_of_a_degree(self):
        x, y, re, im = settle.snap(self.raw(20.0004), self.raw(0.4992), self.ONE - 3, 12000, settle.DEFAULT_STEP)
        self.assertEqual((x, y), (self.raw(20), self.raw(0.499)))
        self.assertEqual((re, im), (self.ONE, 0))  # 0.0007 degree: upright

    def test_snapping_is_idempotent(self):
        once = settle.snap(self.raw(3.14159), self.raw(2.71828), 2986345000, 3084090000, settle.DEFAULT_STEP)
        self.assertEqual(settle.snap(*once, settle.DEFAULT_STEP), once)

    def test_step_zero_keeps_the_pose(self):
        self.assertEqual(settle.snap(5, 6, 7, 8, Fraction(0)), (5, 6, 7, 8))

    def test_roll_pull_is_about_one_metre_per_second(self):
        self.assertEqual(settle.roll_pull(level(block(10, 0.5))), 50)  # launch_scale 0.02


@unittest.skipUnless(os.environ.get("SETTLE_ROUND_TRIP"), "needs the built replay executables (SETTLE_ROUND_TRIP=level.json)")
class RoundTrip(unittest.TestCase):
    def test_settling_a_settled_level_moves_no_pose(self):
        path = Path(os.environ["SETTLE_ROUND_TRIP"])
        first, _ = settle.settle(levelc.load_level(path), 120, [], 6, settle.DEFAULT_STEP, lambda *_: None)
        again, history = settle.settle(first, 120, [], 1, settle.DEFAULT_STEP, lambda *_: None)
        self.assertEqual(levelc.level_to_felts(again), levelc.level_to_felts(first))
        self.assertTrue(all(r["moved"] == 0 for r in history[-1]))


if __name__ == "__main__":
    unittest.main()
