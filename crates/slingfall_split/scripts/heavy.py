#!/usr/bin/env python3
"""Runs a command under the machine's heavy-run lock (`flock ~/orchestrator/heavy-build.lock`,
the brief's rule for whole-shot runs), from the spike's package directory.

    python3 crates/slingfall_split/scripts/heavy.py snforge test <filter> [...]

Python 3 standard library only.
"""
import fcntl
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
    return subprocess.run(sys.argv[1:], cwd=PACKAGE).returncode


if __name__ == "__main__":
    sys.exit(main())
