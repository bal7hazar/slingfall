#!/usr/bin/env python3
"""verify: re-verify a slingfall proof and check what it commits to (lot P1, `docs/proving.md`).
Python 3 standard library, plus the `verify` binary of `tools/prove/setup.sh`.

    verify.py <proof> <outputs.json> [--bin DIR]     # one proof against its outputs.json
    verify.py --run <dir> [--bin DIR]                # every proof of a `prove.py` output directory

One proof (`outputs.json` as `prove.py` writes it):

1. the STARK verifies (`verify --proof_format binary|json`, patched to also print the program hash
   and the public output it verified);
2. the proof's public output (read from the proof file by `proofdata.py`, and equal to what the
   binary printed) is `[10, outputs...]`: the 10 felts of `docs/DESIGN.md` D4;
3. the proof's program hash is `outputs.json`'s `program_hash`, which is the hash of the
   executable's bytecode (recomputed when the executable is at hand);
4. `level_hash` and `inputs_hash` (outputs 1 and 4) are the Poseidon hashes of the level and
   inputs felts recorded in `outputs.json`.

`--run <dir>` checks every proof listed in the directory's `report.json` (whole: `main`; chunked:
`init`, the `step_chunk` chain, `outputs`) and the chain's links as recorded by the prover (each
chunk's input state is the previous proof's public output). Those links are not in the proofs:
the arguments of a standalone executable are private (see the chunk trust model in
`docs/proving.md`).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "tools" / "levelc"))
import poseidon  # noqa: E402
import proofdata  # noqa: E402

DEFAULT_BIN = HERE / "vendor" / "stwo-cairo" / "stwo_cairo_prover" / "target" / "release"
VERIFICATION_OUTPUT = re.compile(r"^VERIFICATION_OUTPUT (\{.*\})$", re.M)


class VerifyError(Exception):
    """A proof or its claims do not check out."""


def felt(x) -> int:
    return int(x, 0) if isinstance(x, str) else int(x)


def proof_format(path: Path) -> str:
    return "binary" if Path(path).read_bytes()[:3] == b"BZh" else "json"


def stark_verify(proof: Path, bin_dir: Path) -> dict:
    """Runs the `verify` binary. Returns `{ok, program_hash, output, log}`; `program_hash` and
    `output` are what the binary printed (None when it failed before)."""
    out = subprocess.run(
        [str(bin_dir / "verify"), "--proof_path", str(proof), "--proof_format", proof_format(proof)],
        capture_output=True, text=True,
    )
    m = VERIFICATION_OUTPUT.search(out.stdout)
    printed = json.loads(m.group(1)) if m else {}
    return {
        "ok": out.returncode == 0,
        "program_hash": felt(printed["program_hash"]) if printed else None,
        "output": [felt(v) for v in printed.get("output", [])] if printed else None,
        "log": (out.stdout + out.stderr)[-3000:],
    }


def public_claims(proof: Path) -> dict:
    """The program hash and the returned felts of a proof file, decoded in Python."""
    mem = proofdata.read_public_memory(proof)
    return {
        "program_hash": proofdata.program_hash(mem["program"]),
        "output": mem["output"],
        "returned": proofdata.returned_felts(mem["output"]),
    }


def check_proof(proof: Path, expected: list[int], program_hash: int | None, bin_dir: Path,
                executable: Path | None = None) -> dict:
    """Verifies one proof; raises `VerifyError` unless it verifies, returns `expected` and has
    `program_hash` (and the executable's hash, when given). Returns the decoded claims."""
    claims = public_claims(proof)
    problems = []
    if claims["returned"] != expected:
        problems.append("public output differs:\n" + "\n".join(
            f"  [{i}] proof {g:#x}, expected {e:#x}"
            for i, (g, e) in enumerate(zip(claims["returned"], expected)) if g != e
        ) + ("" if len(claims["returned"]) == len(expected)
             else f"\n  length {len(claims['returned'])} vs {len(expected)}"))
    if program_hash is not None and claims["program_hash"] != program_hash:
        problems.append(f"program hash {claims['program_hash']:#x}, expected {program_hash:#x}")
    if executable is not None:
        want = proofdata.program_hash(proofdata.executable_bytecode(executable))
        if claims["program_hash"] != want:
            problems.append(f"program hash {claims['program_hash']:#x} is not {executable.name}'s {want:#x}")
    v = stark_verify(proof, bin_dir)
    if not v["ok"]:
        problems.append("the STARK does not verify\n" + v["log"])
    elif (v["program_hash"], v["output"]) != (claims["program_hash"], claims["output"]):
        problems.append("the verifier's program hash / output differ from the proof file's decoding "
                        f"(verifier {v['program_hash']:#x}, decoded {claims['program_hash']:#x})")
    if problems:
        raise VerifyError(f"{proof}: " + "; ".join(problems))
    return claims


def check_identity(doc: dict) -> None:
    """`level_hash` and `inputs_hash` are the hashes of the recorded level and inputs felts."""
    out = [felt(v) for v in doc["outputs"]]
    level, inputs = [felt(v) for v in doc["level_felts"]], [felt(v) for v in doc["inputs_felts"]]
    if out[1] != poseidon.hash_span(level):
        raise VerifyError("level_hash is not the Poseidon hash of the recorded level felts")
    if out[4] != poseidon.hash_span(inputs):
        raise VerifyError("inputs_hash is not the Poseidon hash of the recorded inputs felts")


def executable_path(doc: dict, name: str) -> Path | None:
    d = doc.get("executables")
    p = (ROOT / d / f"{name}.executable.json") if d else None
    return p if p and p.exists() else None


def cmd_one(proof: Path, outputs: Path, bin_dir: Path) -> None:
    doc = json.loads(outputs.read_text())
    check_identity(doc)
    name = doc["program"]
    check_proof(proof, [felt(v) for v in doc["outputs"]], felt(doc["program_hash"]), bin_dir,
                executable_path(doc, name))
    print(f"ok  {proof}: verifies, public output = {outputs.name}, program {name} "
          f"{felt(doc['program_hash']):#x}")


def cmd_run(run: Path, bin_dir: Path) -> None:
    report = json.loads((run / "report.json").read_text())
    doc = json.loads((run / "outputs.json").read_text())
    check_identity(doc)
    hashes = {k: felt(v) for k, v in report["program_hashes"].items()}
    previous = None
    for p in report["proofs"]:
        expected = [felt(v) for v in p["public_output"]]
        if p.get("input_state") is not None and previous is not None:
            if [felt(v) for v in p["input_state"]] != previous:
                raise VerifyError(f"{p['proof']}: recorded input state is not the previous proof's output")
        check_proof(run / p["proof"], expected, hashes[p["program"]], bin_dir,
                    executable_path(doc, p["program"]))
        print(f"ok  {p['proof']}: {p['program']} verifies, {len(expected)} output felts")
        previous = expected
    last = [felt(v) for v in report["proofs"][-1]["public_output"]]
    if last != [felt(v) for v in doc["outputs"]]:
        raise VerifyError("the last proof's output is not outputs.json's outputs")
    print(f"ok  {run}: {len(report['proofs'])} proofs, outputs = outputs.json")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("proof", nargs="?", type=Path)
    ap.add_argument("outputs", nargs="?", type=Path)
    ap.add_argument("--run", type=Path, help="a prove.py output directory")
    ap.add_argument("--bin", type=Path, default=DEFAULT_BIN, help="directory of the verify binary")
    args = ap.parse_args()
    try:
        if args.run:
            cmd_run(args.run, args.bin)
        elif args.proof and args.outputs:
            cmd_one(args.proof, args.outputs, args.bin)
        else:
            ap.error("verify.py <proof> <outputs.json> | --run <dir>")
    except (VerifyError, proofdata.ProofDataError) as e:
        print(f"FAIL {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
