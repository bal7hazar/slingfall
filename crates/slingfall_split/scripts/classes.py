#!/usr/bin/env python3
"""Derives every list of the game's declared classes from `crates/slingfall_split/classes.json`
(lot H3: the classes layouts (e) and (b) really library-call, measured by `tests/called.cairo`).

    python3 crates/slingfall_split/scripts/classes.py            # rewrite the derived lists
    python3 crates/slingfall_split/scripts/classes.py --check    # exit 1 when one is out of date
    python3 crates/slingfall_split/scripts/classes.py --measure  # run tests/called.cairo (heavy), compare

Derived: `Scarb.toml`'s `build-external-contracts`, `tests/harness.cairo`'s `classes()`,
`src/hashes.cairo`'s `pinned()` entries of the rapier classes (a new class gets a placeholder
constant: run `pin.py` next), `client/src/chain/slingfall.ts`'s `SPLIT_BUNDLE_CLASSES`. Run
`scarb fmt --workspace` after a rewrite (`--check` ignores the formatter's layout).
`services/prove/snip36.py` reads the JSON itself. Python 3 standard library only.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[1]
CLASSES = json.loads((PACKAGE / "classes.json").read_text())
CHAIN, RAPIER = CLASSES["chain"], CLASSES["rapier"]
BUNDLE = CHAIN + list(RAPIER)
TS = ROOT / "client" / "src" / "chain" / "slingfall.ts"


def constant(name: str) -> str:
    base = name[: -len("Class")] if name.endswith("Class") else name
    return re.sub(r"(?<!^)(?=[A-Z])", "_", base).upper() + "_HASH"


def scarb(text: str) -> str:
    paths = ",\n".join(f'    "rapier2d_classes::{module}::{name}"' for name, module in RAPIER.items())
    return re.sub(r"build-external-contracts = \[[^\]]*\]", f"build-external-contracts = [\n{paths},\n]", text)


def harness(text: str) -> str:
    """Both `classes()` bodies: the rapier classes, then the rest of each array as it is."""
    listed = ", ".join(f'"{n}"' for n in RAPIER)
    return re.sub(r'(pub fn classes\(\) -> Array<ByteArray> \{\n    array!\[\n)(.*?)("RulesClass")',
                  lambda m: f"{m[1]}        {listed},\n        {m[3]}", text, flags=re.S)


def hashes(text: str) -> str:
    head, tail = text.split("pub fn pinned()")
    entries = ", ".join(f'("{n}", {constant(n)})' for n in RAPIER)
    tail = re.sub(r"array!\[\n.*?(\(\"RulesClass\")", lambda m: f"array![\n        {entries},\n        {m[1]}", tail,
                  count=1, flags=re.S)
    for name in RAPIER:
        if not re.search(rf"pub const {constant(name)}: felt252", head):
            head = head.replace("\n/// The stage classes", f"\npub const {constant(name)}: felt252 = 0x0;\n\n/// The stage classes", 1)
    return head + "pub fn pinned()" + tail


def typescript(text: str) -> str:
    body = "".join(f"  '{n}',\n" for n in BUNDLE)
    return re.sub(r"(export const SPLIT_BUNDLE_CLASSES = \[\n).*?(\] as const;)", lambda m: m[1] + body + m[2], text,
                  flags=re.S)


TARGETS = [(PACKAGE / "Scarb.toml", scarb), (PACKAGE / "tests" / "harness.cairo", harness),
           (PACKAGE / "src" / "hashes.cairo", hashes), (TS, typescript)]


def same(a: str, b: str) -> bool:
    """Equal but for `scarb fmt`'s layout (whitespace, trailing commas)."""
    return re.sub(r"\s+|,(?=\s*[\])])", "", a) == re.sub(r"\s+|,(?=\s*[\])])", "", b)


def main() -> int:
    stale = []
    for path, derive in TARGETS:
        old = path.read_text()
        new = derive(old)
        if not same(new, old):
            stale.append(path)
            if "--check" not in sys.argv:
                path.write_text(new)
    if "--measure" in sys.argv:
        return measure()
    for path in stale:
        print(f"{'stale' if '--check' in sys.argv else 'rewrote'}: {path.relative_to(ROOT)}", file=sys.stderr)
    return 1 if stale and "--check" in sys.argv else 0


def measure() -> int:
    """Runs every `test_called_<layout>_<class>` (class left undeclared): the classes whose run fails are
    the ones the shot calls; their union over the layouts must be exactly `classes.json`'s `rapier`."""
    run = subprocess.run([sys.executable, str(PACKAGE / "scripts" / "heavy.py"), "snforge", "test", "test_called_",
                          "--ignored"], capture_output=True, text=True)
    called = {"e": set(), "b": set()}
    seen = 0
    for m in re.finditer(r"\[(PASS|FAIL)\] slingfall_split_tests::called::test_called_([eb])_(\w+)", run.stdout):
        seen += 1
        if m[1] == "FAIL":
            called[m[2]].add("".join(w.capitalize() for w in m[3].split("_")) + "Class")
    print(f"layout (e) calls {sorted(called['e'])}\nfallback (b) calls {sorted(called['b'])}")
    want = set(RAPIER)
    ok = seen == 2 * 10 and called["e"] | called["b"] == want
    print("measured list == classes.json" if ok else f"MISMATCH ({seen} runs), classes.json: {sorted(want)}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
