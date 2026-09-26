# Proof measurements (lot P1)

One directory per `tools/prove/prove.py` run, named `<golden case>-<mode>`. A directory holds:

- `summary.json`, the run's `report.json` without the state felts. Per proof it keeps the steps,
  wall time, peak RSS, proof bytes, the proof's sha256 and the verify result; each public output
  or input state becomes its length and sha256.
- `outputs.json`, when the run succeeded: the 10 D4 felts, the level and inputs felts, and the
  program hash.

The proofs themselves (~1 MB each) are never committed. The runs are CI runs on
`ubuntu-latest`; see `docs/proving.md`, "Measurements". The program hashes change whenever the
replay, the rules or rapier change, so these files record a measurement; they are not goldens.
