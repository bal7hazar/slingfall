#!/usr/bin/env python3
"""Throwaway lever builds of spike S36a (sizes only, as rapier-cairo's `scripts/cs3_levers.py`):
each lever rewrites the sources of `crates/slingfall_split` (textual replacements), builds, prints
the CASM and Sierra felts of the classes it names, then restores the sources. The results are
sizes of code that is not meant to run (a lever may stub a piece out).

    python3 crates/slingfall_split/scripts/levers.py [LEVER ...]

Python 3 standard library only.
"""
import json
import subprocess
import sys
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]
SRC = PACKAGE / "src"
TARGET = PACKAGE / "target" / "dev"

LEAN = "lean.cairo"
VIEWS = "        write_views(ref world, watch.span(), ref calldata);\n"
EDIT = "        if !edit.is_empty() {\n            let mut calldata"
EVENTS = """        calldata.append(events.len().into());
        for event in events.span() {
            event.collider1.serialize(ref calldata);
            event.collider2.serialize(ref calldata);
            event.total_force_magnitude.serialize(ref calldata);
        }
"""

EDIT_BLOCK = """        if !edit.is_empty() {
            let mut calldata = array![];
            save(world, ref calldata);
            calldata.append_span(edit.span());
            let mut ret = library_call_syscall(G::edit(), selector!("edit"), calldata.span())
                .unwrap_syscall();
            world = load(ref ret);
            inserted = Serde::deserialize(ref ret).expect(errors::DECODE);
        }
"""
RULES_CALL = """        let mut ret = library_call_syscall(G::lean_rules(), selector, calldata.span())
            .unwrap_syscall();
        let (
            next, edit, next_watch, status,
        ): (Array<felt252>, Array<felt252>, Array<Handle>, felt252) =
            Serde::deserialize(
            ref ret,
        )
            .expect(errors::DECODE);
"""
RULES_STUB = """        let (next, edit, next_watch, status): (
            Array<felt252>, Array<felt252>, Array<Handle>, felt252,
        ) =
            (calldata, array![], array![], 0);
"""

# lever: (classes to report, [(file, old, new)]).
LEVERS = {
    "e": (["LayoutE"], []),
    "e-no-views": (["LayoutE"], [(LEAN, VIEWS, "        calldata.append(0);\n")]),
    "e-no-events": (["LayoutE"], [(LEAN, EVENTS, "        calldata.append(0);\n")]),
    "e-no-edit-block": (["LayoutE"], [(LEAN, EDIT_BLOCK, "")]),
    "e-no-rules-call": (["LayoutE"], [(LEAN, RULES_CALL, RULES_STUB)]),
    "e-loop-only": (["LayoutE"], [
        (LEAN, VIEWS, "        calldata.append(0);\n"),
        (LEAN, EDIT_BLOCK, ""),
        (LEAN, EVENTS, "        calldata.append(0);\n"),
        (LEAN, RULES_CALL, RULES_STUB),
    ]),
    "e-no-views-edit-events": (["LayoutE"], [
        (LEAN, VIEWS, "        calldata.append(0);\n"),
        (LEAN, EDIT, "        if edit.len() == 0xffffffff {\n            let mut calldata"),
        (LEAN, EVENTS, "        calldata.append(0);\n"),
    ]),
}


def sizes(names):
    out = {}
    for c in json.loads((TARGET / "slingfall_split.starknet_artifacts.json").read_text())["contracts"]:
        if c["contract_name"] in names:
            sierra = json.loads((TARGET / c["artifacts"]["sierra"]).read_text())
            casm = json.loads((TARGET / c["artifacts"]["casm"]).read_text())
            out[c["contract_name"]] = (len(sierra["sierra_program"]), len(casm["bytecode"]))
    return out


def run(name):
    classes, edits = LEVERS[name]
    saved = {}
    try:
        for file, old, new in edits:
            path = SRC / file
            text = saved.setdefault(path, path.read_text()) if path not in saved else path.read_text()
            if old not in text:
                sys.exit(f"{name}: pattern not found in {file}")
            path.write_text(text.replace(old, new, 1))
        build = subprocess.run(["scarb", "build"], cwd=PACKAGE, capture_output=True, text=True)
        if build.returncode != 0:
            sys.exit(f"{name}: build failed\n{build.stdout[-3000:]}")
        for cls, (sierra, casm) in sizes(classes).items():
            print(f"| {name} | `{cls}` | {sierra:,} | {casm:,} | {73728 - casm:,} |")
    finally:
        for path, text in saved.items():
            path.write_text(text)


def main():
    names = sys.argv[1:] or list(LEVERS)
    print("| lever | class | Sierra felts | CASM felts | CASM margin |")
    print("|---|---|--:|--:|--:|")
    for name in names:
        run(name)


if __name__ == "__main__":
    main()
