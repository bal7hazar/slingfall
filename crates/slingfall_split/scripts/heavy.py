#!/usr/bin/env python3
"""Runs a command under the machine's heavy-run lock (`flock ~/orchestrator/heavy-build.lock`,
the brief's rule for whole-shot runs), from the spike's package directory.

    python3 crates/slingfall_split/scripts/heavy.py snforge test <filter> [...]

Python 3 standard library only.
"""
import fcntl
import resource
import subprocess
import sys
from pathlib import Path

LOCK = Path.home() / "orchestrator" / "heavy-build.lock"
PACKAGE = Path(__file__).resolve().parents[1]


def locked():
    """The lock, held until the process exits."""
    handle = open(LOCK, "a")
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def main() -> int:
    _lock = locked()
    code = subprocess.run(sys.argv[1:], cwd=PACKAGE).returncode
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 2**20
    print(f"heavy.py: peak RSS of the run {peak:.1f} GiB", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
