"""replay: run a level through the replay executables and read the trace lines (lot G8).
Python 3 standard library only; shared by `settle.py` and `levelc.py check --rules`.

`run(name, level_felts, shots)` executes one built executable of `crates/slingfall_replay` with
`golden.execute` (`scarb execute --no-build`, so `scarb build` first) and parses the trace lines
v1 (`crates/slingfall_replay/README.md`) into a `Run`. Raw values stay signed integers (Q32.32).
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
for tool in ("golden", "tracec", "levelc"):
    sys.path.insert(0, str(ROOT / "tools" / tool))
import golden  # noqa: E402
import tracec  # noqa: E402

KIND_STATIC, KIND_BLOCK, KIND_CORE = 0, 1, 2


@dataclass
class Run:
    steps: int
    outputs: list[int]
    bodies: dict[int, tuple[int, int]] = field(default_factory=dict)  # handle -> (kind, material)
    frames: list[tuple[int, dict[int, tuple[int, int, int, int, bool]]]] = field(default_factory=list)
    damage: list[tuple[int, int, int]] = field(default_factory=list)  # (tick, handle, hp)
    destroyed: list[tuple[int, int]] = field(default_factory=list)  # (tick, handle)
    score: int = 0
    won: bool = False
    ticks: int = 0
    shot_end: int | None = None

    def destroyed_cores(self) -> set[int]:
        return {h for _, h in self.destroyed if self.bodies[h][0] == KIND_CORE}


def parse(lines: list[str], steps: int, outputs: list[int]) -> Run:
    run = Run(steps, outputs)
    for line in lines:
        t = line.split()
        if t[0] == "body":
            run.bodies[int(t[1])] = (int(t[2]), int(t[3]))
        elif t[0] == "frame":
            v = t[2:]
            run.frames.append((int(t[1]), {
                int(v[i]): (int(v[i + 1]), int(v[i + 2]), int(v[i + 3]), int(v[i + 4]), v[i + 5] == "1")
                for i in range(0, len(v), 6)
            }))
        elif t[0] == "damage":
            run.damage.append((int(t[1]), int(t[2]), int(t[3])))
        elif t[0] == "destroyed":
            run.destroyed.append((int(t[1]), int(t[2])))
        elif t[0] == "shot_end":
            run.shot_end = int(t[1])
    run.score, run.won, run.ticks = outputs[5], bool(outputs[6]), outputs[8]
    return run


def run(name: str, level_felts: list[int], shots: list[tuple[int, int, int]]) -> Run:
    """`name` is `main` or `main_trace`; the trace lines are empty for `main`."""
    args = [len(level_felts), *level_felts]
    inputs = tracec.inputs_felts(tracec.DEFAULT_PLAYER, shots)
    steps, outputs, lines = golden.execute(name, [*args, len(inputs), *inputs])
    return parse(lines, steps, outputs)
