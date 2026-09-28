#!/usr/bin/env python3
"""Where a world class's code goes beyond another's: the Sierra functions reachable from class
A's entry points and not from class B's, with their statement counts, from the library's Sierra
program (`target/dev/slingfall_split.sierra.json` of the workspace root, `[lib] sierra = true`, built with
`scarb build -p slingfall_split --features probes` when a class of `crate::probes` is named). The functions are
lowered as in the contract classes (same compiler, same settings); a Sierra statement is roughly
2-3 CASM felts.

    python3 crates/slingfall_split/scripts/attribution.py WorldClass SlimCaller [--top N]
    python3 crates/slingfall_split/scripts/attribution.py SlimCaller --modules [--depth N]
        # one class's statements by module path (N segments)

Python 3 standard library only; the Sierra reading is `tools/classsize/classsize.py`'s.
"""
import argparse
import json
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
ROOT = PACKAGE.parents[1]
sys.path.insert(0, str(ROOT / "tools" / "classsize"))
import classsize  # noqa: E402


def reachable(funcs, roots):
    by_id = {f[0]: f for f in funcs}
    seen, stack = set(), list(roots)
    while stack:
        fid = stack.pop()
        if fid in seen:
            continue
        seen.add(fid)
        stack.extend(by_id[fid][3])
    return seen


def entries(funcs, cls):
    marker = f"::{cls}::__wrapper__"
    return [f[0] for f in funcs if marker in f[1]]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("a")
    ap.add_argument("b", nargs="?")
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--modules", action="store_true")
    ap.add_argument("--depth", type=int, default=3)
    args = ap.parse_args()
    program = json.loads((ROOT / "target" / "dev" / "slingfall_split.sierra.json").read_text())
    funcs, _ = classsize.sierra_functions(program.get("program", program))
    by_id = {f[0]: f for f in funcs}
    if args.modules:
        a = reachable(funcs, entries(funcs, args.a))
        groups = {}
        for f in a:
            key = classsize.module_key(by_id[f][1], args.depth)
            groups[key] = groups.get(key, 0) + by_id[f][2]
        total = sum(groups.values())
        print(f"`{args.a}`: {total:,} statements by module (depth {args.depth})\n")
        print("| module | statements | share |")
        print("|---|--:|--:|")
        for key, n in sorted(groups.items(), key=lambda kv: -kv[1])[: args.top]:
            print(f"| `{key}` | {n:,} | {100 * n / total:.1f} % |")
        return
    a = reachable(funcs, entries(funcs, args.a))
    b = reachable(funcs, entries(funcs, args.b))
    if not a or not b:
        sys.exit("class not found in the library's Sierra program")
    only = sorted((by_id[f] for f in a - b), key=lambda f: -f[2])
    total_a = sum(by_id[f][2] for f in a)
    total_b = sum(by_id[f][2] for f in b)
    print(f"`{args.a}`: {total_a:,} statements; `{args.b}`: {total_b:,}; "
          f"only in `{args.a}`: {sum(f[2] for f in only):,} in {len(only)} functions\n")
    print("| function | statements |")
    print("|---|--:|")
    for f in only[: args.top]:
        print(f"| `{f[1][:160]}` | {f[2]:,} |")


if __name__ == "__main__":
    main()
