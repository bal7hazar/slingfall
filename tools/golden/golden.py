#!/usr/bin/env python3
"""golden: determinism and step-ceiling checks of the replay executables (lot G5).
Python 3 standard library only. From anywhere:

    golden.py [run] [--check | --update] [--case NAME]... [-j N] [--no-build]
    golden.py fuzz --seed S --n N [--level NAME]... [-j N] [--no-build]
    golden.py to-cairo [--check]

`run` reads `fixtures/golden/cases.json` (a level fixture, its shots, and the chunk schedules to
chain) and, per case, executes with `scarb execute` (`crates/slingfall_replay`):

* `main` (the proof build): the 10 output felts and the Cairo steps;
* `main_trace` (the trace build): the same 10 felts, and its printed trace lines;
* the chunked build: `init`, then `step_chunk` chained (`trace = 1`) with each chunk schedule of the
  case (a list of tick budgets K, the last one repeated until the level is over). A chained run
  has no `Outputs` of its own, so they are rebuilt from what it returns and prints: identity
  fields from the level and the inputs (Poseidon as the contract does), score / shots / ticks from
  the state header, `won` from the printed `body` / `destroyed` lines, `final_state_hash` from the
  last printed frame. The three builds must agree on the 10 felts, the chained trace lines must be
  `main_trace`'s, and every schedule must end on the same final `ChunkState` bit for bit.

The felts are then compared with the committed golden `fixtures/golden/<case>.json` (outputs and
the Cairo steps of `main`). `--update` rewrites the goldens (a deliberate change: review the
diff). `--check` (the default) fails on any difference, and when the steps of `main` exceed the
golden's by more than `step_margin` (`cases.json`, 10 %); fewer steps only prompts `--update`.

`fuzz` draws random shots (pulls inside and outside the disk, delays, shot counts) per fixture
level from `--seed`, and checks `main` against a chain of random chunk sizes; nothing is stored.

`to-cairo` writes `crates/slingfall_replay/tests/golden.cairo` (levels, inputs and golden outputs of
every case, one snforge test per case); with `--check` it fails when the file is stale.

`SLINGFALL_SUBSTEPS` (1, 2, 4) and `SLINGFALL_HZ` (30, 60) select another simulation setting of
`slingfall_rules::world` (lot S1): every tool built on this module then builds and runs a scratch copy
of the workspace with the two constants rewritten (`variant_root`); the committed goldens are the
default, x4 at 60 Hz.

`scarb execute` costs about 10 s of fixed overhead per call (VM setup, whatever the program
does), so the runs are spread over `-j` processes and the chained schedules keep a few small
chunks (to cut through delays, launches and shot ends) before a large tail.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LEVELS = ROOT / "fixtures" / "levels"
GOLDEN = ROOT / "fixtures" / "golden"
CASES = GOLDEN / "cases.json"
CAIRO_TESTS = ROOT / "crates" / "slingfall_replay" / "tests" / "golden.cairo"
sys.path.insert(0, str(ROOT / "tools" / "tracec"))
sys.path.insert(0, str(ROOT / "tools" / "levelc"))
import poseidon  # noqa: E402
import tracec  # noqa: E402

P = tracec.P
STEPS_RE = re.compile(r"^\s*steps:\s*([\d,]+)", re.M)
TRACE_LINE = re.compile(r"^(trace|level|material|body|frame|damage|destroyed|score|shot_end)\b")
OUTPUT_NAMES = [
    "version", "level_hash", "seed", "player", "inputs_hash", "score", "won", "shots_used",
    "ticks_run", "final_state_hash",
]
PULL_MAX = 1024  # `slingfall_level::inputs::PULL_MAX`
DELAY_MAX = 60  # D3
KIND_STATIC, KIND_CORE = 0, 2
TAIL_K = 60  # tick budget of the chunks after a schedule's small ones, unless it says otherwise
# Felts of each chunked executable's binding header (`crates/slingfall_replay/README.md`).
BINDING_HEADER = {"init": 1, "step_chunk": 4, "outputs": 2}


# --------------------------------------------------------------------------- simulation settings

DT_60, DT_30 = 71582788, 143165576  # floor(2^32 / 60), floor(2^32 / 30), raw Q32.32
SUBSTEPS_ENV, HZ_ENV = "SLINGFALL_SUBSTEPS", "SLINGFALL_HZ"
SETTINGS = (int(os.environ.get(SUBSTEPS_ENV, 4)), int(os.environ.get(HZ_ENV, 60)))  # (substeps, Hz)


def variant_root(substeps: int, hz: int) -> Path:
    """Scratch copy of the workspace built with another setting of `slingfall_rules::world`
    (`SOLVER_ITERATIONS`, `TICK_DT_RAW`), used instead of Scarb features: the manifests declare
    none. The default setting is the repository itself."""
    if (substeps, hz) == (4, 60):
        return ROOT
    if substeps not in (1, 2, 4) or hz not in (30, 60):
        sys.exit(f"unsupported setting: substeps {substeps} (1, 2, 4), hz {hz} (30, 60)")
    return Path(tempfile.gettempdir()) / f"slingfall-sim-x{substeps}-{hz}hz"


def sync_variant(substeps: int, hz: int) -> Path:
    """Refreshes the scratch copy from the repository (the `target` dirs stay: incremental)."""
    root = variant_root(substeps, hz)
    if root == ROOT:
        return root
    root.mkdir(exist_ok=True)
    shutil.copy2(ROOT / "Scarb.toml", root / "Scarb.toml")
    shutil.copytree(ROOT / "crates", root / "crates", dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("target", ".snfoundry_cache"))
    world = root / "crates" / "slingfall_rules" / "src" / "world.cairo"
    text = world.read_text()
    text, n = re.subn(r"(pub const SOLVER_ITERATIONS: u32 = )\d+;", rf"\g<1>{substeps};", text)
    text, m = re.subn(r"(pub const TICK_DT_RAW: i64 = )\d+;", rf"\g<1>{DT_30 if hz == 30 else DT_60};", text)
    if n != 1 or m != 1:
        sys.exit("world.cairo: SOLVER_ITERATIONS / TICK_DT_RAW constants not found")
    world.write_text(text)
    return root


MANIFEST = variant_root(*SETTINGS) / "crates" / "slingfall_replay" / "Scarb.toml"


def use_setting(substeps: int, hz: int) -> None:
    """Switches this process (and the tools built on it) to another setting; `build()` follows."""
    global MANIFEST, SETTINGS
    SETTINGS = (substeps, hz)
    MANIFEST = variant_root(substeps, hz) / "crates" / "slingfall_replay" / "Scarb.toml"


class GoldenError(Exception):
    """A determinism or golden failure (the message says which case and build)."""


# --------------------------------------------------------------------------- running scarb

def build() -> None:
    sync_variant(*SETTINGS)
    out = subprocess.run(["scarb", "--manifest-path", str(MANIFEST), "build"], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"scarb build failed\n{out.stdout}\n{out.stderr}")


def execute(name: str, felts: list[int]) -> tuple[int, list[int], list[str]]:
    """Runs one executable (built): (Cairo steps, returned felts, printed trace lines)."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump([hex(x % P) for x in felts], f)
    try:
        out = subprocess.run(
            ["scarb", "--manifest-path", str(MANIFEST), "execute", "--no-build", "--output", "none",
             "--executable-name", name, "--arguments-file", f.name, "--print-program-output",
             "--print-resource-usage"],
            capture_output=True, text=True, check=False,
        )
    finally:
        Path(f.name).unlink()
    text = out.stdout
    if out.returncode != 0 or "Program output:" not in text:
        raise GoldenError(f"{name}: scarb execute failed\n{text[-2000:]}\n{out.stderr[-2000:]}")
    head, rest = text.split("Program output:", 1)
    values = [int(v) % P for v in rest.split("Resources:", 1)[0].split()]
    # Without the binding header of the chunked executables (lot P1b): the state, or the outputs.
    returned = values[1 + BINDING_HEADER.get(name, 0) : 1 + values[0]]
    steps = int(STEPS_RE.search(rest).group(1).replace(",", ""))
    return steps, returned, [l for l in head.splitlines() if TRACE_LINE.match(l)]


# --------------------------------------------------------------------------- the three builds

class Level:
    """A fixture level: its felts, and the chained `init` run (shared by every schedule)."""

    def __init__(self, name: str):
        self.name = name
        self.felts = tracec.load_level_felts(LEVELS / f"{name}.felts.json")
        self.args = [len(self.felts), *self.felts]
        self.shots = self.felts[4]  # version, level_id, seed, gravity_y, shots
        self._init: tuple[list[int], list[str]] | None = None
        self._lock = threading.Lock()

    def init(self) -> tuple[list[int], list[str]]:
        with self._lock:
            if self._init is None:
                _, state, lines = execute("init", self.args)
                self._init = (state, lines)
            return self._init


def run_build(level: Level, inputs: list[int], name: str) -> tuple[int, list[int], list[str]]:
    return execute(name, [*level.args, len(inputs), *inputs])


def run_chain(level: Level, inputs: list[int], schedule: list[int]) -> tuple[list[int], list[str]]:
    """`init` then `step_chunk(state, inputs, shot, K, 1)` until the level is over or the inputs
    end; K comes from `schedule`, its last value repeating. Returns the final state and the lines."""
    state, lines = level.init()
    lines = list(lines)
    n_shots = inputs[1]
    step = 0
    for shot in range(n_shots):
        while state[1] == shot and state[2] == 0:
            k = schedule[min(step, len(schedule) - 1)]
            step += 1
            _, state, printed = execute("step_chunk", [len(state), *state, len(inputs), *inputs, shot, k, 1])
            lines += printed
    return state, lines


def chain_outputs(level: Level, inputs: list[int], state: list[int], lines: list[str]) -> list[int]:
    """The 10 felts of D4 for a chained run, from its final `ChunkState` and its trace lines."""
    bodies = [l.split() for l in lines if l.startswith("body ")]
    cores = {int(b[1]) for b in bodies if int(b[2]) == KIND_CORE}
    destroyed = {int(l.split()[2]) for l in lines if l.startswith("destroyed ")}
    n_bodies = len(bodies)
    # The last frame lists the live dynamic bodies (the pebble, a handle >= n_bodies, is removed
    # at the shot's end); with no frame the level is as stored.
    poses = None
    for l in lines:
        if l.startswith("frame "):
            t = l.split()[2:]
            poses = [[int(v) for v in t[i : i + 5]] for i in range(0, len(t), 6)]
    if poses is None:
        poses = [[int(b[1]), *map(int, b[4:8])] for b in bodies if int(b[2]) != KIND_STATIC]
    state_hash = poseidon.hash_span(
        [v % P for handle, x, y, re_, im in poses if handle < n_bodies for v in (x, y, re_, im)]
    )
    return [
        level.felts[0], poseidon.hash_span(level.felts), level.felts[2], inputs[0],
        poseidon.hash_span(inputs), state[6], int(cores <= destroyed), state[1], state[5], state_hash,
    ]


def check_chain(level: Level, inputs: list[int], outputs: list[int], trace_lines: list[str],
                schedule: list[int], label: str) -> list[int]:
    state, lines = run_chain(level, inputs, schedule)
    derived = chain_outputs(level, inputs, state, lines)
    if derived != outputs:
        raise GoldenError(f"{label}: chained {schedule} outputs differ from main\n{diff_outputs(outputs, derived)}")
    if trace_lines is not None and lines != trace_lines:
        first = next((i for i, (a, b) in enumerate(zip(lines, trace_lines)) if a != b), min(len(lines), len(trace_lines)))
        raise GoldenError(f"{label}: chained {schedule} trace lines differ from main_trace at line {first}")
    return state


def diff_outputs(expected: list[int], got: list[int]) -> str:
    return "\n".join(
        f"  {n}: expected {e:#x}, got {g:#x}" for n, e, g in zip(OUTPUT_NAMES, expected, got) if e != g
    ) or f"  length {len(expected)} vs {len(got)}"


# --------------------------------------------------------------------------- cases

def load_cases() -> dict:
    return json.loads(CASES.read_text())


def case_inputs(case: dict) -> list[int]:
    return tracec.inputs_felts(tracec.DEFAULT_PLAYER, [tuple(s) for s in case["shots"]])


def evaluate_case(case: dict, levels: dict[str, Level], pool: ThreadPoolExecutor) -> dict:
    """Runs the three builds of one case; raises `GoldenError` unless they agree."""
    level, inputs, label = levels[case["level"]], case_inputs(case), case["name"]
    main_f = pool.submit(run_build, level, inputs, "main")
    trace_f = pool.submit(run_build, level, inputs, "main_trace")
    steps, outputs, _ = main_f.result()
    trace_steps, trace_outputs, trace_lines = trace_f.result()
    if trace_outputs != outputs:
        raise GoldenError(f"{label}: main_trace outputs differ from main\n{diff_outputs(outputs, trace_outputs)}")
    finals = list(pool.map(lambda s: check_chain(level, inputs, outputs, trace_lines, s, label), case["chunks"]))
    if any(f != finals[0] for f in finals):
        raise GoldenError(f"{label}: chunk schedules end on different states")
    return {"outputs": outputs, "steps": steps, "trace_steps": trace_steps}


def golden_doc(case: dict, result: dict) -> dict:
    return {
        "case": case["name"], "level": case["level"], "shots": case["shots"],
        "outputs": [hex(v) for v in result["outputs"]], "steps": result["steps"],
    }


def dumps_golden(doc: dict) -> str:
    return json.dumps({**doc, "shots": "@@"}, indent=2).replace(
        '"@@"', json.dumps(doc["shots"], separators=(",", ":")).replace("],[", "], [")) + "\n"


def cmd_run(args) -> int:
    doc = load_cases()
    cases = [c for c in doc["cases"]
             if (not args.case or c["name"] in args.case) and (not args.level or c["level"] in args.level)]
    if not cases:
        sys.exit("no such case")
    if not args.no_build:
        build()
    levels = {n: Level(n) for n in {c["level"] for c in cases}}
    margin = doc["step_margin"]
    failures, started = [], time.time()
    # Cases run one after the other, each spreading its builds over the pool: the memory of a
    # 30M-step `main` is held for one case at a time.
    with ThreadPoolExecutor(args.jobs) as pool:
        for case in cases:
            t = time.time()
            path = GOLDEN / f"{case['name']}.json"
            try:
                result = evaluate_case(case, levels, pool)
            except GoldenError as e:
                failures.append(str(e))
                print(f"FAIL {case['name']}: builds disagree ({time.time() - t:.0f} s)")
                continue
            new = golden_doc(case, result)
            if args.update:
                path.write_text(dumps_golden(new))
                print(f"wrote {path.relative_to(ROOT)}: {result['steps']:,} steps ({time.time() - t:.0f} s)")
                continue
            if not path.exists():
                failures.append(f"{case['name']}: no golden {path.relative_to(ROOT)} (run --update)")
                continue
            old = json.loads(path.read_text())
            problems = []
            if old["outputs"] != new["outputs"]:
                problems.append("outputs differ from the golden\n" + diff_outputs(
                    [int(v, 16) for v in old["outputs"]], result["outputs"]))
            if (old["level"], old["shots"]) != (new["level"], new["shots"]):
                problems.append("the golden is for other inputs (run --update)")
            ceiling = old["steps"] * margin
            if result["steps"] > ceiling:
                problems.append(f"main takes {result['steps']:,} steps, over the ceiling {ceiling:,.0f} "
                                f"(golden {old['steps']:,} x {margin})")
            note = ""
            if result["steps"] < old["steps"]:
                note = f", fewer steps than the golden {old['steps']:,}: run --update"
            if problems:
                failures.append(f"{case['name']}: " + "; ".join(problems))
            print(f"{'FAIL' if problems else 'ok  '} {case['name']}: {result['steps']:,} steps "
                  f"({time.time() - t:.0f} s){note}")
    for f in failures:
        print(f"::error::{f}" if args.github else f, file=sys.stderr)
    print(f"{len(cases) - len(failures)}/{len(cases)} cases ok in {time.time() - started:.0f} s")
    return 1 if failures else 0


# --------------------------------------------------------------------------- fuzz

def random_pull(rng: random.Random, radius: int) -> tuple[int, int]:
    """Inside the disk, on its axes, or in the square outside it (clamped by D3)."""
    kind = rng.choice(["inside", "inside", "outside", "axis"])
    if kind == "axis":
        return rng.choice([(-radius, 0), (0, -radius), (radius, 0), (0, radius), (0, 0)])
    if kind == "outside":
        return rng.randint(-PULL_MAX, PULL_MAX), rng.randint(-PULL_MAX, PULL_MAX)
    while True:
        x, y = rng.randint(-radius, radius), rng.randint(-radius, radius)
        if x * x + y * y <= radius * radius:
            return x, y


def random_schedule(rng: random.Random) -> list[int]:
    """A few small budgets (1..60), then a large tail: at most two chunks per 120-tick shot."""
    return [rng.choice([1, 1, 2, 3, 7, 13, 30, 60]) for _ in range(rng.randint(2, 5))] + [rng.choice([90, 400])]


def cmd_fuzz(args) -> int:
    if not args.no_build:
        build()
    rng = random.Random(args.seed)
    names = args.level or sorted(p.name[: -len(".felts.json")] for p in LEVELS.glob("*.felts.json"))
    levels = {n: Level(n) for n in names}
    samples = []
    for name in names:
        level = levels[name]
        radius = level.felts[12]  # pull_radius
        for _ in range(args.n):
            shots = [(*random_pull(rng, radius), rng.choice([0, 0, rng.randint(0, DELAY_MAX)]))
                     for _ in range(rng.randint(1, min(level.shots, args.max_shots)))]
            samples.append((name, shots, random_schedule(rng)))
    mismatches, started = [], time.time()

    def one(sample) -> None:
        name, shots, schedule = sample
        level, inputs = levels[name], tracec.inputs_felts(tracec.DEFAULT_PLAYER, shots)
        _, outputs, _ = run_build(level, inputs, "main")
        label = f"fuzz seed {args.seed} {name} shots {shots}"
        check_chain(level, inputs, outputs, None, schedule, label)

    with ThreadPoolExecutor(args.jobs) as pool:
        futures = [(s, pool.submit(one, s)) for s in samples]
        for s, fut in futures:
            try:
                fut.result()
                print(f"ok   {s[0]} {s[1]} chunks {s[2]}")
            except GoldenError as e:
                mismatches.append(str(e))
                print(f"FAIL {s[0]} {s[1]} chunks {s[2]}")
    for m in mismatches:
        print(m, file=sys.stderr)
    print(f"fuzz seed {args.seed}: {len(samples)} samples, {len(mismatches)} mismatches, {time.time() - started:.0f} s")
    return 1 if mismatches else 0


# --------------------------------------------------------------------------- to-cairo

def felt_lines(felts: list[int], indent: str) -> str:
    """felts as decimal literals, wrapped at 100 columns (`scarb fmt` style)."""
    lines, cur = [], indent
    for f in felts:
        item = f"{f}, "
        if len(cur) + len(item.rstrip()) > 100:
            lines.append(cur.rstrip())
            cur = indent
        cur += item
    lines.append(cur.rstrip())
    return "\n".join(lines)


def slug(name: str) -> str:
    return re.sub(r"\W", "_", name)


def cairo_source() -> str:
    doc = load_cases()
    used = sorted({c["level"] for c in doc["cases"]})
    out = [
        "//! Golden replays: `main` on the inputs of `fixtures/golden/cases.json` returns the felts of",
        "//! `fixtures/golden/<case>.json` (lot G5). Generated by `python3 tools/golden/golden.py to-cairo`",
        "//! (`--check` in CI): do not edit by hand.",
        "",
        "use slingfall_replay::main::main;",
        "use slingfall_testing::opaque;",
    ]
    for name in used:
        felts = tracec.load_level_felts(LEVELS / f"{name}.felts.json")
        out += ["", f"/// `fixtures/levels/{name}.json`: {len(felts)} felts.",
                f"fn {name}_felts() -> Array<felt252> {{", "    array![", felt_lines(felts, "        "), "    ]", "}"]
    for case in doc["cases"]:
        golden = json.loads((GOLDEN / f"{case['name']}.json").read_text())
        inputs = case_inputs(case)
        out += [
            "",
            f"/// {case['name']}: {case['level']}, shots {json.dumps(case['shots'])};",
            f"/// {golden['steps']:,} Cairo steps in `scarb execute`.",
            "#[test]",
            f"fn test_golden_{slug(case['name'])}() {{",
            "    let inputs = array![",
            felt_lines(inputs, "        "),
            "    ];",
            "    let expected = array![",
            felt_lines([int(v, 16) for v in golden["outputs"]], "        "),
            "    ];",
            f"    assert_eq!(main(opaque({case['level']}_felts()), opaque(inputs)), expected);",
            "}",
        ]
    return "\n".join(out) + "\n"


def cmd_to_cairo(args) -> int:
    source = cairo_source()
    if args.check:
        if not CAIRO_TESTS.exists() or CAIRO_TESTS.read_text() != source:
            print(f"{CAIRO_TESTS.relative_to(ROOT)} is stale: python3 tools/golden/golden.py to-cairo, then scarb fmt", file=sys.stderr)
            return 1
        print(f"{CAIRO_TESTS.relative_to(ROOT)} is current")
        return 0
    CAIRO_TESTS.parent.mkdir(parents=True, exist_ok=True)
    CAIRO_TESTS.write_text(source)
    print(f"wrote {CAIRO_TESTS.relative_to(ROOT)}")
    return 0


# --------------------------------------------------------------------------- main

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")

    def common(p) -> None:
        p.add_argument("-j", "--jobs", type=int, default=4, help="parallel `scarb execute` processes")
        p.add_argument("--no-build", action="store_true", help="the executables are already built")

    run = sub.add_parser("run", help="goldens: three builds agree and equal the committed goldens (default)")
    common(run)
    group = run.add_mutually_exclusive_group()
    group.add_argument("--check", action="store_true", help="fail on any difference (default)")
    group.add_argument("--update", action="store_true", help="rewrite the goldens")
    run.add_argument("--case", action="append")
    run.add_argument("--level", action="append", help="only the cases on this level fixture")
    run.add_argument("--github", action="store_true", help="print failures as GitHub annotations")
    fuzz = sub.add_parser("fuzz", help="random inputs: main equals chained chunks")
    common(fuzz)
    fuzz.add_argument("--seed", type=int, required=True)
    fuzz.add_argument("--n", type=int, default=6, help="samples per level")
    fuzz.add_argument("--level", action="append")
    fuzz.add_argument("--max-shots", type=int, default=3, help="most shots of a sample")
    cairo = sub.add_parser("to-cairo", help="write (or --check) the snforge tests")
    cairo.add_argument("--check", action="store_true")
    argv = sys.argv[1:]
    if not argv or argv[0].startswith("-") and argv[0] not in ("-h", "--help"):
        argv = ["run", *argv]
    args = parser.parse_args(argv)
    try:
        code = {"run": cmd_run, "fuzz": cmd_fuzz, "to-cairo": cmd_to_cairo}[args.command](args)
    except GoldenError as e:
        print(e, file=sys.stderr)
        code = 1
    sys.exit(code)


if __name__ == "__main__":
    main()
