# slingfall_contract

The Starknet contracts (`docs/DESIGN.md` D9, two-class layout), the only crate that depends on `starknet`:
`Slingfall` (registry, `submit`, admin; declarable) and `SlingfallSim` (the physics, no storage; too large to
declare until rapier-cairo's cuts land). `Slingfall::simulate` loads the level felts, `library_call_syscall`s
`SlingfallSim::simulate` at the admin-set `sim_class_hash` (`'simulate: class'` while unset) and sends the
D9 message from its own context. `python3 tools/classsize/classsize.py check` gates `Slingfall` under the
Starknet class limits in CI and reports `SlingfallSim`.

| module | contents |
|---|---|
| `registry` | `LevelMeta`, `Record`, `Entry`; `improves` (a won attempt beats any lost one, then the higher score; ties keep the record); `insert` (top-10 leaderboard of won attempts, ties keep the earlier row) |
| `simulate` | `class` (`ISlingfallSim`, the `SlingfallSim` contract); `MARKER`; `SimulateHook { fn simulate(level: @Level, inputs: @Inputs) -> Outputs }`, `StubSimulateHook` (identity fields only, no physics) and the alias `ActiveHook` = `replay_hook::ReplaySimulateHook`, `slingfall_game::play::play` with the `NoopObserver` (the `main` executable's logic, lot G4b); `run` (decode, `InputsTrait::validate`, hook) |
| `submit` | the contract: `ISlingfall` (`register_level`, `set_level_active`, `level`, `level_data`, `simulate`, `submit`, `best`, `leaderboard`), `ISlingfallAdmin` (`admin`, `set_admin`, `set_virtual_os_hash`, `set_sim_class_hash`, `set_verifier`, `set_attestation_key` and their reads); events `LevelRegistered`, `LevelActiveSet`, `LevelValidated`; `submit::errors` (panic messages) |
| `verifier` | `Verifier<T> { fn check(ref self, claim: Outputs, evidence: Span<felt252>) -> bool }`; `Snip36Verifier` (`tx_info.proof_facts`: program hash at `PROGRAM_HASH_INDEX` equal to the admin's `virtual_os_hash`, and `message_hash(this, MARKER, outputs felts)` among the following facts); `StubVerifier` (`evidence = [r, s]`, Stark ECDSA over `attestation_hash = poseidon(outputs felts)`); `VerifierKind` |

`submit(outputs, evidence)`: `Outputs::from_felts`; level registered and active; `player == caller`;
nullifier `poseidon(level_hash, player, inputs_hash)` unused, then set; active verifier; record and
leaderboard update; `LevelValidated`. The message-hash rule and the facts layout are provisional
until the SNIP-36 round trip (lot E2).

Golden vectors (ECDSA key and signature, message hash): `python3 tools/vectors.py golden` (stdlib
only; Poseidon from `tools/levelc/poseidon.py`). Test: `snforge test -p slingfall_contract`.
