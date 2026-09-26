"""rules: `levelc.py check --rules`, the rule-level validator of a level (lot G8).

It runs the level through the replay executables (`crates/slingfall_replay`, built:
`scarb --manifest-path crates/slingfall_replay/Scarb.toml build`; through `tools/settle/replay.py`)
and checks what the JSON and felts cannot say:

1. `tick_cap >= 140` (a shot needs time to fall and settle) and at least one core;
2. **at rest**: `main_trace` with a (0, 0) pull, 120 ticks: no `damage` line (the level starts
   asleep, so this alone is a weak test: the pebble falls at the sling and the pile is untouched);
3. **awake**: every pile of dynamic bodies is woken by the settle probe (`tools/settle/settle.py`:
   a pebble rolling away from the pile's side) and must take no damage while it settles, sleep
   again within the probe, and end on the poses it started on (so the level is *pre-settled*: a
   settle would move nothing). This is the static-load note of `crates/slingfall_rules/README.md`:
   a woken pile whose supports carry more than their material's `force_threshold` hurts itself;
4. **reachable cores**: 12 pulls (`GRID`: 4 angles x 3 magnitudes, the sling pulled down-left),
   each through `main_trace`; every core must be destroyed by at least one of them;
5. **step budget**: the reference shots (the best single pull of the grid, a win with the highest
   score; on a level no single pull wins, one grid pull per core, in core order, one shot each)
   run through `main` (the proof build, no prints) must win, and take fewer Cairo steps than
   `--budget` (default 1e8, the interim budget of the brief; the target of D10 is 3e7, a warning).

Fixtures written by hand before the settle tool (`LEGACY`: their poses and goldens are frozen by
the committed goldens) get the awake test as a warning, not a failure.
"""

from __future__ import annotations

import math
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "settle"))
import levelc  # noqa: E402
import replay  # noqa: E402
import settle  # noqa: E402

MIN_TICK_CAP = 140
REST_TICKS = 120
ANGLES = (25, 33, 41, 50)  # degrees above the horizontal
MAGNITUDES = (600, 720, 850)  # pull length (launch speed 12 / 14.4 / 17 m/s at launch_scale 0.02)
BUDGET_INTERIM = 100_000_000
BUDGET_TARGET = 30_000_000
LEGACY = {"one_block"}
PROBE_TICKS = 120


def grid(radius: int) -> list[tuple[int, int]]:
    """The 12 pulls: down-left (the sling is on the left, the pebble flies right)."""
    return [(-round(min(m, radius) * math.cos(math.radians(a))), -round(min(m, radius) * math.sin(math.radians(a))))
            for m in MAGNITUDES for a in ANGLES]


@dataclass
class Report:
    name: str
    failures: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    lines: list[str] = field(default_factory=list)
    best: list[tuple[int, int]] | None = None  # the reference shots
    best_steps: int | None = None
    best_score: int | None = None
    runs: list[tuple[tuple[int, int], replay.Run]] = field(default_factory=list)

    def ok(self) -> bool:
        return not self.failures


def check_level(path: Path, jobs: int = 2, pulls: list[tuple[int, int]] | None = None,
                budget: int = BUDGET_INTERIM, log=print) -> Report:
    name = path.name.removesuffix(".json")
    rep = Report(name)
    legacy = name in LEGACY
    level = levelc.canonical(levelc.load_level(path))
    felts = levelc.level_to_felts(level)
    say = lambda text: (rep.lines.append(text), log(f"  {name}: {text}"))  # noqa: E731

    if level["tick_cap"] < MIN_TICK_CAP:
        rep.failures.append(f"tick_cap {level['tick_cap']} < {MIN_TICK_CAP}")
    cores = [i for i, b in enumerate(level["bodies"]) if b["kind"] == "core"]
    if not cores:
        rep.failures.append("no core")

    pulls = pulls or grid(level["pull_radius"])
    with ThreadPoolExecutor(jobs) as pool:
        rest_f = pool.submit(replay.run, "main_trace", felts, [(0, 0, 0)])
        try:
            piles = settle.piles(level)
        except settle.SettleError as e:
            piles = []
            rep.failures.append(str(e))
        awake_f = [pool.submit(awake_probe, level, pile) for pile in piles]
        grid_f = [pool.submit(replay.run, "main_trace", felts, [(*pull, 0)]) for pull in pulls]

        rest = rest_f.result()
        if rest.damage:
            rep.failures.append(f"at rest: {len(rest.damage)} damage lines over {rest.ticks} ticks")
        say(f"at rest (pull (0, 0)): {rest.ticks} ticks, {len(rest.damage)} damage lines")

        for k, future in enumerate(awake_f):
            problems, info = future.result()
            say(f"awake, pile {k} ({len(piles[k])} bodies): {info}")
            (rep.warnings if legacy else rep.failures).extend(f"awake, pile {k}: {p}" for p in problems)

        reached: dict[int, tuple[int, int]] = {}
        for pull, future in zip(pulls, grid_f):
            run = future.result()
            rep.runs.append((pull, run))
            for handle in run.destroyed_cores():
                reached.setdefault(handle, pull)
            say(f"pull {pull}: won {int(run.won)}, score {run.score}, {run.ticks} ticks, "
                f"cores destroyed {sorted(run.destroyed_cores())}; destroyed in all "
                f"{tally(level, run, 0, run.ticks)}, in the first hit {tally(level, run, *first_hit(run))}")
        for core in cores:
            if core not in reached:
                rep.failures.append(f"core {core} is destroyed by none of the {len(pulls)} pulls")
        say(f"cores reached: {', '.join(f'{c} by {reached[c]}' for c in cores if c in reached) or 'none'}")

        wins = [(pull, run) for pull, run in rep.runs if run.won]
        if wins:
            best_pull, best = max(wins, key=lambda w: (w[1].score, -w[1].ticks))
            rep.best = [best_pull]
        else:
            # No single pull wins (a two-pile level): the pulls that reach the cores, one shot each.
            rep.best = list(dict.fromkeys(reached[c] for c in cores if c in reached))
            best = None
            if not 0 < len(rep.best) <= level["shots"]:
                rep.failures.append(f"no pull wins the level and {len(rep.best)} pulls reach the cores "
                                    f"({level['shots']} shots)")
                return rep
        main = pool.submit(replay.run, "main", felts, [(*pull, 0) for pull in rep.best]).result()
        rep.best_steps, rep.best_score = main.steps, main.score
        if best is not None and main.outputs != best.outputs:
            rep.failures.append("main and main_trace disagree on the best pull")
        if not main.won:
            rep.failures.append(f"the shots {rep.best} do not win the level")
        say(f"reference shots {rep.best}: won {int(main.won)}, score {main.score}, {main.ticks} ticks, "
            f"{main.steps:,} steps in `main` (proof build)")
        if main.steps > budget:
            rep.failures.append(f"the reference shots take {main.steps:,} steps, over the budget {budget:,}")
        elif main.steps > BUDGET_TARGET * len(rep.best):
            rep.warnings.append(f"the reference shots take {main.steps:,} steps, over the 3e7 per shot target of D10")
    return rep


MATERIAL_NAMES = {50: "timber", 100: "frost", 150: "slate", 1000: "core"}  # by score, D7


def first_hit(run: replay.Run) -> tuple[int, int]:
    """Ticks of the first hit: from the first destruction to two ticks later."""
    first = min((t for t, _ in run.destroyed), default=0)
    return first, first + 2


def tally(level: dict, run: replay.Run, start: int, stop: int) -> str:
    """Bodies destroyed in the ticks [start, stop], by material name."""
    counts: dict[str, int] = {}
    for tick, handle in run.destroyed:
        if start <= tick <= stop:
            score = level["materials"][run.bodies[handle][1]]["score"]
            name = MATERIAL_NAMES.get(score, f"m{run.bodies[handle][1]}")
            counts[name] = counts.get(name, 0) + 1
    return "{" + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + "}"


def awake_probe(level: dict, pile: list[int]) -> tuple[list[str], str]:
    """Wakes the pile (the settle probe) and reports what a settle would change."""
    problems: list[str] = []
    try:
        wake = settle.wake_position(level, pile)
        run = settle.probe_run(level, pile, wake, PROBE_TICKS)
    except settle.SettleError as e:
        return [str(e)], "probe failed"
    _, last = run.frames[-1]
    if run.damage:
        problems.append(f"{len(run.damage)} damage lines while awake (first: tick {run.damage[0][0]} body "
                        f"{run.damage[0][1]}): a support carries more than its force_threshold")
    if not all(last[i][4] for i in pile):
        problems.append(f"still awake at tick {run.frames[-1][0]}")
    moved = [i for i in pile if settle.snap(*last[i][:4], settle.DEFAULT_STEP) != settle.pose_raw(level, i)]
    if moved:
        problems.append(f"not pre-settled: a settle moves bodies {moved} (run tools/settle/settle.py)")
    return problems, f"{len(run.damage)} damage lines, {len(moved)} bodies move, {run.steps:,} steps"
