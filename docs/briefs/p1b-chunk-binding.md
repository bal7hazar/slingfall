# P1b — sound chunked proofs: public binding of every chunk to its input state and inputs

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D4; **`docs/proving.md` "The chunk trust model"** (P1: a standalone executable's
arguments are private, only bytecode + output segment are public, so nothing binds chunk i+1's input to chunk i's
output; only the whole-level `main` proof is trustless today; `canonical_small` caps one proof at a ~2^20 range-check
segment ≈ 8.5M steps, so whole levels must be chunked); on `main`: `crates/slingfall_game/src/chunk.cairo`
(`ChunkState`, `init_state`, `step_state`, `state_outputs`), `crates/slingfall_replay/src/{chunk,outputs,main}.cairo`,
`tools/prove/{prove.py,verify.py,proofdata.py}`, `crates/slingfall_level/src/hash.cairo` (`serde_hash`).

## 2. Scope (allowlist)
`crates/slingfall_game/src/chunk.cairo` (+ tests), `crates/slingfall_replay/src/**` + its tests, `tools/prove/**`,
`docs/proving.md`, `fixtures/proofs/**`, `steps/**`, `client/src/vm/**` ONLY the parsing of the new output prefix
(`ChunkState` header offsets) + its tests, `client/vm/fixtures/replay/*.executable.json` (rebuilt),
`fixtures/golden/**` only if `main`'s outputs change (they must not).

## 3. Design (implement exactly)
Every executable's **public output** starts with a binding header, then its payload:
- `init(level)` → `[LEVEL_HASH = poseidon(level felts)] ++ state`;
- `step_chunk(state, inputs, shot, k, trace)` → `[STATE_IN_HASH = poseidon(state felts), INPUTS_HASH = poseidon(inputs felts), shot, k] ++ new_state`;
- `outputs(state, inputs)` → `[STATE_IN_HASH, INPUTS_HASH] ++ the 10 D4 felts`;
- `main` unchanged (already binds level_hash / inputs_hash in its 10 felts).
A verifier holding the proofs and their public outputs checks, from public data only: `chunk_0.STATE_IN_HASH ==
poseidon(init.state)`, `chunk_{i+1}.STATE_IN_HASH == poseidon(chunk_i.new_state)`, `outputs.STATE_IN_HASH ==
poseidon(last.new_state)`, all `INPUTS_HASH` equal and equal to the 10-felt `inputs_hash`, `shot` / `k` sequence
consistent (shots in order, each chunk's shot = the state's `shots_used` before it), `init.LEVEL_HASH ==` the
10-felt `level_hash`, and every proof's program hash is the expected executable's. Then the chain is as sound as
`main`. The hash of a state must be the same function as `slingfall_level::hash::serde_hash` on the `ChunkState`
felts (document the exact felt sequence hashed: the state's Serde output, length prefix included or not: pick one
and use it everywhere, Cairo and Python).

## 4. Work
1. Cairo: the headers above; `main`'s outputs bit-identical (goldens untouched); step overhead of the extra
   hashes reported (`steps_init`, `steps_step_chunk`, `steps_outputs` probes: a state hash of ~2k felts costs
   ~10-20k steps).
2. `tools/prove/verify.py --run <dir>`: enforce the links from the proofs' public outputs (via `proofdata.py`),
   never from `report.json`; tamper tests: a chain whose middle chunk was proven on a fabricated state is rejected.
   `prove.py`: record the headers; `docs/proving.md`: rewrite "The chunk trust model" as "Chunk binding" with the
   check list.
3. Client: `client/src/vm/program.ts` reads the state after the new prefix (header lengths as constants exported
   by the replay README); `npm test` green; executables rebuilt (`fetch-executables.sh --build`).
4. Local measurement on this VPS (your unit is capped at 22 GiB, no swap; the launcher now allows `cargo`, repo
   scripts and `nice` / `env` prefixes): `tools/prove/setup.sh --native`, then `prove.py --case one_block-miss`
   (whole) and `pile10-reference --k 16` (chain), `verify.py --run` on both; report steps, wall, peak RSS per
   proof. Only if `free -g` shows ≥ 22 GB available: `pile10-reference` whole with
   `params.canonical_without_pedersen.json` (predicted ~23 GiB: it may be killed; report the peak). Never two
   proofs at once.

## 5. Budget
`main` unchanged; chunk header hashing ≤ 2 % of a K = 16 chunk.

## 6. Tests
snforge: header contents on `init` / `step_chunk` / `outputs` with the reference case, hash equality with a
Python recomputation (golden felts); `tools/prove/test_prove.py` link tests + the fabricated-state tamper test;
CI `prove` job green (whole `one_block-miss`) and, if it stays under ~10 min, a `--k 16` chain of `one_block-miss`.

## 7. Definition of done
`AGENTS.md` §6 (crate-scoped: game, replay with `--manifest-path`, client tests); conventional commits with the
trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push `feat/p1b-chunk-binding`; `gh pr create`;
`gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Header layouts · Steps · Local measurements ·
Deviations · Escalations · PR URL). Work autonomously, do not ask questions, do not widen the scope.
