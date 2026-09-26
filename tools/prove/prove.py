#!/usr/bin/env python3
"""prove: local Stwo proofs of a slingfall level (lot P1, `docs/proving.md`). Python 3 standard
library, plus the binaries of `tools/prove/setup.sh` and the replay executables
(`scarb --manifest-path crates/slingfall_replay/Scarb.toml build`).

    prove.py --case one_block-miss --out DIR                     # a golden case, whole level
    prove.py --level one_block --shot=-150,-150 --out DIR        # any shots (PX,PY[,DELAY])
    prove.py --case pile10-reference --chunks 2 --out DIR        # chunked: init + step_chunk chain

Whole: one `run_and_prove --program_type executable` of `main(level, inputs)`; its public output
is the 10 felts of `docs/DESIGN.md` D4.

Chunked (`--chunks N` or `--k K`): `init(level)`, then `step_chunk(state, inputs, shot, K, 0)`
until each shot is over, then `outputs(state, inputs)`, one proof each. Every proof's public
output is the state it returns (the 10 felts for `outputs`); the next proof is run on it.
`--chunks N` sets K = ceil(ticks / N) with the level's `ticks_run` (from the golden with
`--case`, else from one `scarb execute` of `main`): N `step_chunk` proofs on a one-shot level,
more when a chunk would cross a shot's end.

Every proof: `--params_json params.canonical_small.json --proof-format binary --verify`, run
through `measure.py` (wall, peak RSS), one at a time. Then `verify.py`'s checks on each proof.
Writes to `--out`: the proofs (`*.proof.bin`), `outputs.json` (the 10 felts, the level and inputs
felts, the program hash of the executable that produced them), `report.json` (per proof: steps,
wall, peak RSS, proof bytes and sha256, verify; the chain), the logs. With `--case`, the outputs
must equal `fixtures/golden/<case>.json`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "tools" / "tracec"))
sys.path.insert(0, str(ROOT / "tools" / "levelc"))
import measure  # noqa: E402
import proofdata  # noqa: E402
import tracec  # noqa: E402
import verify  # noqa: E402

P = tracec.P
MANIFEST = ROOT / "crates" / "slingfall_replay" / "Scarb.toml"
EXECUTABLES = ROOT / "crates" / "slingfall_replay" / "target" / "dev"
GOLDEN = ROOT / "fixtures" / "golden"
LEVELS = ROOT / "fixtures" / "levels"
PARAMS = HERE / "params.canonical_small.json"
STEPS_RE = re.compile(r"Num steps: (\d+)")
N_OUTPUTS = 10


class ProveError(Exception):
    """A proof failed, or its output is not what it should be."""


def hexes(felts: list[int]) -> list[str]:
    return [hex(v % P) for v in felts]


def level_felts(level: str) -> list[int]:
    path = Path(level)
    if not path.exists():
        path = LEVELS / f"{level}.felts.json"
    return tracec.load_level_felts(path)


def scarb_ticks(level: list[int], inputs: list[int]) -> int:
    """`ticks_run` of `main` (one VM run, no proof)."""
    args = HERE / "out" / "ticks-args.json"
    args.parent.mkdir(parents=True, exist_ok=True)
    args.write_text(json.dumps(hexes([len(level), *level, len(inputs), *inputs])))
    out = subprocess.run(
        ["scarb", "--manifest-path", str(MANIFEST), "execute", "--no-build", "--output", "none",
         "--executable-name", "main", "--arguments-file", str(args), "--print-program-output"],
        capture_output=True, text=True,
    )
    if out.returncode != 0 or "Program output:" not in out.stdout:
        raise ProveError(f"scarb execute main failed\n{out.stdout[-2000:]}\n{out.stderr[-2000:]}")
    values = [int(v) % P for v in out.stdout.split("Program output:", 1)[1].split("Resources:")[0].split()]
    return values[1 + 8]


class Prover:
    def __init__(self, out: Path, bin_dir: Path, executables: Path, params: Path):
        self.out, self.bin, self.executables, self.params = out, bin_dir, executables, params
        self.proofs: list[dict] = []
        self.hashes: dict[str, int] = {}

    def program_hash(self, name: str) -> int:
        if name not in self.hashes:
            self.hashes[name] = proofdata.program_hash(
                proofdata.executable_bytecode(self.executables / f"{name}.executable.json"))
        return self.hashes[name]

    def prove(self, label: str, name: str, args: list[int], input_state: list[int] | None = None) -> list[int]:
        """One `run_and_prove` of executable `name` on `args`; returns its public output felts
        (the returned array), checked against the proof file and the verify binary."""
        args_path = self.out / f"{label}.args.json"
        args_path.write_text(json.dumps(hexes(args)))
        proof = self.out / f"{label}.proof.bin"
        log = self.out / f"{label}.log"
        cmd = [str(self.bin / "run_and_prove"),
               "--program", str(self.executables / f"{name}.executable.json"),
               "--program_type", "executable", "--program_arguments_file", str(args_path),
               "--params_json", str(self.params), "--proof_path", str(proof),
               "--proof-format", "binary", "--verify"]
        print(f"prove {label} ({name}) ...", flush=True)
        m = measure.measure(cmd, log)
        text = log.read_text(errors="replace")
        steps = [int(s) for s in STEPS_RE.findall(text)]
        entry = {
            "label": label, "program": name, "proof": proof.name,
            "steps": steps[-1] if steps else None, **m,
            "proof_bytes": proof.stat().st_size if proof.exists() else None,
        }
        print("  " + measure.line(label, m) + f" steps={entry['steps']}", flush=True)
        self.proofs.append(entry)
        entry["verify"] = "not proven"
        if m["exit"] != 0 or not proof.exists():
            raise ProveError(f"{label}: run_and_prove exit {m['exit']} (killed: {m['exit'] < 0}), "
                             f"log {log}\n{text[-1500:]}")
        entry["proof_sha256"] = hashlib.sha256(proof.read_bytes()).hexdigest()
        claims = verify.public_claims(proof)
        if claims["program_hash"] != self.program_hash(name):
            program = proofdata.read_public_memory(proof)["program"]
            code = proofdata.executable_bytecode(self.executables / f"{name}.executable.json")
            first = next((i for i, (a, b) in enumerate(zip(program, code)) if a != b), None)
            raise ProveError(f"{label}: the proof's program hash {claims['program_hash']:#x} is not "
                             f"{name}'s bytecode hash {self.program_hash(name):#x} (program section "
                             f"{len(program)} cells, bytecode {len(code)}, first difference at {first})")
        output = claims["returned"]
        entry.update(verify="failed", public_output=hexes(output),
                     input_state=hexes(input_state) if input_state else None)
        t = time.time()
        verify.check_proof(proof, output, self.program_hash(name), self.bin)
        entry.update(verify="ok", verify_wall_s=round(time.time() - t, 1))
        return output


def run(args) -> int:
    started = time.time()
    golden = None
    if args.case:
        case = next((c for c in json.loads((GOLDEN / "cases.json").read_text())["cases"]
                     if c["name"] == args.case), None)
        if case is None:
            sys.exit(f"no case {args.case} in fixtures/golden/cases.json")
        level_name, shots = case["level"], [tuple(s) for s in case["shots"]]
        golden = json.loads((GOLDEN / f"{args.case}.json").read_text())
    else:
        if not args.level or not args.shot:
            sys.exit("--case, or --level and --shot")
        level_name, shots = args.level, args.shot
    level = level_felts(level_name)
    inputs = tracec.inputs_felts(int(args.player, 0), shots)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    for stale in out.glob("*.proof.bin"):
        stale.unlink()
    if args.build:
        subprocess.run(["scarb", "--manifest-path", str(MANIFEST), "build"], check=True)

    k = args.k
    if args.chunks and not k:
        ticks = int(golden["outputs"][8], 16) if golden else scarb_ticks(level, inputs)
        k = math.ceil(ticks / args.chunks)
    prover = Prover(out, args.bin, args.executables, args.params)
    mode = f"chunked K={k}" if k else "whole"
    error = None
    outputs: list[int] = []
    try:
        if not k:
            outputs = prover.prove("main", "main", [len(level), *level, len(inputs), *inputs])
            program = "main"
        else:
            state = prover.prove("init", "init", [len(level), *level])
            i = 0
            for shot in range(len(shots)):
                while state[1] == shot and state[2] == 0:
                    prev = state
                    state = prover.prove(f"chunk{i:02d}", "step_chunk",
                                         [len(state), *state, len(inputs), *inputs, shot, k, 0], prev)
                    i += 1
            outputs = prover.prove("outputs", "outputs", [len(state), *state, len(inputs), *inputs], state)
            program = "outputs"
        if len(outputs) != N_OUTPUTS:
            raise ProveError(f"{len(outputs)} output felts, expected {N_OUTPUTS}")
        if golden and hexes(outputs) != golden["outputs"]:
            raise ProveError(f"outputs differ from fixtures/golden/{args.case}.json\n"
                             f"  proof  {hexes(outputs)}\n  golden {golden['outputs']}")
    except (ProveError, verify.VerifyError, proofdata.ProofDataError) as e:
        error = str(e)

    doc = {
        "case": args.case, "level": level_name, "shots": [list(s) for s in shots], "mode": mode,
        "program": program if not error else None,
        "program_hash": hex(prover.program_hash(program)) if not error else None,
        "executables": str(args.executables.resolve().relative_to(ROOT))
        if args.executables.resolve().is_relative_to(ROOT) else None,
        "level_felts": hexes(level), "inputs_felts": hexes(inputs), "outputs": hexes(outputs),
    }
    if not error:
        (out / "outputs.json").write_text(json.dumps(doc, indent=2) + "\n")
    report = {
        "case": args.case, "level": level_name, "shots": doc["shots"], "mode": mode, "k": k,
        "params": args.params.name, "memory_max": measure.memory_max(),
        "ok": error is None, "error": error, "wall_total_s": round(time.time() - started, 1),
        "steps_total": sum(p["steps"] or 0 for p in prover.proofs),
        "maxrss_peak_bytes": max((p["maxrss_bytes"] for p in prover.proofs), default=0),
        "proof_bytes_total": sum(p["proof_bytes"] or 0 for p in prover.proofs),
        "program_hashes": {n: hex(h) for n, h in prover.hashes.items()},
        "proofs": prover.proofs,
    }
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    print(f"ok  {args.case or level_name} {mode}: {len(prover.proofs)} proof(s), "
          f"{report['steps_total']:,} steps, peak RSS {measure.gib(report['maxrss_peak_bytes'])} GiB, "
          f"outputs {'= golden' if golden else 'written'} ({report['wall_total_s']:.0f} s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--case", help="a case of fixtures/golden/cases.json (its level and shots)")
    ap.add_argument("--level", help="a fixture name (fixtures/levels/<name>.felts.json) or a path")
    ap.add_argument("--shot", action="append", type=tracec.parse_shot, help="PX,PY[,DELAY], repeated")
    ap.add_argument("--player", default=str(tracec.DEFAULT_PLAYER))
    ap.add_argument("--chunks", type=int, help="prove in chunks of K = ceil(ticks / N) ticks")
    ap.add_argument("--k", type=int, help="prove in chunks of K ticks")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--bin", type=Path, default=verify.DEFAULT_BIN)
    ap.add_argument("--executables", type=Path, default=EXECUTABLES)
    ap.add_argument("--params", type=Path, default=PARAMS)
    ap.add_argument("--build", action="store_true", help="scarb build the replay executables first")
    return run(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())
