#!/usr/bin/env python3
"""Run one command, report wall time, exit status and peak RSS (a `/usr/bin/time -v`
substitute: `ru_maxrss` of the waited child, per child through `os.wait4`). Also samples the
cgroup's `memory.current` every 0.5 s to record the peak of the whole unit. From E1L (research 05),
importable by `prove.py` (`measure(...)`).

usage: measure.py <label> <log> [KEY=VAL...] -- <cmd...>
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "out" / "results.txt"


def cgroup_dir() -> Path | None:
    try:
        rel = Path("/proc/self/cgroup").read_text().strip().split("::")[-1]
    except OSError:
        return None
    return Path(f"/sys/fs/cgroup{rel}")


def read(path: Path | None) -> str:
    try:
        return path.read_text().strip() if path else "?"
    except OSError:
        return "?"


def memory_max() -> str:
    """The unit's cgroup `memory.max` (bytes or `max`), `?` when unreadable."""
    cg = cgroup_dir()
    return read(cg / "memory.max" if cg else None)


def measure(cmd: list[str], log: Path, env: dict[str, str] | None = None) -> dict:
    """Runs `cmd` with stdout and stderr to `log`. Returns exit, wall (s), maxrss (bytes, the
    child's `ru_maxrss`), the cgroup's base and sampled peak (bytes, -1 when unreadable)."""
    cg = cgroup_dir()
    current = cg / "memory.current" if cg else None
    base = read(current)
    peak = [0]
    stop = threading.Event()

    def sample() -> None:
        while not stop.is_set():
            v = read(current)
            if v.isdigit():
                peak[0] = max(peak[0], int(v))
            stop.wait(0.5)

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    t0 = time.time()
    with open(log, "w") as f:
        p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, env={**os.environ, **(env or {})})
        _, status, ru = os.wait4(p.pid, 0)
        p.returncode = os.waitstatus_to_exitcode(status)
    wall = time.time() - t0
    stop.set()
    sampler.join()
    return {
        "exit": p.returncode,
        "wall_s": round(wall, 1),
        "maxrss_bytes": ru.ru_maxrss * 1024,
        "cgroup_base_bytes": int(base) if base.isdigit() else -1,
        "cgroup_peak_bytes": peak[0] if peak[0] else -1,
        "memory_max": read(cg / "memory.max" if cg else None),
    }


def gib(n: int) -> str:
    return f"{n / 2**30:.2f}" if n >= 0 else "?"


def line(label: str, m: dict) -> str:
    return (f"{label}: exit={m['exit']} wall={m['wall_s']:.1f}s maxrss={gib(m['maxrss_bytes'])}GiB "
            f"memory.max={m['memory_max']} cgroup_base={gib(m['cgroup_base_bytes'])}GiB "
            f"cgroup_peak_sampled={gib(m['cgroup_peak_bytes'])}GiB")


def main() -> int:
    label, log = sys.argv[1], Path(sys.argv[2])
    sep = sys.argv.index("--")
    env = dict(kv.split("=", 1) for kv in sys.argv[3:sep])
    m = measure(sys.argv[sep + 1:], log, env)
    text = line(label, m)
    print(text)
    RESULTS.parent.mkdir(parents=True, exist_ok=True)
    with open(RESULTS, "a") as f:
        f.write(text + "\n")
    return m["exit"]


if __name__ == "__main__":
    sys.exit(main())
