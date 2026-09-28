#!/usr/bin/env python3
"""Re-pins the class hashes of `src/hashes.cairo` after a change of this crate's classes: runs
`snforge test test_pinned_class_hashes` and rewrites the constants it reports as stale.

    python3 crates/slingfall_split/scripts/pin.py

A class's hash changes with its code; the world classes compile them as constants (as a game
would after declaring), so a stale pin makes their library calls fail. Rebuild after pinning (the
world classes' own hashes then change, which nothing pins). Python 3 standard library only.
"""
import re
import subprocess
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
HASHES = PACKAGE / "src" / "hashes.cairo"
PIN = re.compile(r"^pin (\w+) ([0-9a-f]+)$", re.M)


def constant(name: str) -> str:
    """`RulesClass` -> `RULES_HASH`, `ContactBallClass` -> `CONTACT_BALL_HASH`."""
    base = name[: -len("Class")] if name.endswith("Class") else name
    return re.sub(r"(?<!^)(?=[A-Z])", "_", base).upper() + "_HASH"


def main() -> int:
    run = subprocess.run(["snforge", "test", "test_pinned_class_hashes"], cwd=PACKAGE,
                         capture_output=True, text=True)
    pins = PIN.findall(run.stdout)
    if not pins:
        print("pins up to date" if run.returncode == 0 else run.stdout[-3000:], file=sys.stderr)
        return run.returncode
    text = HASHES.read_text()
    for name, value in pins:
        const = constant(name)
        text, n = re.subn(rf"(pub const {const}: felt252 =\s*)0x[0-9a-fA-F]+;", rf"\g<1>0x{value};",
                          text)
        if n != 1:
            sys.exit(f"{const} not found in {HASHES}")
        print(f"{const} = 0x{value}", file=sys.stderr)
    HASHES.write_text(text)
    subprocess.run(["scarb", "fmt"], cwd=PACKAGE, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
