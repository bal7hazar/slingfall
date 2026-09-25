#!/usr/bin/env python3
"""Cairo steps of the replay executables, measured with `scarb execute --print-resource-usage`
(lot G4; the README's tables). Python 3 standard library only. From the repository root:

    python3 crates/slingfall_replay/scripts/measure.py [--case NAME]... [--chunk K]... [--trace-out DIR]

Per case: `main` (steps, outputs), `main_trace` (steps, same outputs, the lines kept under
`--trace-out`), and for each `--chunk K`: `init` then `step_chunk(state, inputs, shot, K, 0)` until
the level is over or the inputs end, summing the steps; the final state's header (`tick`, `score`,
`shots_used`) is checked against `main`'s outputs (the bit-for-bit comparison, `final_state_hash`
included, is the snforge test `chunk::tests::test_chain_*`). Prints Markdown tables.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MANIFEST = ROOT / "crates" / "slingfall_replay" / "Scarb.toml"
sys.path.insert(0, str(ROOT / "tools" / "tracec"))
import tracec  # noqa: E402

P = tracec.P
REFERENCE = (-600, -392, 0)
CASES = {
    "pile10-1": ("pile10", [REFERENCE]),
    # Two short shots that fall before the pile, then the reference shot.
    "pile10-3": ("pile10", [(-150, -150, 0), (-200, -200, 0), REFERENCE]),
    "cores3-1": ("cores3", [REFERENCE]),
    "cores3-3": ("cores3", [(-150, -150, 0), (-200, -200, 0), REFERENCE]),
    "one_block-1": ("one_block", [REFERENCE]),
}
STEPS_RE = re.compile(r"^\s*steps:\s*([\d,]+)", re.M)


def execute(name: str, felts: list[int]) -> tuple[int, list[int], list[str]]:
    """Runs one executable; returns (steps, returned felts, printed lines)."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump([hex(x % P) for x in felts], f)
        args = f.name
    out = subprocess.run(
        ["scarb", "--manifest-path", str(MANIFEST), "execute", "--executable-name", name,
         "--arguments-file", args, "--print-program-output", "--print-resource-usage"],
        capture_output=True, text=True, check=False,
    )
    Path(args).unlink()
    text = out.stdout
    if out.returncode != 0 or "Program output:" not in text:
        sys.exit(f"{name}: failed\n{text}\n{out.stderr}")
    head, rest = text.split("Program output:", 1)
    body = rest.split("Resources:", 1)[0].split()
    # `[len, felt...]`, printed as signed decimals.
    values = [int(v) % P for v in body]
    returned = values[1 : 1 + values[0]]
    steps = int(STEPS_RE.search(rest).group(1).replace(",", ""))
    lines = [l for l in head.splitlines() if l and not l.lstrip().startswith(("Compiling", "Finished", "Executing"))]
    return steps, returned, lines


def run_case(name: str, chunks: list[int], trace_out: Path | None) -> dict:
    level_name, shots = CASES[name]
    level = tracec.load_level_felts(ROOT / "fixtures" / "levels" / f"{level_name}.felts.json")
    inputs = tracec.inputs_felts(tracec.DEFAULT_PLAYER, shots)
    args = [len(level), *level, len(inputs), *inputs]
    main_steps, outputs, _ = execute("main", args)
    trace_steps, trace_outputs, lines = execute("main_trace", args)
    if trace_outputs != outputs:
        sys.exit(f"{name}: main_trace outputs differ from main")
    if trace_out:
        trace_out.mkdir(parents=True, exist_ok=True)
        (trace_out / f"{name}.lines.txt").write_text("\n".join(lines) + "\n")
    result = {
        "case": name, "shots": len(shots), "outputs": outputs, "main": main_steps, "trace": trace_steps,
        "frames": sum(1 for l in lines if l.startswith("frame ")), "chunks": {},
    }
    score, won, shots_used, ticks = outputs[5], outputs[6], outputs[7], outputs[8]
    for k in chunks:
        init_steps, state, _ = execute("init", [len(level), *level])
        total, calls, shot = init_steps, 0, 0
        while shot < len(shots) and state[2] == 0:
            steps, state, _ = execute("step_chunk", [len(state), *state, len(inputs), *inputs, shot, k, 0])
            total += steps
            calls += 1
            if state[1] == shot + 1:
                shot += 1
        if (state[5], state[6], state[1]) != (ticks, score, shots_used):
            sys.exit(f"{name}, K = {k}: chunked header {state[:7]} differs from main {outputs}")
        result["chunks"][k] = (init_steps, total, calls)
    return result


def per_shot(name: str, k: int) -> None:
    """Chunked only (a whole multi-shot `main` run needs more memory than the shared machine gives
    one process: the VM keeps every cell): steps per shot = the shot's `step_chunk` steps minus one
    `k = 0` round trip per chunk (measured on the initial state)."""
    level_name, shots = CASES[name]
    level = tracec.load_level_felts(ROOT / "fixtures" / "levels" / f"{level_name}.felts.json")
    inputs = tracec.inputs_felts(tracec.DEFAULT_PLAYER, shots)
    init_steps, state, _ = execute("init", [len(level), *level])
    trip, _, _ = execute("step_chunk", [len(state), *state, len(inputs), *inputs, 0, 0, 0])
    rows, shot, gross, calls, before = [], 0, 0, 0, 0
    while shot < len(shots) and state[2] == 0:
        steps, state, _ = execute("step_chunk", [len(state), *state, len(inputs), *inputs, shot, k, 0])
        gross, calls = gross + steps, calls + 1
        if state[1] == shot + 1:
            ticks = state[5] - before
            rows.append((shot, ticks, gross, calls, gross - calls * trip, state[6]))
            shot, gross, calls, before = shot + 1, 0, 0, state[5]
    print(f"{name}, K = {k}: init {init_steps:,}, round trip (k = 0) {trip:,}, over = {state[2]}")
    print("| shot | ticks | chunks | gross | net (minus round trips) | per tick | score after |")
    print("|---:|---:|---:|---:|---:|---:|---:|")
    for s, ticks, g, c, net, score in rows:
        print(f"| {s} | {ticks} | {c} | {g:,} | {net:,} | {net // max(ticks, 1):,} | {score} |")
    total = sum(r[4] for r in rows)
    print(f"level: {state[5]} ticks, net {total:,} + init {init_steps:,} = {total + init_steps:,}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--case", action="append", choices=sorted(CASES))
    parser.add_argument("--chunk", action="append", type=int, default=[])
    parser.add_argument("--trace-out", type=Path)
    parser.add_argument("--per-shot", type=int, metavar="K", help="chunked per-shot table only, chunks of K ticks")
    args = parser.parse_args()
    if args.per_shot:
        for c in args.case or list(CASES):
            per_shot(c, args.per_shot)
        return
    results = [run_case(c, args.chunk, args.trace_out) for c in (args.case or list(CASES))]
    print("| case | shots played | score | won | ticks | `main` steps | per shot | per tick | `main_trace` | trace overhead |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for r in results:
        o = r["outputs"]
        print(
            f"| {r['case']} | {o[7]} | {o[5]} | {o[6]} | {o[8]} | {r['main']:,} | {r['main'] // max(o[7], 1):,} "
            f"| {r['main'] // max(o[8], 1):,} | {r['trace']:,} | {100 * (r['trace'] - r['main']) / r['main']:.1f} % |"
        )
    if args.chunk:
        print()
        print("| case | K | `init` | `init` + chunks | chunks | overhead vs `main` | per chunk |")
        print("|---|---:|---:|---:|---:|---:|---:|")
        for r in results:
            for k, (init_steps, total, calls) in r["chunks"].items():
                extra = total - r["main"]
                print(f"| {r['case']} | {k} | {init_steps:,} | {total:,} | {calls} | {extra:,} | {extra // calls:,} |")


if __name__ == "__main__":
    main()
