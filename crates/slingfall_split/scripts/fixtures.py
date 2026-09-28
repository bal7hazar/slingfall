#!/usr/bin/env python3
"""Fixtures of spike S36a: main's own chunk states at the window boundaries of the two reference
shots, from main's executables (`crates/slingfall_replay`, rapier2d alpha.6, `scarb execute`),
so that the spike's layouts (rapier2d alpha.7) are checked against `main` itself.

    python3 crates/slingfall_split/scripts/fixtures.py [--no-build]

Writes `crates/slingfall_split/fixtures/<case>/`:

* `inputs.txt`: the `Inputs` felts;
* `state_<tick>.txt`: the `ChunkState` felts `init` / `step_chunk` return (without the binding
  header) after `<tick>` ticks, for each boundary of `CASES`;
* `outputs.txt`: the 10 D4 felts of `main` on the case.

One felt per line (hex), the format `snforge_std::fs::read_txt` reads. Python 3 standard library
only; the `scarb execute` helpers are `tools/golden/golden.py`'s.
"""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "golden"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import golden  # noqa: E402
import heavy  # noqa: E402

OUT = ROOT / "crates" / "slingfall_split" / "fixtures"
OWNER = 123610794124658  # the owner's player (docs/briefs/b5-bump-rapier2d-alpha7.md)

# case: (level, player, shot (pull_x, pull_y, delay), window boundaries in ticks): the flight
# (first contact at tick 43 on both shots), then 10-tick windows, the granularity at which the
# transactions of at most 10M steps are packed (docs/research/07-split-game-step.md).
CASES = {
    "reference": ("pile10", golden.tracec.DEFAULT_PLAYER, (-604, -392, 0),
                  [0, 40, *range(50, 107, 10), 107]),
    "owner": ("pile10", OWNER, (-1022, -63, 0), [0, 40, *range(50, 151, 10), 151]),
}


def write(path: Path, felts: list[int]) -> None:
    path.write_text("".join(f"{hex(f % golden.P)}\n" for f in felts))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--no-build", action="store_true")
    args = ap.parse_args()
    _lock = heavy.locked()
    if not args.no_build:
        golden.build()
    for name, (level_name, player, shot, bounds) in CASES.items():
        level = golden.Level(level_name)
        inputs = golden.tracec.inputs_felts(player, [shot])
        out = OUT / name
        out.mkdir(parents=True, exist_ok=True)
        write(out / "inputs.txt", inputs)
        _, outputs, _ = golden.run_build(level, inputs, "main")
        write(out / "outputs.txt", outputs)
        state, _ = level.init()
        write(out / "state_0.txt", state)
        for start, end in zip(bounds, bounds[1:]):
            steps, state, _ = golden.execute(
                "step_chunk", [len(state), *state, len(inputs), *inputs, 0, end - start, 0])
            write(out / f"state_{end}.txt", state)
            print(f"{name}: ticks {start}-{end}: {steps:,} steps (main's step_chunk), "
                  f"over {state[2]}, tick {state[5]}", file=sys.stderr)
        print(f"{name}: outputs {[hex(o) for o in outputs]}", file=sys.stderr)


if __name__ == "__main__":
    main()
