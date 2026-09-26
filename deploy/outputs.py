#!/usr/bin/env python3
"""outputs: the 10 output felts of a golden case replayed for another player (the account that
will `submit` them: the contract wants `player == caller`). Python 3 standard library only.

    deploy/outputs.py --case pile10-reference --player 0x... --out outputs.json [--no-build]
                      [--child-hash HEX]

Runs the proof build `main` of `crates/slingfall_replay` with `scarb execute`, as
`tools/golden/golden.py` does, on the case's level and shots with `inputs.player = --player`,
and writes `{"case", "player", "outputs": [10 x 0x felts], "steps", "args"}` (`args`: `c1main`'s
argument, the evidence of `submit_settled`). The simulation never reads the player: every felt but
`player` and `inputs_hash` must equal the golden's, which is checked. With `--child-hash` (the
`SatelliteVerifier`'s `child_program_hash`) it adds the run's Atlantic facts (`facts`:
`integrity_fact_hash`, `sharp_fact_hash`; `tools/atlantic/encoding.py`), the facts the devnet's
`FakeSatellite` is told (`deploy/e2e.sh`).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "golden"))
import golden  # noqa: E402  (scarb execute of the replay, tracec, Poseidon)

sys.path.insert(0, str(ROOT / "tools" / "atlantic"))
import encoding  # noqa: E402  (the Atlantic fact chain)

PLAYER_INDEX, INPUTS_HASH_INDEX = 3, 4


def replay(case_name: str, player: int, build: bool, child_hash: int | None = None) -> dict:
    path = golden.GOLDEN / f"{case_name}.json"
    doc = json.loads(path.read_text())
    level = golden.Level(doc["level"])
    inputs = golden.tracec.inputs_felts(player, [tuple(s) for s in doc["shots"]])
    if build:
        golden.build()
    started = time.time()
    steps, outputs, _ = golden.run_build(level, inputs, "main")
    expected = [int(v, 16) for v in doc["outputs"]]
    for i, (got, want) in enumerate(zip(outputs, expected)):
        if i not in (PLAYER_INDEX, INPUTS_HASH_INDEX) and got != want:
            raise SystemExit(f"{case_name}: {golden.OUTPUT_NAMES[i]} {got:#x} differs from the golden {want:#x}")
    if outputs[PLAYER_INDEX] != player % golden.P or outputs[INPUTS_HASH_INDEX] != golden.poseidon.hash_span(inputs):
        raise SystemExit(f"{case_name}: player / inputs_hash are not the replayed inputs'")
    print(f"outputs: {case_name} for {player:#x}: {steps:,} steps, {time.time() - started:.0f} s", file=sys.stderr)
    args = [len(level.felts), *level.felts, len(inputs), *inputs]
    doc = {"case": case_name, "player": hex(player), "outputs": [hex(v) for v in outputs], "steps": steps,
           "args": [hex(v % golden.P) for v in args]}
    if child_hash is not None:
        facts = encoding.slingfall_fact(child_hash, outputs, args)
        doc["facts"] = {"child_program_hash": hex(child_hash), **{k: hex(v) for k, v in facts.items()}}
    return doc


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--case", default="pile10-reference", help="a fixtures/golden case")
    parser.add_argument("--player", required=True, help="felt: the submitting account address")
    parser.add_argument("--out", required=True)
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--child-hash", help="SatelliteVerifier's child_program_hash: add the run's facts")
    args = parser.parse_args(argv)
    child = int(args.child_hash, 0) if args.child_hash else None
    doc = replay(args.case, int(args.player, 0), not args.no_build, child)
    Path(args.out).write_text(json.dumps(doc, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
