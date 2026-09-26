#!/usr/bin/env python3
"""matrix: the reference shots of the six levels under one simulation setting (lot S1).
Python 3 standard library only; needs `scarb` (the executables are built in a scratch copy of the
workspace for every setting but the default, see `golden.variant_root`).

    matrix.py --substeps {1,2,4} --hz {30,60} [--level NAME]... [-j N] [--no-build] [--out FILE]
    matrix.py table BASELINE.json OTHER.json...     (markdown rows of the `--out` files)

Per level, the reference shots of `fixtures/golden/cases.json` (the `*-reference` case; `one_block`:
its `delay30` case) run through `main_trace` and `main`: the destroyed set (handles), score, won,
end tick, Cairo steps of `main`, and the flight of the pebble against the client's exact arc
(`client/src/aim/arc.ts`: semi-implicit Euler, every product floored, 60 Hz): the number of ticks
the engine's pebble is bit-identical to the arc, and the largest deviation (millimetres) over the
free flight. The result is printed as JSON (and
written to `--out`).
"""

from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "settle"))
import golden  # noqa: E402
import levelc  # noqa: E402
import replay  # noqa: E402

ARC_HORIZON = 120  # arc ticks compared at most: `MAX_ARC_TICKS` of `arc.ts`


def reference_cases() -> dict[str, dict]:
    """One reference case per level: `<level>-reference`, or the delay case of `one_block`."""
    cases = json.loads(golden.CASES.read_text())["cases"]
    picked: dict[str, dict] = {}
    for case in cases:
        if case["name"].endswith("-reference") or case["name"] == "one_block-delay30":
            picked[case["level"]] = case
    return picked


def mul_floor(a: int, b: int) -> int:
    return (a * b) >> 32


def arc_points(level: dict, pull: tuple[int, int], dt: int, n: int, substeps: int = 1) -> list[tuple[int, int]]:
    """`flightArc` of `client/src/aim/arc.ts` with the tick length `dt` (raw), one Euler step per
    tick (`substeps = 1`); with `substeps = k` the engine's free flight: k Euler steps of `dt // k`
    per tick, gravity included in each (bit-exact against the trace at every setting)."""
    h = dt // substeps
    scale, g = levelc.to_raw(level["launch_scale"]), levelc.to_raw(level["gravity_y"])
    vx, vy = -pull[0] * scale, -pull[1] * scale
    x, y = levelc.to_raw(level["sling_anchor"]["x"]), levelc.to_raw(level["sling_anchor"]["y"])
    dvy = mul_floor(g, h)
    points = []
    for _ in range(n):
        for _ in range(substeps):
            vy += dvy
            x += mul_floor(vx, h)
            y += mul_floor(vy, h)
        points.append((x, y))
    return points


def arc_check(level: dict, shot: list[int], run: replay.Run, substeps: int, hz: int) -> dict:
    """Engine pebble poses against the 60 Hz arc over the free flight. The flight ends at the first
    tick the engine leaves its own substepped Euler arc by more than 5 mm (a contact), or at
    the arc's 120 ticks. Reported over the flight ticks: how many engine ticks are bit-identical
    to the 60 Hz arc, the largest deviation from it in millimetres (at 30 Hz an engine tick is two
    arc ticks), and the flight length in seconds."""
    pebble = len(level["bodies"])  # the handle of the pebble of the first shot: `bodies + shot`
    engine_dt = golden.DT_30 if hz == 30 else golden.DT_60
    step = 2 if hz == 30 else 1  # arc ticks per engine tick
    engine = []
    for tick, frame in run.frames:
        if tick > shot[2] and pebble in frame:
            engine.append(frame[pebble][:2])
    n = min(ARC_HORIZON // step, len(engine))
    own = arc_points(level, (shot[0], shot[1]), engine_dt, n, substeps)
    arc = arc_points(level, (shot[0], shot[1]), golden.DT_60, n * step)
    exact, worst, flight = 0, 0, 0
    for k in range(n):
        ex, ey = engine[k]
        if max(abs(ex - own[k][0]), abs(ey - own[k][1])) > 5 * 2**32 // 1000:
            break
        flight += 1
        ax, ay = arc[(k + 1) * step - 1]
        worst = max(worst, abs(ex - ax), abs(ey - ay))
        if (ex, ey) == (ax, ay) and exact == k:
            exact += 1
    return {"flight_ticks": flight, "bit_identical_ticks": exact, "max_deviation_mm": round(worst * 1000 / 2**32, 3)}


def reference(name: str, case: dict, substeps: int, hz: int) -> dict:
    level = levelc.canonical(levelc.load_level(ROOT / "fixtures" / "levels" / f"{name}.json"))
    felts = levelc.level_to_felts(level)
    shots = [tuple(s) for s in case["shots"]]
    trace = replay.run("main_trace", felts, shots)
    proof = replay.run("main", felts, shots)
    if proof.outputs != trace.outputs:
        raise golden.GoldenError(f"{name}: main and main_trace disagree")
    return {
        "level": name,
        "shots": [list(s) for s in shots],
        "destroyed": sorted(h for _, h in trace.destroyed),
        "destroyed_ticks": [[t, h] for t, h in trace.destroyed],
        "score": trace.score,
        "won": trace.won,
        "ticks": trace.ticks,
        "steps": proof.steps,
        "arc": arc_check(level, list(shots[0]), trace, substeps, hz),
    }


def table(paths: list[str]) -> None:
    """Markdown rows of the `--out` files, the first one being the baseline."""
    docs = [json.loads(Path(p).read_text()) for p in paths]
    base = {r["level"]: r for r in docs[0]["levels"]}
    print("| setting | level | shots | won | score | ticks | steps | vs baseline | destroyed | same or superset | "
          "arc: flight ticks / bit-identical / max deviation |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for doc in docs:
        total = 0
        for r in doc["levels"]:
            b = base[r["level"]]
            total += r["steps"]
            arc = r["arc"]
            print(f"| x{doc['substeps']} {doc['hz']} Hz | {r['level']} | {len(r['shots'])} | {int(r['won'])} | {r['score']} | "
                  f"{r['ticks']} | {r['steps']:,} | {(r['steps'] / b['steps'] - 1) * 100:+.0f} % | {r['destroyed']} | "
                  f"{'yes' if set(b['destroyed']) <= set(r['destroyed']) else 'NO'} | {arc['flight_ticks']} / "
                  f"{arc['bit_identical_ticks']} / {arc['max_deviation_mm']} mm |")
        ref = sum(b["steps"] for b in base.values())
        print(f"| x{doc['substeps']} {doc['hz']} Hz | **total** | | | | | **{total:,}** | **{(total / ref - 1) * 100:+.1f} %** | | | |")


def main() -> None:
    if sys.argv[1:2] == ["table"]:
        return table(sys.argv[2:])
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--substeps", type=int, default=4)
    ap.add_argument("--hz", type=int, default=60)
    ap.add_argument("--level", action="append")
    ap.add_argument("-j", "--jobs", type=int, default=2)
    ap.add_argument("--no-build", action="store_true", help="the executables of this setting are already built")
    ap.add_argument("--out")
    args = ap.parse_args()
    golden.use_setting(args.substeps, args.hz)
    if not args.no_build:
        golden.build()
    cases = {k: v for k, v in reference_cases().items() if not args.level or k in args.level}
    with ThreadPoolExecutor(args.jobs) as pool:
        futures = [pool.submit(reference, name, case, args.substeps, args.hz) for name, case in cases.items()]
        rows = [f.result() for f in futures]
    doc = {"substeps": args.substeps, "hz": args.hz, "levels": rows}
    text = json.dumps(doc, indent=1)
    if args.out:
        Path(args.out).write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
