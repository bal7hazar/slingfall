#!/usr/bin/env python3
"""settle: pre-settle a Slingfall level (docs/DESIGN.md D2: dynamic bodies are stored pre-settled and
start asleep; lot G8). Python 3 standard library + `scarb execute` (`crates/slingfall_replay`,
built: `scarb --manifest-path crates/slingfall_replay/Scarb.toml build`).

    settle.py <level.json> --ticks N --out settled.json [--wake X,Y]... [--rounds R] [--step S] [--quiet]

Adds nothing to Cairo. A level starts asleep (`GameTrait::new` sleeps every body), so a pile never
moves in a shot until something touches it, and there is no "step without a shot". The trick:
run `main_trace` on a *probe copy* of the level with `shots = 1`, `tick_cap = N`, one shot whose
pull rolls the pebble away at about 1 m/s (a pull of (0, 0) would let the calm rule end the shot
after 20 ticks, with the pile still creeping), and the sling anchor moved next to the pile: the
pebble is then launched on the ground, touching the outermost bottom block of a pile from the side (a horizontal contact that
carries no load), which wakes the pile's island. The pile settles under gravity until the game
ends the shot (every body asleep, or calm for 20 ticks, D5) or the cap `N`; the poses of the last
frame (raw Q32.32 felts, exact) are written back. The pebble is discarded; the level keeps its own
anchor, shots and cap.

A pebble wakes one island, so the dynamic bodies are grouped into piles (bodies whose boxes touch,
within 2 cm) and each pile is settled by its own probe run, from the poses the previous run left.
`--wake X,Y` (repeatable, one per pile in the order of the leftmost body) overrides the pebble
position when a pile is not standing on a flat ground (the automatic position needs a static
half space with a vertical normal and a block reaching down to the ground).

Rounds: one round settles every pile once; rounds repeat until a round moves no pose bit (a fixed
point, so settling a settled level is the identity), at most `--rounds` (default 6). The report
gives, per pile and round, the settle tick (first tick from which the whole pile is asleep), the
tick the shot ended on, the drift (sum of the displacement of the pile's bodies, in metres), and any
`damage` line (a pile that hurts itself while settling is a design fault, see docs/levels.md).
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import sys
from decimal import Decimal
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import replay  # noqa: E402
import levelc  # noqa: E402

PEBBLE_RADIUS = Fraction(1, 4)
TOUCH_MARGIN = Fraction(1, 50)  # piles: boxes closer than 2 cm are one pile
ONE = 1 << 32
DEFAULT_STEP = Fraction(1, 1000)  # `--step`


class SettleError(Exception):
    pass


# --------------------------------------------------------------------------- geometry (exact)

def pose_of(body: dict) -> tuple[Fraction, Fraction, Fraction, Fraction]:
    p = body["pose"]
    return Fraction(p["x"]), Fraction(p["y"]), Fraction(p["re"]), Fraction(p["im"])


def box_of(body: dict) -> tuple[Fraction, Fraction, Fraction, Fraction]:
    """Axis-aligned box (x0, y0, x1, y1) of a ball, cuboid or polygon body."""
    x, y, re, im = pose_of(body)
    shape = body["shape"]
    if shape["type"] == "ball":
        r = Fraction(shape["radius"])
        return x - r, y - r, x + r, y + r
    if shape["type"] == "cuboid":
        hx, hy = Fraction(shape["hx"]), Fraction(shape["hy"])
        ex, ey = abs(re) * hx + abs(im) * hy, abs(im) * hx + abs(re) * hy
        return x - ex, y - ey, x + ex, y + ey
    if shape["type"] == "polygon":
        pts = [(x + re * Fraction(p["x"]) - im * Fraction(p["y"]), y + im * Fraction(p["x"]) + re * Fraction(p["y"]))
               for p in shape["points"]]
        return min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)
    raise SettleError(f"a dynamic body cannot be a {shape['type']}")


def piles(level: dict) -> list[list[int]]:
    """Indices of the dynamic bodies grouped into touching piles, ordered by their leftmost box."""
    dyn = [i for i, b in enumerate(level["bodies"]) if b["kind"] != "static"]
    boxes = {i: box_of(level["bodies"][i]) for i in dyn}
    parent = {i: i for i in dyn}

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a in dyn:
        for b in dyn:
            if a < b:
                (ax0, ay0, ax1, ay1), (bx0, by0, bx1, by1) = boxes[a], boxes[b]
                if ax0 - TOUCH_MARGIN <= bx1 and bx0 - TOUCH_MARGIN <= ax1 \
                        and ay0 - TOUCH_MARGIN <= by1 and by0 - TOUCH_MARGIN <= ay1:
                    parent[find(a)] = find(b)
    groups: dict[int, list[int]] = {}
    for i in dyn:
        groups.setdefault(find(i), []).append(i)
    return sorted(groups.values(), key=lambda g: (min(boxes[i][0] for i in g), g[0]))


def ground_level(level: dict) -> Fraction:
    for b in level["bodies"]:
        s = b["shape"]
        if b["kind"] == "static" and s["type"] == "half_space" and Fraction(s["normal"]["x"]) == 0 \
                and Fraction(s["normal"]["y"]) == 1:
            return Fraction(b["pose"]["y"])
    raise SettleError("no flat ground (static half space, normal (0, 1)): give --wake X,Y")


def wake_position(level: dict, pile: list[int]) -> tuple[Fraction, Fraction]:
    """The pebble rests on the ground, its side touching the pile's leftmost body that reaches down
    to it: the contact is horizontal, so the pebble adds no load."""
    y = ground_level(level) + PEBBLE_RADIUS
    reach = [(box_of(level["bodies"][i])[0], i) for i in pile
             if box_of(level["bodies"][i])[1] <= y <= box_of(level["bodies"][i])[3]]
    if not reach:
        raise SettleError(f"no body of the pile reaches the ground: give --wake X,Y (bodies {pile})")
    return min(reach)[0] - PEBBLE_RADIUS, y


# --------------------------------------------------------------------------- probe

def probe_level(level: dict, wake: tuple[Fraction, Fraction], ticks: int) -> dict:
    """The level copy that wakes a pile: one shot, the anchor at the wake position."""
    probe = copy.deepcopy(level)
    probe["shots"], probe["projectiles"], probe["tick_cap"] = 1, [0], ticks
    probe["sling_anchor"] = {"x": levelc.from_raw(round(wake[0] * ONE)), "y": levelc.from_raw(round(wake[1] * ONE))}
    return probe


def roll_pull(level: dict) -> int:
    """Pull whose launch velocity is about 1 m/s to the left (`v = -pull * launch_scale`): the
    pebble rolls away from the pile and, never calming (no damping, D5), keeps the shot going for
    its 120 ticks of flight: the pile then sleeps by itself (D5 (1)) instead of being frozen by the
    20-tick calm rule while still creeping."""
    return min(int(level["pull_radius"]), max(1, math.ceil(1 / Fraction(level["launch_scale"]))))


def probe_run(level: dict, pile: list[int], wake: tuple[Fraction, Fraction], ticks: int) -> replay.Run:
    """`main_trace` on the probe; checks that the pile woke up and lost nothing."""
    felts = levelc.level_to_felts(probe_level(level, wake, ticks))
    run = replay.run("main_trace", felts, [(roll_pull(level), 0, 0)])
    if not any(not frame[h][4] for _, frame in run.frames for h in pile if h in frame):
        raise SettleError(f"the pebble at ({float(wake[0]):.4f}, {float(wake[1]):.4f}) woke no body of the pile {pile}")
    if run.destroyed:
        raise SettleError(f"bodies destroyed while settling: {run.destroyed}")
    return run


def snap(raw_x: int, raw_y: int, re: int, im: int, step: Fraction) -> tuple[int, int, int, int]:
    """Rounds a settled pose onto the authoring grid: x, y to multiples of `step` metres (default
    1 mm), the angle to 0.1 degree (`step = 0`: no snapping). Multiples of 90 degrees stay exact,
    and a pile authored with exact contacts (a block at y = 0.5 on the ground) stays authored: the
    solver's steady penetration (~1e-4 m) and creep are below half a cell. The rounding is what makes
    settling idempotent: a woken pile never returns to a bit-identical pose (its transient depends
    on the pebble that woke it and on the solver's rounding), but it does return to the same cell."""
    if step == 0:
        return raw_x, raw_y, re, im
    raw_x, raw_y = (round(round(Fraction(v, ONE) / step) * step * ONE) for v in (raw_x, raw_y))
    tenths = round(math.degrees(math.atan2(im, re)) * 10)
    re, im = levelc.rotation_raw(Fraction(tenths, 10))
    return raw_x, raw_y, re, im


def pose_raw(level: dict, i: int) -> tuple[int, int, int, int]:
    p = level["bodies"][i]["pose"]
    return tuple(levelc.to_raw(p[k]) for k in ("x", "y", "re", "im"))


def settle_pile(level: dict, pile: list[int], wake: tuple[Fraction, Fraction], ticks: int, step: Fraction) -> dict:
    """Settles one pile in place; returns its report."""
    run = probe_run(level, pile, wake, ticks)
    _, last = run.frames[-1]
    if not all(last[i][4] for i in pile):
        raise SettleError(f"the pile {pile} is still awake at tick {run.frames[-1][0]}: raise --ticks")
    before = {i: pose_raw(level, i) for i in pile}
    # Settle tick: the first tick from which the whole pile stays asleep (D5 (1)).
    settle_tick = next(tick for tick, frame in reversed(run.frames) if not all(frame[i][4] for i in pile)) + 1
    drift = Fraction(0)
    moved = 0
    for i in pile:
        x, y, re, im = snap(*last[i][:4], step)
        for key, raw in zip(("x", "y", "re", "im"), (x, y, re, im)):
            level["bodies"][i]["pose"][key] = levelc.from_raw(raw)
        dx, dy = x - before[i][0], y - before[i][1]
        drift += Fraction(math.isqrt(dx * dx + dy * dy), ONE)
        moved += (x, y, re, im) != before[i]
    return {
        "bodies": len(pile), "settle_tick": settle_tick, "shot_end": run.shot_end, "moved": moved,
        "drift": float(drift), "damage": run.damage, "steps": run.steps,
    }


def settle(level: dict, ticks: int, wakes: list[tuple[Fraction, Fraction]], rounds: int, step: Fraction, log) -> tuple[dict, list]:
    level = levelc.canonical(level)  # poses as re / im
    groups = piles(level)
    if wakes and len(wakes) != len(groups):
        raise SettleError(f"--wake given {len(wakes)} times, the level has {len(groups)} piles")
    if not groups:
        raise SettleError("the level has no dynamic body")
    history = []
    for n in range(1, rounds + 1):
        reports = []
        for k, pile in enumerate(groups):
            wake = wakes[k] if wakes else wake_position(level, pile)
            report = settle_pile(level, pile, wake, ticks, step)
            report.update(round=n, pile=k, indices=pile)
            reports.append(report)
            log(f"round {n} pile {k} ({len(pile)} bodies): settle tick {report['settle_tick']}, shot ended tick "
                f"{report['shot_end']}, drift {report['drift']:.6f} m, moved {report['moved']} bodies, "
                f"{report['steps']:,} steps"
                + (f" [DAMAGE {report['damage']}]" if report["damage"] else ""))
        history.append(reports)
        if all(r["moved"] == 0 for r in reports):
            return level, history
    log(f"warning: not a fixed point after {rounds} rounds")
    return level, history


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("level")
    ap.add_argument("--ticks", type=int, required=True, help="tick cap of the probe run (1..360)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--wake", action="append", default=[], help="pebble position X,Y of a pile (repeatable)")
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--step", default=str(float(DEFAULT_STEP)), help="snap x, y to multiples of STEP metres (0: no snapping)")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--no-build", action="store_true", help="the replay executables are already built")
    args = ap.parse_args()
    if not 1 <= args.ticks <= levelc.TICK_CAP_MAX:
        sys.exit("--ticks: 1..360")
    if not args.no_build:
        replay.golden.build()
    wakes = [tuple(Fraction(v) for v in w.split(",")) for w in args.wake]
    log = (lambda *_: None) if args.quiet else print
    try:
        level, history = settle(levelc.load_level(Path(args.level)), args.ticks, wakes, args.rounds, Fraction(args.step), log)
    except (SettleError, levelc.LevelError) as e:
        sys.exit(f"settle: {e}")
    Path(args.out).write_text(levelc.dumps(level) + "\n")
    first = history[0]
    total = sum(r["drift"] for r in first)
    settle_tick = max(r["settle_tick"] for r in first)
    fixed = all(r["moved"] == 0 for r in history[-1])
    print(f"settled {args.level} -> {args.out}: settle tick {settle_tick}, total drift {total:.6f} m, "
          f"{len(history)} rounds, fixed point: {'yes' if fixed else 'NO'}")
    sys.exit(0 if fixed else 1)


if __name__ == "__main__":
    main()
