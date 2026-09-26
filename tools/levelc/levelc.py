#!/usr/bin/env python3
"""levelc: Slingfall level JSON <-> felts converter (docs/DESIGN.md D2, lot G2).

The JSON form (documented in README.md) holds decimal values; they are converted once to raw
Q32.32 `i64` (round half to even) and serialised exactly as `slingfall_level::level::Level` is by
`Serde`: one felt per scalar (negative = P - x), length-prefixed arrays, enum = variant index then
payload. Python 3 standard library only.

Usage:
    levelc.py to-felts   <level.json> [--out felts.json]
    levelc.py from-felts <felts.json> [--out level.json]
    levelc.py check      <level.json>... [--strict] [--cairo FIXTURES.cairo] [--rules [--jobs N] [--budget STEPS] [--pulls PX,PY;...]]
    levelc.py hash       <level.json>
    levelc.py to-cairo   <level.json>... [--out fixtures.cairo] [--check]
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from decimal import Decimal
from fractions import Fraction
from pathlib import Path

import poseidon

P = 2**251 + 17 * 2**192 + 1  # Starknet field prime
ONE_RAW = 1 << 32
I64_MIN, I64_MAX = -(1 << 63), (1 << 63) - 1
LEVEL_VERSION = 1
PULL_MAX = 1024
SHOTS_MAX = 5
TICK_CAP_MAX = 360
KINDS = ["static", "block", "core"]
SHAPES = ["ball", "cuboid", "polygon", "half_space"]  # variant order of `ShapeDef`
MATERIAL_FIELDS = [
    ("density", "fixed"),
    ("friction", "fixed"),
    ("restitution", "fixed"),
    ("hp", "u32"),
    ("force_threshold", "fixed"),
    ("damage_per_impulse_dt", "fixed"),
    ("score", "u32"),
]
BOUND_KEYS = ["min_x", "min_y", "max_x", "max_y"]
INT_LIMITS = {"u8": 2**8, "u16": 2**16, "u32": 2**32}


class LevelError(Exception):
    """A malformed level; the message of a validation failure is the Cairo panic message."""


# --------------------------------------------------------------------------- scalars


def to_raw(value: Decimal | int) -> int:
    """Decimal (or int) to raw Q32.32, round half to even, exact (no float involved)."""
    if isinstance(value, bool) or not isinstance(value, (Decimal, int)):
        raise LevelError(f"expected a number, got {value!r}")
    raw = round(Fraction(value) * ONE_RAW)  # Fraction.__round__ is round-half-even
    if not I64_MIN <= raw <= I64_MAX:
        raise LevelError(f"{value} does not fit Q32.32")
    return raw


def from_raw(raw: int) -> Decimal:
    """Shortest decimal that `to_raw` maps back to `raw`."""
    exact = Fraction(raw, ONE_RAW)
    for digits in range(33):
        n = round(exact * 10**digits)
        if round(Fraction(n, 10**digits) * ONE_RAW) == raw:
            return Decimal(n).scaleb(-digits)
    raise AssertionError("unreachable: 32 fractional digits are exact")


def fixed_felt(raw: int) -> int:
    return raw % P


def felt_fixed(felt: int) -> int:
    raw = felt if felt < 1 << 63 else felt - P
    if not I64_MIN <= raw <= I64_MAX:
        raise LevelError(f"felt {felt} is not a raw Q32.32 i64")
    return raw


def to_int(value, kind: str) -> int:
    if isinstance(value, Decimal) and value == value.to_integral_value():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < INT_LIMITS[kind]:
        raise LevelError(f"expected a {kind}, got {value!r}")
    return value


def to_felt(value) -> int:
    """A felt252 given as an int, a decimal string or a `0x` hex string."""
    if isinstance(value, str):
        value = int(value, 0)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value < P:
        raise LevelError(f"expected a felt252, got {value!r}")
    return value


def rotation_raw(angle_deg: Decimal | int) -> tuple[int, int]:
    """Raw `(re, im)` = `(cos, sin)` of the angle, each rounded half to even to Q32.32.

    glamx `Rot2::from_angle` cannot be matched bit for bit: rapier_math's port awaits trig support.
    Multiples of 90 degrees are exact; the others come from `math.cos`/`math.sin` on the float
    angle, whose error (~1e-16) is far below half a raw unit (1.2e-10), so the rounding is the
    correctly rounded one except in the negligible case of a tie.
    """
    deg = Fraction(angle_deg) % 360
    if deg % 90 == 0:
        return [(ONE_RAW, 0), (0, ONE_RAW), (-ONE_RAW, 0), (0, -ONE_RAW)][int(deg // 90)]
    rad = math.radians(float(deg))
    return round(Fraction(math.cos(rad)) * ONE_RAW), round(Fraction(math.sin(rad)) * ONE_RAW)


# --------------------------------------------------------------------------- JSON -> felts


def need(obj, key, where):
    if not isinstance(obj, dict) or key not in obj:
        raise LevelError(f"{where}: missing key {key!r}")
    return obj[key]


def vec_felts(obj, where) -> list[int]:
    return [fixed_felt(to_raw(need(obj, k, where))) for k in ("x", "y")]


def shape_felts(shape) -> list[int]:
    kind = need(shape, "type", "shape")
    if kind not in SHAPES:
        raise LevelError(f"shape: unknown type {kind!r}")
    out = [SHAPES.index(kind)]
    if kind == "ball":
        out.append(fixed_felt(to_raw(need(shape, "radius", "ball"))))
    elif kind == "cuboid":
        out += [fixed_felt(to_raw(need(shape, k, "cuboid"))) for k in ("hx", "hy")]
    elif kind == "polygon":
        points = need(shape, "points", "polygon")
        out.append(len(points))
        for point in points:
            out += vec_felts(point, "polygon point")
    else:
        out += vec_felts(need(shape, "normal", "half_space"), "half_space normal")
    return out


def pose_felts(pose) -> list[int]:
    x, y = vec_felts(pose, "pose")
    if "angle_deg" in pose:
        if "re" in pose or "im" in pose:
            raise LevelError("pose: give angle_deg or re/im, not both")
        re, im = rotation_raw(pose["angle_deg"])
    else:
        re, im = to_raw(need(pose, "re", "pose")), to_raw(need(pose, "im", "pose"))
    return [x, y, fixed_felt(re), fixed_felt(im)]


def level_to_felts(level: dict) -> list[int]:
    f: list[int] = []
    f.append(to_int(need(level, "version", "level"), "u16"))
    f.append(to_int(need(level, "level_id", "level"), "u32"))
    f.append(to_felt(need(level, "seed", "level")))
    f.append(fixed_felt(to_raw(need(level, "gravity_y", "level"))))
    f.append(to_int(need(level, "shots", "level"), "u8"))
    f.append(to_int(need(level, "tick_cap", "level"), "u16"))
    bounds = need(level, "bounds", "level")
    f += [fixed_felt(to_raw(need(bounds, k, "bounds"))) for k in BOUND_KEYS]
    f += vec_felts(need(level, "sling_anchor", "level"), "sling_anchor")
    f.append(to_int(need(level, "pull_radius", "level"), "u16"))
    f.append(fixed_felt(to_raw(need(level, "launch_scale", "level"))))
    projectiles = need(level, "projectiles", "level")
    f.append(len(projectiles))
    f += [to_int(p, "u8") for p in projectiles]
    materials = need(level, "materials", "level")
    f.append(len(materials))
    for m in materials:
        for key, kind in MATERIAL_FIELDS:
            v = need(m, key, "material")
            f.append(fixed_felt(to_raw(v)) if kind == "fixed" else to_int(v, kind))
    bodies = need(level, "bodies", "level")
    f.append(len(bodies))
    for b in bodies:
        kind = need(b, "kind", "body")
        if kind not in KINDS:
            raise LevelError(f"body: unknown kind {kind!r}")
        f.append(KINDS.index(kind))
        f += shape_felts(need(b, "shape", "body"))
        f += pose_felts(need(b, "pose", "body"))
        f.append(to_int(need(b, "material", "body"), "u8"))
    return f


# --------------------------------------------------------------------------- felts -> JSON


class Reader:
    def __init__(self, felts: list[int]):
        self.felts, self.pos = felts, 0

    def next(self) -> int:
        if self.pos >= len(self.felts):
            raise LevelError("felts: unexpected end")
        self.pos += 1
        return self.felts[self.pos - 1]

    def fixed(self) -> Decimal:
        return from_raw(felt_fixed(self.next()))

    def raw(self) -> int:
        return felt_fixed(self.next())

    def uint(self, kind: str) -> int:
        v = self.next()
        if v >= INT_LIMITS[kind]:
            raise LevelError(f"felt {v} does not fit a {kind}")
        return v

    def vec(self) -> dict:
        return {"x": self.fixed(), "y": self.fixed()}


def felts_to_level(felts: list[int]) -> dict:
    r = Reader(felts)
    level: dict = {}
    level["version"] = r.uint("u16")
    level["level_id"] = r.uint("u32")
    level["seed"] = r.next()
    level["gravity_y"] = r.fixed()
    level["shots"] = r.uint("u8")
    level["tick_cap"] = r.uint("u16")
    level["bounds"] = {k: r.fixed() for k in BOUND_KEYS}
    level["sling_anchor"] = r.vec()
    level["pull_radius"] = r.uint("u16")
    level["launch_scale"] = r.fixed()
    level["projectiles"] = [r.uint("u8") for _ in range(r.next())]
    materials = []
    for _ in range(r.next()):
        materials.append({k: r.fixed() if kind == "fixed" else r.uint(kind) for k, kind in MATERIAL_FIELDS})
    level["materials"] = materials
    bodies = []
    for _ in range(r.next()):
        kind = r.next()
        if kind >= len(KINDS):
            raise LevelError(f"felt {kind} is not a body kind")
        variant = r.next()
        if variant >= len(SHAPES):
            raise LevelError(f"felt {variant} is not a shape variant")
        shape: dict = {"type": SHAPES[variant]}
        if variant == 0:
            shape["radius"] = r.fixed()
        elif variant == 1:
            shape["hx"], shape["hy"] = r.fixed(), r.fixed()
        elif variant == 2:
            shape["points"] = [r.vec() for _ in range(r.next())]
        else:
            shape["normal"] = r.vec()
        pose = {"x": r.fixed(), "y": r.fixed(), "re": r.fixed(), "im": r.fixed()}
        bodies.append({"kind": KINDS[kind], "shape": shape, "pose": pose, "material": r.uint("u8")})
    level["bodies"] = bodies
    if r.pos != len(felts):
        raise LevelError(f"felts: {len(felts) - r.pos} trailing felts")
    return level


# --------------------------------------------------------------------------- validation


def validate_felts(felts: list[int]) -> None:
    """Mirror of `LevelTrait::validate`; raises `LevelError` with the Cairo panic message."""
    level = felts_to_level(felts)
    raw = lambda d: to_raw(d)  # noqa: E731
    if level["version"] != LEVEL_VERSION:
        raise LevelError("level: version")
    if not 1 <= level["shots"] <= SHOTS_MAX or len(level["projectiles"]) != level["shots"]:
        raise LevelError("level: shots")
    if not 1 <= level["tick_cap"] <= TICK_CAP_MAX:
        raise LevelError("level: tick cap")
    if not 1 <= level["pull_radius"] <= PULL_MAX:
        raise LevelError("level: pull radius")
    b = {k: raw(v) for k, v in level["bounds"].items()}
    if b["min_x"] >= b["max_x"] or b["min_y"] >= b["max_y"]:
        raise LevelError("level: bounds")

    def inside(p) -> bool:
        return b["min_x"] <= raw(p["x"]) <= b["max_x"] and b["min_y"] <= raw(p["y"]) <= b["max_y"]

    if not inside(level["sling_anchor"]):
        raise LevelError("level: bounds")
    for body in level["bodies"]:
        if body["material"] >= len(level["materials"]):
            raise LevelError("level: material")
        if body["shape"]["type"] == "polygon" and len(body["shape"]["points"]) < 3:
            raise LevelError("level: shape")
        if body["kind"] != "static" and not inside(body["pose"]):
            raise LevelError("level: bounds")


# --------------------------------------------------------------------------- output


def inline(value) -> str:
    if isinstance(value, dict):
        return "{" + ", ".join(f'"{k}": {inline(v)}' for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(inline(v) for v in value) + "]"
    if isinstance(value, Decimal):
        return format(value, "f")
    return json.dumps(value)


def dumps(value, indent: int = 0) -> str:
    """JSON with decimals as numbers (never floats); short containers on one line."""
    flat = inline(value)
    if not isinstance(value, (dict, list)) or not value or indent * 2 + len(flat) <= 140:
        return flat
    pad, inner = "  " * indent, "  " * (indent + 1)
    if isinstance(value, dict):
        items = [f'{inner}"{k}": {dumps(v, indent + 1)}' for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    return "[\n" + ",\n".join(inner + dumps(v, indent + 1) for v in value) + "\n" + pad + "]"


def parse_json(text: str):
    return json.loads(text, parse_float=Decimal)


def canonical(level: dict) -> dict:
    """The level as `from-felts` prints it (poses as raw `re`/`im`, shortest decimals)."""
    return felts_to_level(level_to_felts(level))


def felts_document(felts: list[int]) -> dict:
    return {"level_hash": hex(poseidon.hash_span(felts)), "felts": [str(x) for x in felts]}


def load_level(path: Path) -> dict:
    try:
        return parse_json(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise LevelError(f"{path}: {e}") from e


def load_felts(path: Path) -> list[int]:
    doc = parse_json(path.read_text())
    items = doc["felts"] if isinstance(doc, dict) else doc
    return [to_felt(x) for x in items]


def felts_path(level_path: Path) -> Path:
    return level_path.with_name(level_path.name.removesuffix(".json") + ".felts.json")


# --------------------------------------------------------------------------- Cairo fixtures


def cairo_fixtures(paths: list[Path]) -> str:
    """`crates/slingfall_level/src/level/fixtures.cairo` (a public module: the game, replay and contract
    tests import it): the fixture felts and golden hashes."""
    out = [
        "//! Fixture levels as `Serde` felts, generated by `tools/levelc/levelc.py to-cairo`",
        "//! from `fixtures/levels/*.json`. Do not edit by hand.",
        "",
        "use crate::level::Level;",
        "",
        "/// Deserialises the felts of a fixture level.",
        "fn load(felts: Array<felt252>) -> Level {",
        "    let mut span = felts.span();",
        "    let level: Level = Serde::deserialize(ref span).expect('fixture: level');",
        "    assert!(span.is_empty(), \"fixture: trailing felts\");",
        "    level",
        "}",
    ]
    for path in sorted(paths):
        name = path.name.removesuffix(".json")
        felts = level_to_felts(load_level(path))
        out += ["", f"/// `fixtures/levels/{name}.json`: {len(felts)} felts.", f"pub fn {name}_felts() -> Array<felt252> {{"]
        out.append("    array![")
        for i in range(0, len(felts), 6):
            out.append("        " + ", ".join(str(x) for x in felts[i : i + 6]) + ",")
        out += ["    ]", "}", "", f"pub fn {name}() -> Level {{", f"    load({name}_felts())", "}", ""]
        out += [f"/// Golden `level_hash` of `{name}`.", f"pub const {name.upper()}_HASH: felt252 = {hex(poseidon.hash_span(felts))};"]
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------- commands


def cmd_to_felts(args) -> None:
    felts = level_to_felts(load_level(Path(args.level)))
    text = dumps(felts_document(felts), 0) + "\n"
    Path(args.out).write_text(text) if args.out else sys.stdout.write(text)


def cmd_from_felts(args) -> None:
    text = dumps(felts_to_level(load_felts(Path(args.felts)))) + "\n"
    Path(args.out).write_text(text) if args.out else sys.stdout.write(text)


def cmd_hash(args) -> None:
    print(hex(poseidon.hash_span(level_to_felts(load_level(Path(args.level))))))


def cmd_to_cairo(args) -> None:
    text = cairo_fixtures(level_paths(args.levels))
    if args.check:
        if not args.out:
            sys.exit("error: --check needs --out (the file to compare with)")
        if not same_code(Path(args.out).read_text(), text):
            sys.exit(f"FAIL {args.out} is stale: run levelc.py to-cairo")
        print(f"ok   {args.out}")
        return
    Path(args.out).write_text(text) if args.out else sys.stdout.write(text)


def check_one(path: Path, strict: bool) -> None:
    level = load_level(path)
    felts = level_to_felts(level)
    validate_felts(felts)
    # felts -> JSON -> felts is the identity, and the canonical JSON is a fixed point.
    back = felts_to_level(felts)
    if level_to_felts(back) != felts:
        raise LevelError("round trip felts -> JSON -> felts is not the identity")
    if dumps(canonical(back)) != dumps(back):
        raise LevelError("canonical JSON is not a fixed point")
    if strict and dumps(level) != dumps(back):
        raise LevelError("JSON is not canonical (run: levelc.py to-felts, then from-felts)")
    stored = felts_path(path)
    if stored.exists():
        doc = parse_json(stored.read_text())
        if [to_felt(x) for x in doc["felts"]] != felts:
            raise LevelError(f"{stored} is stale: felts differ from {path}")
        if int(doc["level_hash"], 0) != poseidon.hash_span(felts):
            raise LevelError(f"{stored}: level_hash does not match the felts")


def level_paths(names: list[str]) -> list[Path]:
    """The level files among `names`: a shell glob `*.json` also matches the `.felts.json` files."""
    return sorted(Path(n) for n in names if not n.endswith(".felts.json"))


def same_code(a: str, b: str) -> bool:
    """Equal up to whitespace: `scarb fmt` rewraps the generated Cairo."""
    return "".join(a.split()) == "".join(b.split())


def check_rules(levels: list[Path], args) -> int:
    """`--rules`: the rule-level validator (`rules.py`); returns the number of failing levels."""
    import rules  # runs the replay executables: imported on demand

    if not args.no_build:
        rules.replay.golden.build()
    failing = 0
    for path in levels:
        print(f"rules {path}")
        pulls = [tuple(int(v) for v in p.split(",")) for p in args.pulls.split(";")] if args.pulls else None
        report = rules.check_level(path, args.jobs, pulls=pulls, budget=args.budget)
        for w in report.warnings:
            print(f"warn {path}: {w}", file=sys.stderr)
        for f in report.failures:
            print(f"FAIL {path}: {f}", file=sys.stderr)
        failing += not report.ok()
        print(f"{'ok  ' if report.ok() else 'FAIL'} {path} (rules)")
    return failing


def cmd_check(args) -> None:
    failures = 0
    levels = level_paths(args.levels)
    for path in levels:
        name = str(path)
        try:
            check_one(Path(name), args.strict)
            print(f"ok   {name}")
        except LevelError as e:
            failures += 1
            print(f"FAIL {name}: {e}", file=sys.stderr)
    if args.rules:
        failures += check_rules(levels, args)
    if args.cairo:
        if not same_code(Path(args.cairo).read_text(), cairo_fixtures(levels)):
            failures += 1
            print(f"FAIL {args.cairo} is stale: run levelc.py to-cairo", file=sys.stderr)
        else:
            print(f"ok   {args.cairo}")
    sys.exit(1 if failures else 0)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("to-felts")
    p.add_argument("level")
    p.add_argument("--out")
    p.set_defaults(fn=cmd_to_felts)
    p = sub.add_parser("from-felts")
    p.add_argument("felts")
    p.add_argument("--out")
    p.set_defaults(fn=cmd_from_felts)
    p = sub.add_parser("check")
    p.add_argument("levels", nargs="+")
    p.add_argument("--strict", action="store_true")
    p.add_argument("--cairo")
    p.add_argument("--rules", action="store_true", help="also run the rule-level validator (rules.py; needs scarb)")
    p.add_argument("--jobs", type=int, default=2, help="--rules: parallel `scarb execute` (about 6 GB each)")
    p.add_argument("--budget", type=int, default=100_000_000, help="--rules: most Cairo steps of the best pull")
    p.add_argument("--pulls", help="--rules: PX,PY;PX,PY... instead of the 12-pull grid")
    p.add_argument("--no-build", action="store_true", help="--rules: the replay executables are already built")
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("hash")
    p.add_argument("level")
    p.set_defaults(fn=cmd_hash)
    p = sub.add_parser("to-cairo")
    p.add_argument("levels", nargs="+")
    p.add_argument("--out")
    p.add_argument("--check", action="store_true", help="fail when --out is not up to date")
    p.set_defaults(fn=cmd_to_cairo)
    args = ap.parse_args()
    try:
        args.fn(args)
    except LevelError as e:
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    main()
