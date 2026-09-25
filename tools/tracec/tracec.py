#!/usr/bin/env python3
"""tracec: arguments of the replay executables, and their trace lines to trace format v1 JSON
(lot G4). Python 3 standard library only.

Usage:
    tracec.py args  <level.felts.json> [--player FELT] [--shot PX,PY[,DELAY]]... [--out args.json]
    tracec.py trace <lines.txt|-> [--out trace.json]

`args` writes the `--arguments-file` of `scarb execute` for `main` / `main_trace`: a JSON array of
hex felts (`0x`, as `scarb execute` wants), `[len(level), level..., len(inputs), inputs...]` (negative = P - x); `inputs` is
`Inputs { player, shots }` with `ability_tick = 0`. The level document is `levelc.py to-felts`'s.

`trace` reads the lines printed by `main_trace` (the `scarb execute` output; other lines are
ignored) and writes trace format v1 (`client/README.md`). The lines are documented in
`crates/slingfall_replay/src/trace.cairo`. Material names come from the D7 score of the material
(50 timber, 100 frost, 150 slate, 1000 core; static bodies are `ground`); an unknown score gives
`m<index>`. A tick-0 frame (every dynamic body asleep at its level pose) is prepended, as the
level starts pre-slept.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

P = 2**251 + 17 * 2**192 + 1  # Starknet field prime
TRACE_VERSION = 1
LINES_VERSION = 1
KINDS = ["static", "block", "core"]
MATERIAL_NAMES = {50: "timber", 100: "frost", 150: "slate", 1000: "core"}
DEFAULT_PLAYER = int.from_bytes(b"player", "big")


class TraceError(Exception):
    """Malformed trace lines."""


def felt(value: int) -> int:
    """An integer as a felt (negative = P - x)."""
    return value % P


def inputs_felts(player: int, shots: list[tuple[int, int, int]]) -> list[int]:
    """`Serde` felts of `Inputs { player, shots }`, `ability_tick = 0`."""
    felts = [felt(player), len(shots)]
    for px, py, delay in shots:
        felts += [felt(px), felt(py), delay, 0]
    return felts


def parse_shot(text: str) -> tuple[int, int, int]:
    parts = [int(p) for p in text.split(",")]
    if len(parts) not in (2, 3):
        raise argparse.ArgumentTypeError(f"shot {text!r}: PX,PY[,DELAY]")
    return (parts[0], parts[1], parts[2] if len(parts) == 3 else 0)


def load_level_felts(path: Path) -> list[int]:
    doc = json.loads(path.read_text())
    felts = doc["felts"] if isinstance(doc, dict) else doc
    return [int(f, 0) if isinstance(f, str) else int(f) for f in felts]


def main_arguments(level: list[int], inputs: list[int]) -> list[str]:
    """`scarb execute --arguments-file` wants `0x` felts."""
    return [hex(f) for f in [len(level), *level, len(inputs), *inputs]]


# --------------------------------------------------------------------------- lines -> JSON


def pose(tokens: list[str]) -> dict:
    x, y, re, im = tokens
    return {"x": x, "y": y, "re": re, "im": im}


def parse_shape(tokens: list[str]) -> dict:
    kind = tokens[0]
    if kind == "ball":
        return {"type": "ball", "radius": tokens[1]}
    if kind == "cuboid":
        return {"type": "cuboid", "hx": tokens[1], "hy": tokens[2]}
    if kind == "polygon":
        n = int(tokens[1])
        values = tokens[2 : 2 + 2 * n]
        return {"type": "polygon", "vertices": [{"x": values[2 * i], "y": values[2 * i + 1]} for i in range(n)]}
    if kind == "halfspace":
        return {"type": "halfspace", "normal": {"x": tokens[1], "y": tokens[2]}}
    raise TraceError(f"unknown shape {kind!r}")


def lines_to_trace(lines: list[str]) -> dict:
    level = None
    materials: dict[int, int] = {}
    bodies: list[dict] = []
    frames: list[dict] = []
    events: list[dict] = []
    version = None
    for raw in lines:
        tokens = raw.split()
        if not tokens:
            continue
        tag, rest = tokens[0], tokens[1:]
        if tag == "trace":
            version = int(rest[0])
            if version != LINES_VERSION:
                raise TraceError(f"trace lines version {version}, expected {LINES_VERSION}")
        elif tag == "level":
            g, scale, radius, shots, min_x, min_y, max_x, max_y, ax, ay, _n = rest
            level = {
                "bounds": {"min_x": min_x, "min_y": min_y, "max_x": max_x, "max_y": max_y},
                "sling_anchor": {"x": ax, "y": ay},
                "gravity_y": g,
                "launch_scale": scale,
                "pull_radius": int(radius),
                "shots": int(shots),
            }
        elif tag == "material":
            materials[int(rest[0])] = int(rest[1])
        elif tag == "body":
            handle, kind, material = int(rest[0]), int(rest[1]), int(rest[2])
            name = "ground" if kind == 0 else MATERIAL_NAMES.get(materials.get(material), f"m{material}")
            bodies.append(
                {
                    "handle": handle,
                    "kind": KINDS[kind],
                    "shape": parse_shape(rest[7:]),
                    "material": name,
                    "pose": pose(rest[3:7]),
                }
            )
        elif tag == "frame":
            tick, values = int(rest[0]), rest[1:]
            if len(values) % 6:
                raise TraceError(f"frame {tick}: {len(values)} values")
            frame = []
            for i in range(0, len(values), 6):
                h, x, y, re, im, asleep = values[i : i + 6]
                frame.append({"handle": int(h), "x": x, "y": y, "re": re, "im": im, "asleep": asleep == "1"})
            if frames and tick <= frames[-1]["tick"]:
                raise TraceError(f"frame {tick} after frame {frames[-1]['tick']}")
            frames.append({"tick": tick, "bodies": frame})
        elif tag == "damage":
            events.append({"tick": int(rest[0]), "kind": "damage", "handle": int(rest[1]), "hp": int(rest[2])})
        elif tag == "destroyed":
            events.append({"tick": int(rest[0]), "kind": "destroyed", "handle": int(rest[1])})
        elif tag == "score":
            events.append({"tick": int(rest[0]), "kind": "score", "points": int(rest[1]), "total": int(rest[2])})
        elif tag == "shot_end":
            events.append({"tick": int(rest[0]), "kind": "shot_end", "shot": int(rest[1])})
    if version is None or level is None:
        raise TraceError("no `trace` / `level` header line")
    level["bodies"] = bodies
    start = {
        "tick": 0,
        "bodies": [
            {"handle": b["handle"], **b["pose"], "asleep": True} for b in bodies if b["kind"] != "static"
        ],
    }
    return {"version": TRACE_VERSION, "level": level, "frames": [start, *frames], "events": events}


def dumps(trace: dict) -> str:
    """One line per frame and per event: diffable and still small."""
    out = ["{", f'  "version": {trace["version"]},', f'  "level": {json.dumps(trace["level"], separators=(",", ":"))},']
    out.append('  "frames": [')
    out.append(",\n".join("    " + json.dumps(f, separators=(",", ":")) for f in trace["frames"]))
    out.append("  ],")
    out.append('  "events": [')
    out.append(",\n".join("    " + json.dumps(e, separators=(",", ":")) for e in trace["events"]))
    out.append("  ]")
    out.append("}")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------- CLI


def cmd_args(args) -> None:
    level = load_level_felts(Path(args.level))
    felts = main_arguments(level, inputs_felts(int(args.player, 0), args.shot))
    text = json.dumps(felts) + "\n"
    if args.out:
        Path(args.out).write_text(text)
    else:
        sys.stdout.write(text)


def cmd_trace(args) -> None:
    text = sys.stdin.read() if args.lines == "-" else Path(args.lines).read_text()
    out = dumps(lines_to_trace(text.splitlines()))
    if args.out:
        Path(args.out).write_text(out)
    else:
        sys.stdout.write(out)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("args", help="arguments file of main / main_trace")
    p.add_argument("level")
    p.add_argument("--player", default=str(DEFAULT_PLAYER))
    p.add_argument("--shot", type=parse_shot, action="append", default=[])
    p.add_argument("--out")
    p.set_defaults(func=cmd_args)
    p = sub.add_parser("trace", help="trace lines to trace format v1 JSON")
    p.add_argument("lines")
    p.add_argument("--out")
    p.set_defaults(func=cmd_trace)
    args = parser.parse_args()
    try:
        args.func(args)
    except TraceError as error:
        sys.exit(f"tracec: {error}")


if __name__ == "__main__":
    main()
