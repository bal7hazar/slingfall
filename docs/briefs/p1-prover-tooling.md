# P1 — `tools/prove/`: local Stwo proving of a level (stwo-cairo `run_and_prove`, `canonical_small`)

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D9, D10; **`docs/research/05-local-proving.md`** (spike E1L: exact commands,
params JSON, the `vm_utils.rs` patch, the memory model 2.6 GiB + 1.5 GiB per M steps); on `main`: `tools/prove/`
(staged: `vm_utils-standalone-context.patch`, `params.canonical_small.json`, `measure.py`), `crates/slingfall_replay/`
(`main`, `init`, `step_chunk`, `outputs`; README argument layouts), `tools/golden/golden.py` (how a case is run),
`fixtures/golden/cases.json`.

## 2. Scope (allowlist)
`tools/prove/**`, `docs/proving.md` (new), `.github/workflows/ci.yml` ONLY to add a `prove` job (see §3.5),
`fixtures/proofs/**` (new, small files only: outputs + proof hashes, never a proof), `.gitignore` entries.

## 3. Work
1. `tools/prove/setup.sh`: clone stwo-cairo at rev `467d5c6` under `tools/prove/vendor/` (git-ignored), apply the
   patch, build `run_and_prove`, `prove`, `verify` (`cargo build --release -j 4 -p stwo-cairo-dev-utils`; use the
   `rust-toolchain.toml` of the clone; `-C target-cpu=native` when allowed). Idempotent; prints the binaries' path.
2. `tools/prove/prove.py`: `prove --level <fixture> --shots <pull list or --case <golden case>> [--chunks N] --out <dir>`:
   builds the args with `tools/tracec`-style encoding, runs `run_and_prove --program_type executable` on
   `slingfall_replay` `main` (whole level) or, with `--chunks`, on `init` + a chain of `step_chunk` proofs
   (each proof's public output = the state it returns; the chain's binding is the next chunk's input state:
   document it as the trust model of chunked proofs), `--params_json` canonical_small, `--proof-format binary`,
   `--verify`; writes `outputs.json` (the 10 felts, from `outputs` executable or from `main`'s output), the
   proofs, `report.json` (steps, wall, peak RSS via `measure.py`, proof bytes, verify result). `verify.py <proof>
   <outputs>` re-verifies with the `verify` binary and checks the proof's public output equals `outputs.json`
   (find where the program output lives in the proof's public data: `public_data.outputs` or the
   `public_memory` output segment; document).
3. Measurements on this VPS (`measure.py`, one proof at a time, `RAYON_NUM_THREADS` default): `one_block-miss`
   (2.8M steps), `cores3-reference` (13.5M: expect a kill under 14 GiB, try under your unit's cap and report),
   `pile10-reference` whole (10.7M, only if the cap allows) and **chunked in 2 and 3 chunks** (K per `--chunks`);
   table: case × mode: steps, wall, peak RSS, proof bytes, verify. Your unit's memory cap is printed by
   `cat /sys/fs/cgroup$(cat /proc/self/cgroup | cut -d: -f3)/memory.max` at start: report it.
4. `docs/proving.md`: how to set up, prove a level, verify a proof, the memory model, the chunk trust model,
   what a verifier must check (program hash? the executable's hash as stwo exposes it; outputs; chain).
5. CI job `prove` (Ubuntu runner, ~16 GB RAM): `setup.sh` (cache the built binaries by rev), prove `one_block-miss`
   (2.8M steps ≈ 7 GiB) and verify; if the runner is too small, prove the 1-tick `ball_drop`-like smallest case
   (add a `one_block-1tick` golden case only if needed) and say so; not in `all-checks` if it exceeds ~12 min.

## 4. Budget
Report wall and peak RSS per case; nothing else is budgeted in this lot.

## 5. Tests
`prove.py` on `one_block-miss` end to end (proof verifies, outputs equal the golden); `verify.py` rejects a
tampered outputs file; the CI job green (or documented as skipped with the reason).

## 6. Definition of done
`AGENTS.md` §6 (no Cairo crate touched); conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
push `feat/p1-prover-tooling`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · Measurements table · Chunk trust model · CI · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope. Never run two proofs at once.
