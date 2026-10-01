#!/usr/bin/env python3
"""Regenerates the pinned class hashes of `src/hashes.cairo` (`ClassHashes` constants) after a
change of a class of this crate, or of `rapier2d_classes`: runs `snforge test test_pinned_class_hashes`,
rewrites the constants it reports as stale, and repeats until nothing is stale.

    python3 crates/slingfall_split/scripts/pin.py            # the default build's classes
    python3 crates/slingfall_split/scripts/pin.py --probes   # the alternatives' class (`src/probes/hashes.cairo`)
    python3 crates/slingfall_split/scripts/pin.py --check    # print the stale pins, change nothing

A class's hash changes with its code; the classes that library-call others compile their hashes as
constants (as a game would after declaring), so a stale pin makes their library calls fail. Pinning
one class changes the classes that compile it, hence the loop: `RulesClass`, `EditClass`,
`StepClass` first, then `WorldClass` and `FallbackGame`, which compile them. CI runs the test:
a class changed without this script fails it. Python 3 standard library only.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

# Sierra is not deterministic across compiler threads (docs/proving.md "Deterministic builds"):
# every build of this script runs on one.
os.environ["RAYON_NUM_THREADS"] = "1"
PACKAGE = Path(__file__).resolve().parents[1]
PIN = re.compile(r"^pin (\w+) ([0-9a-f]+)$", re.M)
MAX_ROUNDS = 5


def constant(name: str) -> str:
    """`RulesClass` -> `RULES_HASH`, `ContactBallClass` -> `CONTACT_BALL_HASH`,
    `FallbackGame` -> `FALLBACK_GAME_HASH`."""
    base = name[: -len("Class")] if name.endswith("Class") else name
    return re.sub(r"(?<!^)(?=[A-Z])", "_", base).upper() + "_HASH"


def stale(probes: bool) -> tuple[int, list[tuple[str, str]], str]:
    """-> (snforge's exit code, [(class, hash)] it reports as stale, its output)."""
    test = "test_pinned_probe_hashes" if probes else "test_pinned_class_hashes"
    cmd = ["snforge", "test", test] + (["--features", "probes"] if probes else [])
    run = subprocess.run(cmd, cwd=PACKAGE, capture_output=True, text=True)
    return run.returncode, PIN.findall(run.stdout), run.stdout


def rewrite(path: Path, pins: list[tuple[str, str]]) -> None:
    text = path.read_text()
    for name, value in pins:
        const = constant(name)
        text, n = re.subn(rf"(pub const {const}: felt252 =\s*)0x[0-9a-fA-F]+;", rf"\g<1>0x{value};",
                          text)
        if n != 1:
            sys.exit(f"{const} not found in {path}")
        print(f"{const} = 0x{value}", file=sys.stderr)
    path.write_text(text)
    subprocess.run(["scarb", "fmt"], cwd=PACKAGE, check=True)


def main() -> int:
    probes = "--probes" in sys.argv
    path = PACKAGE / "src" / ("probes/hashes.cairo" if probes else "hashes.cairo")
    for _ in range(MAX_ROUNDS):
        code, pins, out = stale(probes)
        if not pins:
            if code:
                print(out[-3000:], file=sys.stderr)
            else:
                print("pins up to date", file=sys.stderr)
            return code
        if "--check" in sys.argv:
            for name, value in pins:
                print(f"stale: {constant(name)} = 0x{value}", file=sys.stderr)
            return 1
        rewrite(path, pins)
    print(f"pins still stale after {MAX_ROUNDS} rounds", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
