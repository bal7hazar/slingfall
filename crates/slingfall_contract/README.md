# slingfall_contract

The Starknet contracts (`docs/DESIGN.md` D9, two-class layout), the only crate that depends on `starknet`:
`Slingfall` (registry, `submit`, admin; declarable) and `SlingfallSim` (the physics, no storage; too large to
declare until rapier-cairo's cuts land). `Slingfall::simulate` loads the level felts, `library_call_syscall`s
`SlingfallSim::simulate` at the admin-set `sim_class_hash` (`'simulate: class'` while unset) and sends the
D9 message from its own context. `python3 tools/classsize/classsize.py check` gates `Slingfall` under the
Starknet class limits in CI and reports `SlingfallSim`.

| module | contents |
|---|---|
| `registry` | `LevelMeta`, `Best` (v2 record, stored packed in 3 slots by `BestStorePacking`), `Record` (v1, kept for `slingfall_sizes`), `Entry`; `improves` / `improves_best` (a won attempt beats any lost one, then the higher score; ties keep the record); `insert` (top-10 leaderboard of won attempts, ties keep the earlier row); `remove` (a player's row out) |
| `simulate` | `class` (`ISlingfallSim`, the `SlingfallSim` contract); `MARKER`; `SimulateHook { fn simulate(level: @Level, inputs: @Inputs) -> Outputs }`, `StubSimulateHook` (identity fields only, no physics) and the alias `ActiveHook` = `replay_hook::ReplaySimulateHook`, `slingfall_game::play::play` with the `NoopObserver` (the `main` executable's logic, lot G4b); `run` (decode, `InputsTrait::validate`, hook) |
| `submit` | the contract, v2 (`docs/contract-v2.md`): `ISlingfall` (`register_level`, `set_level_active`, `level`, `level_data`, `simulate`, `submit`, `submit_settled`, `expire`, `attempt`, `best`, `best_settled`, `leaderboard`, `leaderboard_provisional`), `ISlingfallAdmin` (`admin`, `set_admin` (proposes), `set_virtual_os_hash`, `set_sim_class_hash`, `set_verifier`, `set_attestation_key` (bumps the epoch) and their reads), `ISlingfallSatellite` (`satellite_config`, `set_satellite_config`), `ISlingfallGovernance` (`pending_admin`, `accept_admin`, `upgrade`, `current_program`, `program_valid_until`, `pin_program`, `revoke_program`, `attestation_epoch`, `expire_delay`, `set_expire_delay`); `nullifier::{NONE, ATTESTED, SETTLED}`; events `LevelRegistered`, `LevelActiveSet`, `LevelValidated`, `RecordExpired`, `ProgramPinned`, `ProgramRevoked`, `AttestationKeySet`, `AdminTransferStarted`, `AdminTransferred`, `Upgraded`; `submit::errors` (panic messages) |
| `verifier` | `Verifier<T> { fn check(ref self, claim: Outputs, evidence: Span<felt252>) -> bool }`; `Snip36Verifier` (`tx_info.proof_facts`: program hash at `PROGRAM_HASH_INDEX` equal to the admin's `virtual_os_hash`, and `message_hash(this, MARKER, outputs felts)` among the following facts); `AttestationVerifier` (v2: `evidence = [program_hash, expiry, r, s]`, Stark ECDSA over `attestation_message('SLINGFALL_ATTEST', chain_id, contract, program_hash, epoch, expiry, outputs…)`); `StubVerifier` (v1: `[r, s]` over `attestation_hash = poseidon(outputs felts)`, kept for `slingfall_sizes`); `SatelliteVerifier` (`evidence = args`, `c1main`'s argument, and the `child_program_hash` of the call: the Atlantic fact of the run on Herodotus's Satellite, translated or bridged keccak; `SatelliteConfig`, `ISatellite`, `atlantic_output`, `integrity_fact`, `sharp_fact`, `run_args`; `docs/proving.md` "Contract side (E3b)"); `VerifierKind` (`Snip36`, `Stub`, `Satellite`) |

`submit(outputs, evidence)` (provisional): `Outputs::from_felts`; level registered and active;
`player == caller`; nullifier `poseidon(level_hash, player, inputs_hash)` unused, then set; the
active verifier (`Stub`: the attestation, its program valid now; `Snip36`: the proof facts;
`Satellite`: refused); records and the provisional leaderboard; `LevelValidated`. The message-hash
rule and the facts layout are provisional until the SNIP-36 round trip (lot E2).

`submit_settled(outputs, args, child_program_hash)` (settled): the same checks without `player ==
caller` (the record is `claim.player`'s, whoever sends it), the program valid now, the Satellite
fact; may settle an `ATTESTED` attempt once. `best` and `leaderboard_provisional` rank either tier,
`best_settled` and `leaderboard` settled attempts only; `expire` demotes a provisional record older
than `expire_delay` (24 h by default) to the settled best. `Best.settled`, `Best.program_hash` and
the same fields of `LevelValidated` carry the tier and the program.

Golden vectors (ECDSA key and signatures v1 / v2, message hash): `python3 tools/vectors.py golden`
(stdlib only; Poseidon from `tools/levelc/poseidon.py`); `tools/vectors.py attest …` signs a v2
attestation. Test: `snforge test -p slingfall_contract`.
