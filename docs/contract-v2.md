# Contract v2

Lot V2 (2026-09-27): the `Slingfall` contract of `crates/slingfall_contract/src/submit.cairo`, as research
06 §2.1-2.3 designed it (`docs/research/06-fast-validation.md`), closing QA M7 and the contract half of S10 /
S12 (`docs/qa/2026-09-26-mac.md`). Code only: nothing is declared or deployed by this lot. Lot W1 (same
branch) wires the client, the services and `deploy/**` to v2 ("Wiring (lot W1)" below); a v2 deployment
is a later lot.

## What changes

| # | v1 (Sepolia `0x4b645f…0ae2`) | v2 |
|---|---|---|
| programs | one `SatelliteConfig.child_program_hash`; a re-pin voids every proof in flight (M7) | `programs: Map<hash, valid_until>` + `current_program`; `pin_program(hash, grace_s)` keeps the previous one for `grace_s`, `revoke_program(hash)` voids one at once, `program_valid_until(hash)`; `submit_settled(outputs, args, child_program_hash)` asserts the hash is valid now and builds the fact with it |
| relay | `submit_settled` requires `caller == player` | `submit_settled` records for `claim.player`, whoever sends it; `submit` (attested) keeps `caller == player` |
| tiers | one record per player and one board, both tiers mixed | `best` (either tier) + `best_settled`; `leaderboard` (settled only) + `leaderboard_provisional` (each player's `best`, either tier); permissionless `expire(level, player)` |
| attestations | `poseidon(outputs)`, no domain | `poseidon('SLINGFALL_ATTEST', chain_id, contract, program_hash, epoch, expiry, outputs…)`; `set_attestation_key` bumps the epoch |
| verifiers | `set_verifier` switches `submit` between Snip36, Stub and Satellite | `submit` is the provisional tier (Stub by default, Snip36 later; `Satellite` closes it), `submit_settled` the settled one, always open |
| records | `Record { score, won, inputs_hash, block, settled }`, 5 slots | `Best { …, timestamp, program_hash }`, 3 slots (packed) |
| admin | `set_admin` takes effect at once; no upgrade | `set_admin` proposes, `accept_admin` takes over; `upgrade(class_hash)` (`replace_class_syscall`, event `Upgraded`) |

## Programs (M7)

- `programs[hash]` is the block timestamp until which `hash` is accepted (exclusive): `FOREVER` (`u64::MAX`) for
  the current program, `0` for a hash never pinned or revoked. A program is valid while `block_timestamp <
  valid_until`.
- `pin_program(hash, grace_s)` (admin): the previous current program gets `valid_until = now + grace_s`
  (saturating below `FOREVER`), `hash` gets `FOREVER` and becomes current. Re-pinning the current hash changes
  nothing else; pinning a former hash makes it current again. Event `ProgramPinned { program_hash, previous,
  previous_valid_until }`.
- `revoke_program(hash)` (admin): `valid_until = 0`; if it was current, `current_program = 0` (nothing new
  settles until the next pin). Event `ProgramRevoked`.
- `submit_settled(outputs, args, child_program_hash)`: `'submit: program'` unless the hash is valid now; the
  fact is then recomputed with that hash, so a hash that is valid but not the one the run was proven with fails
  as `'submit: proof'`. Taking the hash from calldata is safe: the fact commits to it.
- The attested `submit` applies the same rule to the program its attestation names (`evidence[0]`).
- `Best.program_hash` and `LevelValidated.program_hash` carry the program of each row: `c1main`'s hash for the
  settled and attested tiers, `sim_class_hash` for SNIP-36.
- `SatelliteConfig` loses `child_program_hash` (three fields: the two bootloader hashes and the Satellite).

Policy (research 06 §2.3, the admin's to apply): a grace period (e.g. 24 h) for bit-compatible re-pins only;
`grace_s = 0` plus `revoke_program` for the fix of an exploitable defect. With two numerically different
programs both valid, the same `(level, inputs)` has two valid outputs and the nullifier keeps whichever settles
first; choose a short grace or new level hashes for such releases.

## Relay (S10)

`submit_settled` no longer compares `claim.player` with the caller: the fact binds the player (the proven
program computes `player` from `args`), so anyone may settle anyone's proven attempt, with exactly the outcome
the player would get (`improves` never lowers a record). The record, the boards and `LevelValidated.player` are
`claim.player`'s. A `claim.player` that is not a contract address (≥ 2^251) is refused with `'submit: player'`.
Player and relay racing: the second reverts on `'submit: nullifier'` and pays a failed fee. The attested
`submit` keeps `caller == player` (the attestation carries no consent of the player).

## Tiers

- `best(player, level)`: the best attempt of either tier (what v1's `best` was); `best_settled(player, level)`:
  settled attempts only. Invariant: `best` is `best_settled` or a provisional record above it (or the same
  attempt, settled by upgrade).
- `leaderboard(level)`: the top 10 of the won `best_settled` records; `leaderboard_provisional(level)`: the top
  10 of the won `best` records (the "live" board, where a provisional row may stand above settled ones). A
  provisional record therefore never hides a settled one: the settled board and `best_settled` ignore it.
- A provisional submission writes `best` and the provisional board; a settled one also writes `best_settled`
  and the settled board. The settlement of the attested attempt that is `best` marks it `settled` (and records
  it in `best_settled`).
- `expire(level, player)` (anyone): if `best` is provisional, not settled, above `best_settled` and at least
  `expire_delay` seconds old (`block_timestamp - best.timestamp`), `best` falls back to `best_settled` and the
  player's provisional-board row moves to it (or goes, when the settled best is not a win). Event
  `RecordExpired { player, level_hash, inputs_hash }`. The attempt stays `ATTESTED`: it can still be settled
  later, and is then the record again. Errors: `'expire: none'` (nothing to demote), `'expire: early'`.
- `expire_delay` defaults to 24 h (`DEFAULT_EXPIRE_DELAY = 86 400`); `set_expire_delay` (admin).
- A top-10 board keeps no rows below its tenth: a player pushed out earlier does not come back when a row is
  removed by `expire` (the same limitation as v1's `insert`).

The alternative of research 06, `Entry.settled` on a single board, was not taken: `slingfall_sizes`' fixtures
call `registry::insert` and read `Entry`, and one mixed board cannot answer "the settled top 10" without a
scan. Two boards cost one extra board update on a settled submission (measured below).

## Attestations

`evidence = [program_hash, expiry, r, s]`, a Stark-curve ECDSA signature of

```
attestation_message = poseidon_hash_span(['SLINGFALL_ATTEST', chain_id, contract, program_hash, epoch, expiry,
                                          outputs[0..10]])
```

by `attestation_key`, where `chain_id` is `tx_info.chain_id`, `contract` this contract's address and `epoch`
`attestation_epoch()`, the number of `set_attestation_key` calls (the first key is epoch 1). The signature is
accepted while `block_timestamp < expiry` and `programs[program_hash]` is valid. It cannot be replayed on
another chain or deployment, after a rotation (rotating to the same key also bumps the epoch, which voids every
earlier signature at once) or once expired. The v1 `[r, s]` evidence is refused. Golden vector:
`crates/slingfall_contract/tools/vectors.py golden` (`GOLDEN_ATTEST_*`); a service signs with `vectors.py
attest SECRET CHAIN_ID CONTRACT PROGRAM_HASH EPOCH EXPIRY OUTPUT...` or its own port of `attestation_message`.

`VerifierKind` keeps its three values (`slingfall_sizes` matches on them): `Stub` is the v2 attestation and the
constructor's choice, `Snip36` the proof facts, `Satellite` refuses every `submit` (the provisional tier
closed, e.g. after a key compromise: then rotate the key and `expire` the rows).

## Admin and upgrade

- `set_admin(new)` (admin, `ISlingfallAdmin`, signature unchanged) now only proposes: `pending_admin() = new`,
  event `AdminTransferStarted`. `accept_admin()` by the pending admin takes over (event `AdminTransferred`);
  anyone else gets `'admin: pending'`. Proposing again replaces the pending admin; proposing oneself cancels.
- `upgrade(class_hash)` (admin; `'upgrade: zero'` for zero): `replace_class_syscall`, event `Upgraded`. No
  timelock: research 06 asks for one before mainnet (a later lot). The storage layout of v2 is what a v3 class
  must keep.

## Interfaces

`ISlingfall` (players):

```
register_level(level) -> felt252            set_level_active(level_hash, active)
level(level_hash) -> LevelMeta              level_data(level_hash) -> Array<felt252>
simulate(level_hash, inputs) -> Outputs
submit(outputs, evidence)                   evidence = [program_hash, expiry, r, s] (Stub) | [] (Snip36)
submit_settled(outputs, args, child_program_hash)
expire(level_hash, player)
attempt(level_hash, player, inputs_hash) -> u8
best(player, level_hash) -> Best            best_settled(player, level_hash) -> Best
leaderboard(level_hash) -> Array<(ContractAddress, u32)>              settled
leaderboard_provisional(level_hash) -> Array<(ContractAddress, u32)>  either tier
```

`ISlingfallAdmin` (unchanged signatures): `admin`, `virtual_os_hash`, `sim_class_hash`, `verifier`,
`attestation_key`, `set_admin` (proposes), `set_virtual_os_hash`, `set_sim_class_hash`, `set_verifier`,
`set_attestation_key` (bumps the epoch). `ISlingfallSatellite`: `satellite_config`, `set_satellite_config`
(three fields). `ISlingfallGovernance`: `pending_admin`, `accept_admin`, `upgrade`, `current_program`,
`program_valid_until`, `pin_program`, `revoke_program`, `attestation_epoch`, `expire_delay`,
`set_expire_delay`.

`Best { score: u32, won: bool, inputs_hash, block: u64, timestamp: u64, settled: bool, program_hash }` (7
felts in calldata / return data). Events: `LevelRegistered`, `LevelActiveSet`, `LevelValidated` (+
`program_hash`), `RecordExpired`, `ProgramPinned`, `ProgramRevoked`, `AttestationKeySet { attestation_key,
epoch }`, `AdminTransferStarted`, `AdminTransferred`, `Upgraded`. New panic messages: `'submit: program'`,
`'expire: none'`, `'expire: early'`, `'program: zero'`, `'upgrade: zero'`, `'admin: pending'`.

Configuration of a fresh deployment: `set_attestation_key(pub)` (epoch 1), `pin_program(c1main_hash, 0)`,
`set_satellite_config({atlantic_bootloader, sharp_bootloader, satellite})`, `set_sim_class_hash` when
`SlingfallSim` is declarable, then the levels.

## Gas and size

snforge probes, over their setup (`steps_submit__stub(_setup)`, `steps_submit_settled__*`), L2 gas as snforge
estimates it (`--detailed-resources`) and Cairo steps; first record and first board row of the player.

| entry point | v1 L2 gas | v2 L2 gas | v2 unpacked `Best` | v1 steps | v2 steps |
|---|--:|--:|--:|--:|--:|
| `submit` (attested) | 4 267 200 | **3 870 320** (−9 %) | 4 512 320 | 9 968 | 10 132 |
| `submit_settled`, translated fact | 6 069 200 | **8 002 320** (+32 %) | 10 090 320 | 23 860 | 27 034 |
| `submit_settled`, keccak fact | 9 027 200 | **10 960 320** (+21 %) | – | 56 817 | 59 991 |
| `expire`, full board, top row removed | – | 907 840 | – | – | 24 657 |

- The attested `submit` got cheaper despite the longer signed message: `Best` is packed in 3 slots (v1's
  `Record` took 5), and the provisional board is the only board it writes.
- A first settled record costs more: it writes two records (`best`, `best_settled`) and two boards. The
  settlement of an attested attempt that is already the record writes one board only.
- Packing (`registry::BestStorePacking`) saves 0.64M on `submit` and 2.09M on `submit_settled` against the
  derived 7-slot layout (the "unpacked" column, measured by swapping the derive in; not kept).
- The attestation check itself: `steps_verifier_attestation_check` 805 steps (v1 `StubVerifier` 487).

Class of `Slingfall` (`scarb build`; CASM from the `deploy/contract` package), limit 81 920 felts each:

| | Sierra felts | CASM felts | class bytes |
|---|--:|--:|--:|
| v1 | 8 409 | 18 049 | 427 340 |
| v2 | 10 823 (0.13x) | 23 892 (0.29x) | 562 932 |

## Tests

`crates/slingfall_contract/src/submit/tests/`: `programs.cairo` (pin, grace, saturation, revoke, stale program
after grace on both tiers, `grace_s = 0`, revoked and unknown programs), `tiers.cairo` (provisional not hiding
settled, both tiers moved by a better settlement, `expire` before / at the delay, without a settled record,
on a lost record, refusals, an expired attempt settled later, the delay setter), `governance.cairo` (two-step
admin, cancellation, `upgrade` to a test class, attestation replays across contract / chain / program / expiry
/ epoch, relayed settlement by a third party and of an attested attempt, the race loser on the nullifier, the
attested tier not relayable, a player that is not an address), `settled.cairo` (the E3a facts on v2, both
tiers without a verifier switch, `Satellite` closing `submit`), and `verifier.cairo` (the golden
`attestation_message`, each field committed, the verifier's refusals).

## Wiring (lot W1)

What speaks v2 on this branch, and where each change of the interface lands:

| v2 change | where |
|---|---|
| 3-field `SatelliteConfig`; a fresh deployment = key + `pin_program(c1main, 0)` + Satellite + levels | `deploy/slingfall.ts deploy` (`deploy/devnet.sh`, `deploy/sepolia.sh deploy`) |
| `pin_program(hash, grace_s)` with an explicit grace (`--bit-compatible` = 86 400 s, else 0 / `--grace S`); `revoke_program`; the unsettled-jobs guard (Q3) on both | `deploy/slingfall.ts pin-program` / `revoke-program`, `deploy/sepolia.sh pin` / `revoke` |
| `set_attestation_key` (epoch), two-step admin, `upgrade`, `set_expire_delay` | `deploy/slingfall.ts set-attestation-key` / `set-admin` / `accept-admin` / `upgrade` / `set-expire-delay`, `deploy/sepolia.sh` |
| the attestation message and `[program_hash, expiry, r, s]` evidence; epoch read from the contract | `services/attest/attest.py` (`--execute` re-executes the replay; `--verify-cmd` kept; rate limit per player), `client/src/chain/attest.ts` |
| `program_valid_until(hash) > now` instead of equality with the pin; `child_program_hash` in `submit_settled` | `services/prove/prove_service.py` (409, `/status`, `/health`), `client/src/chain/slingfall.ts`, `panel.ts` |
| `submit_settled` for `claim.player` (relay) | `services/prove/relay.py` (`serve --relay`, `relay <job>`), `/status` `relayed` |
| `Best` (7 felts), `best_settled`, `leaderboard` settled, `leaderboard_provisional`, `LevelValidated.program_hash`, `expire` | `client/src/chain/slingfall.ts` (`readBoards`), `panel.ts` (two boards, the release of each row), `deploy/slingfall.ts best --settled` / `leaderboard --provisional` / `boards` / `expire` |

`deploy/e2e.sh` runs both tiers on the devnet: the attested submit (the service re-executing), a relayed
settle by a third account, a re-pin with grace (an old proof settles inside the window, `'submit:
program'` after it) and an expired provisional record (`docs/e2e.md`).
