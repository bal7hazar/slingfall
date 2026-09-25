# G7 — `slingfall_contract`: level registry, `simulate`, `submit`, verifier interface

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D4, D9, D11; `docs/research/01-proof-pipeline.md` §2 (SNIP-36 `proof_facts`,
`get_execution_info_v3_syscall`), §6 (contract sketch), `01b` (audit: consensus-level security, proof
retention); `docs/research/02` §5; on `main`: `crates/slingfall_contract/src/lib.cairo` (stubs `registry`,
`simulate`, `submit`, `verifier`; manifest: `starknet`, `fixed`, `slingfall_level`, `slingfall_rules`),
`crates/slingfall_level` (G2: `Outputs::{to_felts, from_felts}`, `OUTPUTS_LEN`, `LevelTrait::hash`), the
starknet corelib in `~/.cache/scarb` or `~/.asdf/installs/scarb/2.19.4` (`core::starknet::info`,
`get_execution_info_v3` / `v3_syscall` and the `TxInfo` fields available in Cairo 2.19.4: check whether
`proof_facts` exists; if it does not, put the facts behind the `Verifier` trait and say so in the report).

## 2. Scope (allowlist)
`crates/slingfall_contract/src/**`, `crates/slingfall_contract/README.md`, `steps/slingfall_contract/*.snap`.
`slingfall_rules` is being written in parallel (lot G3): do NOT depend on its API in this lot; `simulate`
calls a `SimulateHook` / trait stub that G4 wires later (document the expected signature:
`fn simulate(level: @Level, inputs: @Inputs) -> Outputs`).

## 3. Expected API (Cairo 1 Starknet contract, `#[starknet::contract]`)
- `registry`: `register_level(level: Array<felt252>) -> felt252` (hash = `LevelTrait::hash` of the
  deserialised level after `validate`; stores `LevelMeta { author, version, active, registered_at }` and the
  level felts; `set_level_active(hash, bool)` by the author or admin), `level(hash) -> LevelMeta`,
  `level_data(hash) -> Array<felt252>`.
- `verifier`: `trait Verifier { fn check(ref self, claim: Outputs, evidence: Span<felt252>) -> bool }` with
  two impls: `Snip36Verifier` (reads `proof_facts` from `get_execution_info_v3`: virtual-OS program hash equals
  a storage `virtual_os_hash` settable by the admin; the L2->L1 message hash of `(from = this, to = MARKER,
  payload = outputs felts)` is among the facts; keep the exact hashing rule in one function with a unit test
  on a fixed vector) and `StubVerifier` (admin-signed attestation: `evidence = [r, s]` over
  `poseidon(outputs felts)` checked against an admin public key with `core::ecdsa::check_ecdsa_signature`;
  the interim path of research 01 §4 rank 2). The active verifier is a storage enum switched by the admin.
- `simulate(level_hash, inputs: Array<felt252>)`: loads the level felts, deserialises, validates inputs against
  the level, calls the simulate hook, and `send_message_to_l1_syscall(MARKER, outputs felts)`; also returns
  the outputs (so `scarb execute` / snforge can call it).
- `submit(outputs: Array<felt252>, evidence: Array<felt252>)`: `Outputs::from_felts`; level registered and
  active; `outputs.player == get_caller_address()`; nullifier `poseidon(level_hash, player, inputs_hash)` unused,
  then set; `verifier.check`; update `best[(player, level_hash)]` if `score` higher (and `won`); emit
  `LevelValidated { player, level_hash, inputs_hash, score, won }`. Reads: `best(player, level_hash) -> Record`,
  `leaderboard(level_hash) -> Array<(ContractAddress, u32)>` (top 10 kept in storage, insertion sort).
- Admin: `Ownable`-like minimal (owner set at construction; `set_admin`, `set_virtual_os_hash`,
  `set_verifier`, `set_attestation_key`). No upgradeability in this lot (DEFER).

## 4. Steps / gas budget
`submit` (stub verifier) ≤ 200k Cairo steps in snforge (`steps_submit__stub`), `register_level(pile10)` reported.

## 5. Tests
snforge contract tests (`snforge_std` cheatcodes: `start_cheat_caller_address`, `spy_events`): register +
read, inactive level rejected, wrong caller rejected (`'submit: player'`), replay rejected
(`'submit: nullifier'`), stub-verifier accept / reject with a real ECDSA vector (generate the key pair and the
signature in a Python helper committed under `crates/slingfall_contract/tools/` if the stdlib allows it; else
use a known Starknet test vector), best-score update rules, leaderboard order, events. Panic messages in
an `errors` module. For `Snip36Verifier`, a unit test of the message-hash rule only (facts cannot be
cheated in snforge unless a cheatcode exists: check `snforge_std` for `cheat_execution_info`; use it if present).

## 6. Definition of done
`AGENTS.md` §6: `scarb fmt --workspace`, `scarb lint -p slingfall_contract --deny-warnings`, `scarb build -p slingfall_contract`,
`snforge test -p slingfall_contract`, `python3 scripts/steps.py snapshot --filter slingfall_contract`; conventional
commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push `feat/g7-contract`;
`gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · API · Step table ·
Deviations · Deferred · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
