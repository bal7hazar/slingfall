#!/usr/bin/env python3
"""Class size of the Slingfall contract and of its layered fixtures (crates/slingfall_sizes, lot
G7b) against the Starknet limits, and where the bytes go.

usage:
  tools/classsize/classsize.py [table] [--no-build]
      build `slingfall_contract` and `slingfall_sizes` (dev profile) and print the size table of
      every class in target/dev.
  tools/classsize/classsize.py attribution [--hook H] [--depth N] [--top K] [--strategy S]
                                           [--dump FILE | --from FILE]
      compile `simulate::run::<H>` alone as a library (temporary package) and print its Sierra
      statements (`.sierra.json`; a function owns its entry point to the next one) grouped by
      module path (N segments), its K heaviest functions, and the exclusive statements of the
      engine code the game never runs (`UNREACHABLE`, a cut of the call graph). H: `replay`
      (default, the real hook), `stub`, or a `slingfall_sizes::hooks` impl.
  tools/classsize/classsize.py strategies [--strategy S ...] [--cairo 'KEY = VALUE' ...]
      rebuild the `slingfall_sizes` fixtures in a temporary package (its own workspace: scarb
      only applies the `[cairo]` of the workspace root) once per `[cairo]` variant:
      `inlining-strategy = S` (`default`, `avoid` or a number) or a raw line, and print one table
      per variant.

Measured quantities, per class (`LIMITS` gives their source):
  sierra_felts  length of `sierra_program` in `*.contract_class.json`
  casm_felts    length of `bytecode` in `*.compiled_contract_class.json`, else the output of
                `starknet-sierra-compile` when it is on PATH, else n/a (`slingfall_contract` builds
                Sierra only: its CASM is `SizeE_Simulate`'s, the same code)
  sierra_bytes  compact JSON of the class as a declare transaction carries it (`sierra_program`,
                `contract_class_version`, `entry_points_by_type`, `abi` as a string; no debug info),
                the figure of scarb's "Contract class size" warning
  casm_bytes    compact JSON of the compiled class

Precedent: glam-cairo `scripts/bytecode_size.py`. Python 3 standard library only.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ["slingfall_contract", "slingfall_sizes"]

# Starknet limits (Starknet v0.14.x, read 2026-09-21 by glam-cairo R1 from the sequencer,
# starkware-libs/sequencer 1c4fa02: apollo_gateway `stateless_transaction_validator.rs`,
# apollo_sierra_compilation_config, apollo_class_manager_config) and scarb 2.19.4's warnings.
LIMITS = {
    "sierra_felts": 81920,
    "casm_felts": 81920,
    "sierra_bytes": 4089446,
    "casm_bytes": 4089446,
}

# Fixture order of the table (the layers (a)-(e) of the brief, then the split pair).
ORDER = [
    "SizeA_Registry", "SizeB_Decode", "SizeC_World", "SizeC2_GameNew", "SizeD_OneStep",
    "SizeD2_OneTick", "SizeE_Simulate", "Slingfall", "SplitCore", "SplitSim",
]

HOOKS = {
    "replay": "slingfall_contract::simulate::replay_hook::ReplaySimulateHook",
    "stub": "slingfall_contract::simulate::StubSimulateHook",
}

# ---------------------------------------------------------------------------------------------
# Measurement


def scarb(cwd, args, note=""):
    cmd = ["scarb"] + args
    print(f"$ {' '.join(cmd)}{note}", file=sys.stderr)
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        out = (p.stdout + p.stderr).splitlines()
        sys.exit("scarb failed:\n" + "\n".join(out[-60:]))


def compact(obj):
    return json.dumps(obj, separators=(",", ":"))


def casm_of(sierra_path):
    """CASM class of a Sierra class through `starknet-sierra-compile`, or None."""
    exe = shutil.which("starknet-sierra-compile")
    if not exe:
        return None
    p = subprocess.run([exe, "--allowed-libfuncs-list-name", "all", "--add-pythonic-hints",
                        str(sierra_path)], capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return json.loads(p.stdout)


def measure(target):
    """-> {contract_name: {metric: int | None}} from every starknet_artifacts.json in `target`."""
    res = {}
    for artifacts_file in sorted(target.glob("*.starknet_artifacts.json")):
        for c in json.loads(artifacts_file.read_text())["contracts"]:
            sierra_path = target / c["artifacts"]["sierra"]
            sierra = json.loads(sierra_path.read_text())
            declared = {
                "sierra_program": sierra["sierra_program"],
                "contract_class_version": sierra["contract_class_version"],
                "entry_points_by_type": sierra["entry_points_by_type"],
                "abi": compact(sierra["abi"]),
            }
            casm_file = c["artifacts"].get("casm")
            casm = json.loads((target / casm_file).read_text()) if casm_file else casm_of(sierra_path)
            res[c["contract_name"]] = {
                "sierra_felts": len(sierra["sierra_program"]),
                "casm_felts": len(casm["bytecode"]) if casm else None,
                "sierra_bytes": len(compact(declared)),
                "casm_bytes": len(compact(casm)) if casm else None,
            }
    return res


def fmt(value):
    return "n/a" if value is None else f"{value:,}"


def ratio(value, metric):
    return "n/a" if value is None else f"{value / LIMITS[metric]:.2f}"


def print_table(rows, title):
    print(f"\n### {title}\n")
    print("| class | Sierra felts | × limit | CASM felts | × limit | class bytes | × limit "
          "| CASM class bytes |")
    print("|---|--:|--:|--:|--:|--:|--:|--:|")
    names = [n for n in ORDER if n in rows] + sorted(n for n in rows if n not in ORDER)
    for name in names:
        r = rows[name]
        print(f"| `{name}` | {fmt(r['sierra_felts'])} | {ratio(r['sierra_felts'], 'sierra_felts')} "
              f"| {fmt(r['casm_felts'])} | {ratio(r['casm_felts'], 'casm_felts')} "
              f"| {fmt(r['sierra_bytes'])} | {ratio(r['sierra_bytes'], 'sierra_bytes')} "
              f"| {fmt(r['casm_bytes'])} |")
    print(f"\nLimits: {LIMITS['sierra_felts']:,} Sierra felts, {LIMITS['casm_felts']:,} CASM felts, "
          f"{LIMITS['sierra_bytes']:,} bytes per class object (declared and compiled).")


def table(build):
    if build:
        for package in PACKAGES:
            scarb(ROOT, ["build", "-p", package])
    print_table(measure(ROOT / "target" / "dev"), "Classes of target/dev (dev profile)")


# ---------------------------------------------------------------------------------------------
# Temporary packages (outside the workspace, path dependencies on the crates)


def workspace_pins():
    """`[workspace.dependencies]` registry pins of the root manifest (one source of `fixed`)."""
    pins, section = {}, None
    for line in (ROOT / "Scarb.toml").read_text().splitlines():
        header = re.match(r"^\[(.+)\]$", line.strip())
        if header:
            section = header.group(1)
            continue
        m = re.match(r'^(\w+)\s*=\s*"([^"]+)"', line.strip())
        if section == "workspace.dependencies" and m:
            pins[m.group(1)] = m.group(2)
    return pins


def manifest(name, extra):
    pins = workspace_pins()
    crates = ROOT / "crates"
    deps = [f'{d} = "{pins[d]}"' for d in ("starknet", "fixed", "rapier2d")]
    deps += [f'{c} = {{ path = "{(crates / c).as_posix()}" }}' for c in
             ("slingfall_contract", "slingfall_level", "slingfall_rules", "slingfall_game")]
    return (f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2024_07"\n\n'
            "[dependencies]\n" + "\n".join(deps) + "\n\n" + extra)


def strategy_toml(strategy):
    return strategy if strategy.isdigit() else f'"{strategy}"'


def strategies(variants):
    """`variants`: `[cairo]` lines, one build each."""
    for line in variants:
        with tempfile.TemporaryDirectory(prefix="classsize_") as tmp:
            work = Path(tmp)
            shutil.copytree(ROOT / "crates" / "slingfall_sizes" / "src", work / "src")
            (work / "Scarb.toml").write_text(manifest(
                "slingfall_sizes",
                "[[target.starknet-contract]]\nsierra = true\ncasm = true\n\n"
                f"[cairo]\n{line}\n"))
            scarb(work, ["build"], f"  ([cairo] {line})")
            rows = measure(work / "target" / "dev")
        print_table(rows, f"Fixtures, [cairo] {line}")


# ---------------------------------------------------------------------------------------------
# Attribution: Sierra statements per function of `run::<Hook>` compiled alone


# Engine code the game never runs (`--cut`): a regex on Sierra function names per group. The
# game inserts no impulse joint and no sensor collider, and its shapes are balls, cuboids, convex
# polygons and half-spaces (`slingfall_rules::world::shape`), so the capsule and segment
# generators of the closed `Shape` dispatch are never taken.
UNREACHABLE = {
    "joint solver": r"^rapier_dynamics2d::solver::joint::",
    "sensor intersection tests": r"^rapier_geometry2d::dispatch::intersection|"
                                 r"^rapier_dynamics2d::narrow_phase::intersections",
    "capsule / segment generators": r"^rapier_geometry2d::contact_generators::"
                                    r"(capsule_capsule|cuboid_capsule|cuboid_segment|polygon_segment)"
                                    r"|^rapier_geometry2d::contact_generators::polygon_polygon::"
                                    r"contact_manifold_polygon_(capsule|segment)",
}


def sierra_functions(program):
    """-> ([(id, name, statements, callees)], total) of a `*.sierra.json` program: each function
    owns the statements from its entry point to the next function's (they are laid out
    contiguously); `callees` are the user functions its `function_call`s name."""
    statements = program["statements"]
    calls = {}
    for decl in program["libfunc_declarations"]:
        if decl["long_id"]["generic_id"] == "function_call":
            calls[decl["id"]["id"]] = decl["long_id"]["generic_args"][0]["UserFunc"]["id"]
    funcs = sorted((f["entry_point"], f["id"]["id"], f["id"].get("debug_name") or "?")
                   for f in program["funcs"])
    out = []
    for i, (entry, fid, name) in enumerate(funcs):
        end = funcs[i + 1][0] if i + 1 < len(funcs) else len(statements)
        callees = set()
        for s in statements[entry:end]:
            inv = s.get("Invocation")
            if inv and inv["libfunc_id"]["id"] in calls:
                callees.add(calls[inv["libfunc_id"]["id"]])
        out.append((fid, name, end - entry, callees))
    return out, len(statements)


def exclusive(funcs, root, pattern):
    """Statements of the functions matching `pattern` plus those reachable from `root` only
    through them: what `run` would lose if the matching functions were never called."""
    by_id = {f[0]: f for f in funcs}
    cut = re.compile(pattern)
    seen, stack = set(), [root]
    while stack:
        fid = stack.pop()
        if fid in seen or cut.search(by_id[fid][1]):
            continue
        seen.add(fid)
        stack.extend(by_id[fid][3])
    kept = sum(by_id[f][2] for f in seen)
    return sum(f[2] for f in funcs) - kept, len(funcs) - len(seen)


def module_key(name, depth):
    # Generic arguments carry `::` too: cut them before splitting the path.
    base = re.sub(r"<.*", "", name)
    parts = [p for p in base.split("::") if p]
    return "::".join(parts[:depth])


def attribution(hook, depth, top, strategy, dump, source):
    if source:
        program = json.loads(Path(source).read_text())
    else:
        program = attribution_build(hook, strategy, dump)
    funcs, total = sierra_functions(program.get("program", program))
    groups = defaultdict(lambda: [0, 0])
    for _, name, n, _ in funcs:
        g = groups[module_key(name, depth)]
        g[0] += n
        g[1] += 1
    print(f"\n### Sierra statements of `run::<{hook}>` by module (depth {depth}); "
          f"{total:,} statements, {len(funcs):,} functions\n")
    print("| module | statements | share | functions |")
    print("|---|--:|--:|--:|")
    for key, (n, count) in sorted(groups.items(), key=lambda kv: -kv[1][0]):
        print(f"| `{key}` | {n:,} | {100 * n / total:.1f} % | {count} |")
    print(f"\n### {top} heaviest functions\n")
    print("| function | statements | share |")
    print("|---|--:|--:|")
    for _, name, n, _ in sorted(funcs, key=lambda f: -f[2])[:top]:
        print(f"| `{name}` | {n:,} | {100 * n / total:.1f} % |")
    root = next(f[0] for f in funcs if f[1] == "slingfall_sizes_attr::simulate")
    print("\n### Code the game never runs (exclusive statements: the matching functions and "
          "what only they call)\n")
    print("| group | statements | share | functions |")
    print("|---|--:|--:|--:|")
    for label, pattern in list(UNREACHABLE.items()) + [("all of the above",
                                                         "|".join(UNREACHABLE.values()))]:
        n, count = exclusive(funcs, root, pattern)
        print(f"| {label} | {n:,} | {100 * n / total:.1f} % | {count} |")


def attribution_build(hook, strategy, dump):
    """Compiles `run::<hook>` alone as a library; -> its `*.sierra.json` program."""
    hook_path = HOOKS.get(hook, f"slingfall_sizes_attr::hooks::{hook}")
    with tempfile.TemporaryDirectory(prefix="classsize_attr_") as tmp:
        work = Path(tmp)
        (work / "src").mkdir()
        lib = ["pub mod hooks;\n"] if hook not in HOOKS else []
        if hook not in HOOKS:
            shutil.copy(ROOT / "crates" / "slingfall_sizes" / "src" / "hooks.cairo",
                        work / "src" / "hooks.cairo")
        lib.append(
            "use slingfall_level::outputs::Outputs;\n\n"
            "pub fn simulate(level: Span<felt252>, inputs: Span<felt252>) -> Outputs {\n"
            f"    slingfall_contract::simulate::run::<{hook_path}>(level, inputs)\n}}\n")
        (work / "src" / "lib.cairo").write_text("".join(lib))
        extra = "[lib]\nsierra = true\n"
        if strategy:
            extra += f"\n[cairo]\ninlining-strategy = {strategy_toml(strategy)}\n"
        (work / "Scarb.toml").write_text(manifest("slingfall_sizes_attr", extra))
        scarb(work, ["build"], f"  (run::<{hook_path}>, Sierra JSON)")
        text = (work / "target" / "dev" / "slingfall_sizes_attr.sierra.json").read_text()
    if dump:
        Path(dump).write_text(text)
    return json.loads(text)


# ---------------------------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", nargs="?", default="table", choices=["table", "attribution", "strategies"])
    ap.add_argument("--no-build", action="store_true", help="table: measure target/dev as it is")
    ap.add_argument("--hook", default="replay", help="attribution: replay, stub or a hooks impl")
    ap.add_argument("--depth", type=int, default=2, help="attribution: module path segments")
    ap.add_argument("--top", type=int, default=25, help="attribution: heaviest functions shown")
    ap.add_argument("--dump", help="attribution: also write the Sierra JSON to this file")
    ap.add_argument("--from", dest="source", help="attribution: read this Sierra JSON, no build")
    ap.add_argument("--strategy", action="append",
                    help="inlining-strategy: default, avoid or a number (repeatable)")
    ap.add_argument("--cairo", action="append", default=[],
                    help="strategies: a raw [cairo] line, one variant each (repeatable)")
    a = ap.parse_args()
    if a.cmd == "table":
        table(not a.no_build)
    elif a.cmd == "strategies":
        lines = [f"inlining-strategy = {strategy_toml(s)}" for s in a.strategy or []] + a.cairo
        strategies(lines or ['inlining-strategy = "default"', 'inlining-strategy = "avoid"'])
    else:
        attribution(a.hook, a.depth, a.top, (a.strategy or [None])[0], a.dump, a.source)


if __name__ == "__main__":
    main()
