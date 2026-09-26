#!/usr/bin/env python3
"""verify: re-verify a slingfall proof and check what it commits to (lot P1, `docs/proving.md`).
Python 3 standard library, plus the `verify` binary of `tools/prove/setup.sh`.

    verify.py <proof> <outputs.json> [--bin DIR]     # one proof against its outputs.json
    verify.py --run <dir> [--bin DIR] [--executables DIR]   # every proof of a `prove.py` directory

One proof (`outputs.json` as `prove.py` writes it):

1. the STARK verifies (`verify --proof_format binary|json`, patched to also print the program hash
   and the public output it verified);
2. the proof's public output (read from the proof file by `proofdata.py`, and equal to what the
   binary printed) is `[n, header..., outputs...]`: the executable's binding header (none for
   `main`, `[state_in_hash, inputs_hash]` for `outputs`), then the 10 felts of `docs/DESIGN.md` D4;
3. the proof's program hash is `outputs.json`'s `program_hash`, which is the hash of the
   executable's bytecode (recomputed when the executable is at hand);
4. `level_hash` and `inputs_hash` (outputs 1 and 4) are the Poseidon hashes of the level and
   inputs felts recorded in `outputs.json`.

`--run <dir>` checks every proof of a `prove.py` directory (whole: `main.proof.bin`; chunked:
`init`, `chunkNN`, `outputs`), each against the program hash of the executable it must be
(recomputed from `--executables`, never read from `report.json`), then the chain's links **from the
proofs' public outputs alone** (lot P1b, `docs/proving.md` "Chunk binding", `check_chain`): each
chunk's `STATE_IN_HASH` is the Poseidon hash of the previous proof's state, every `INPUTS_HASH` is
the outputs' `inputs_hash`, each chunk's shot is the shot in progress, the last state is finished,
`init`'s `LEVEL_HASH` is the outputs' `level_hash`. `report.json` is not read.
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
EXECUTABLES = ROOT / "crates" / "slingfall_replay" / "target" / "dev"
CHUNK_PROOF = re.compile(r"^chunk(\d+)\.proof\.bin$")
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


def check_proof(proof: Path, expected: list[int] | None, program_hash: int | None, bin_dir: Path,
                executable: Path | None = None) -> dict:
    """Verifies one proof; raises `VerifyError` unless it verifies, returns `expected` (when given)
    and has `program_hash` (and the executable's hash, when given). Returns the decoded claims."""
    claims = public_claims(proof)
    problems = []
    if expected is not None and claims["returned"] != expected:
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
    claims = check_proof(proof, None, felt(doc["program_hash"]), bin_dir, executable_path(doc, name))
    got = proofdata.split_public_output(name, claims["returned"])["outputs"]
    if got != [felt(v) for v in doc["outputs"]]:
        raise VerifyError(f"{proof}: the public outputs after {name}'s header differ from {outputs.name}")
    print(f"ok  {proof}: verifies, public output = {outputs.name}, program {name} "
          f"{felt(doc['program_hash']):#x}")


class ChainError(VerifyError):
    """The proofs' public outputs do not form one run of the level (`check_chain`)."""


def check_chain(links: list[tuple[str, list[int]]], inputs: list[int]) -> list[int]:
    """The links of a chunked run from public data only (`docs/proving.md` "Chunk binding").
    `links`: `(executable, public output)` per proof in order, the executable identified by its
    program hash; `inputs`: the `Inputs` felts (their hash must be the outputs' `inputs_hash`).
    Returns the 10 outputs; raises `ChainError` on the first broken link."""
    names = [n for n, _ in links]
    if len(links) < 2 or names[0] != "init" or names[-1] != "outputs" or \
            any(n != "step_chunk" for n in names[1:-1]):
        raise ChainError(f"a chain is init, step_chunk..., outputs; got {names}")
    parts = [proofdata.split_public_output(n, out) for n, out in links]
    init, chunks, last = parts[0], parts[1:-1], parts[-1]
    outputs = last["outputs"]
    if len(outputs) != 10:
        raise ChainError(f"outputs: {len(outputs)} output felts, expected 10")
    inputs_hash = poseidon.hash_span(inputs)
    if outputs[4] != inputs_hash:
        raise ChainError("the outputs' inputs_hash is not the hash of the inputs")
    if init["level_hash"] != outputs[1]:
        raise ChainError("init's LEVEL_HASH is not the outputs' level_hash")
    n_shots = inputs[1]
    state = init["state"]
    for i, c in enumerate([*chunks, last]):
        label = f"chunk{i:02d}" if i < len(chunks) else "outputs"
        if c["state_in_hash"] != poseidon.hash_span(state):
            raise ChainError(f"{label}: STATE_IN_HASH is not the hash of the previous proof's state "
                             f"(proven on another state)")
        if c["inputs_hash"] != inputs_hash:
            raise ChainError(f"{label}: INPUTS_HASH is not the outputs' inputs_hash")
        if i == len(chunks):
            break
        if c["shot"] != state[proofdata.STATE_SHOTS_USED] or state[proofdata.STATE_OVER] != 0 \
                or c["shot"] >= n_shots:
            raise ChainError(f"{label}: shot {c['shot']} is not the shot in progress "
                             f"(shots_used {state[proofdata.STATE_SHOTS_USED]}, over "
                             f"{state[proofdata.STATE_OVER]}, {n_shots} shots)")
        state = c["state"]
    if state[proofdata.STATE_OVER] == 0 and state[proofdata.STATE_SHOTS_USED] != n_shots:
        raise ChainError(f"the chain stops before the level is over (shots_used "
                         f"{state[proofdata.STATE_SHOTS_USED]} of {n_shots}, not over)")
    return outputs


def run_proofs(run: Path) -> list[Path]:
    """The proofs of a `prove.py` directory in chain order: `main`, or `init`, `chunkNN` by index,
    `outputs`."""
    if (run / "main.proof.bin").exists():
        return [run / "main.proof.bin"]
    chunks = sorted((int(m.group(1)), p) for p in run.iterdir() if (m := CHUNK_PROOF.match(p.name)))
    if [i for i, _ in chunks] != list(range(len(chunks))):
        raise VerifyError(f"{run}: chunk proofs are not numbered 0..{len(chunks) - 1}")
    return [run / "init.proof.bin", *(p for _, p in chunks), run / "outputs.proof.bin"]


def cmd_run(run: Path, bin_dir: Path, executables: Path) -> None:
    doc = json.loads((run / "outputs.json").read_text())
    check_identity(doc)
    proofs = run_proofs(run)
    names = ["main"] if len(proofs) == 1 else ["init", "step_chunk", "outputs"]
    pinned = {}
    for name in names:
        path = executables / f"{name}.executable.json"
        if not path.exists():
            raise VerifyError(f"{path} is missing: the expected program hashes come from the "
                              f"executables (scarb --manifest-path crates/slingfall_replay/Scarb.toml build)")
        pinned[proofdata.program_hash(proofdata.executable_bytecode(path))] = name
    links = []
    for proof in proofs:
        claims = check_proof(proof, None, None, bin_dir)
        name = pinned.get(claims["program_hash"])
        if name is None:
            raise VerifyError(f"{proof.name}: program hash {claims['program_hash']:#x} is none of "
                              f"{', '.join(names)}'s")
        links.append((name, claims["returned"]))
        print(f"ok  {proof.name}: {name} verifies, {len(claims['returned'])} output felts")
    if names == ["main"]:
        if links[0][0] != "main":
            raise VerifyError("main.proof.bin is not a proof of main")
        outputs = proofdata.split_public_output("main", links[0][1])["outputs"]
    else:
        outputs = check_chain(links, [felt(v) for v in doc["inputs_felts"]])
        print(f"ok  chain: {len(links) - 2} chunk(s) linked by their public headers")
    if outputs != [felt(v) for v in doc["outputs"]]:
        raise VerifyError("the proven outputs are not outputs.json's outputs")
    print(f"ok  {run}: {len(proofs)} proofs, outputs = outputs.json")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("proof", nargs="?", type=Path)
    ap.add_argument("outputs", nargs="?", type=Path)
    ap.add_argument("--run", type=Path, help="a prove.py output directory")
    ap.add_argument("--bin", type=Path, default=DEFAULT_BIN, help="directory of the verify binary")
    ap.add_argument("--executables", type=Path, default=EXECUTABLES,
                    help="directory of the replay *.executable.json (the expected program hashes)")
    args = ap.parse_args()
    try:
        if args.run:
            cmd_run(args.run, args.bin, args.executables)
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
