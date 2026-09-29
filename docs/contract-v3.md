# Contract v3

Lot V3 (2026-09-28): the SNIP-36 tier of `Slingfall` (`crates/slingfall_contract/src/submit.cairo`,
`submit/chunks.cairo`, `verifier.cairo`), as research 07 §4 and programme research SN1 §4 specify it. Code only:
nothing is declared, deployed or sent by this lot. v3 is v2 (`docs/contract-v2.md`) plus a third tier; `upgrade`
carries a v2 deployment to v3 with every record kept. Lot W3 wires the deploy scripts, the services and the client
to it, on the local devnet ("Wiring (lot W3)" below).

## What changes

| # | v2 | v3 |
|---|---|---|
| tiers | provisional (attested), settled (Satellite) | + **proven** (SNIP-36 chain): `submit_chunk` × (n + 2), then `finalize` |
| nullifier | `NONE -> ATTESTED -> SETTLED` | `NONE -> ATTESTED -> SETTLED \| PROVEN`, `NONE -> SETTLED \| PROVEN` (`nullifier::PROVEN = 3`) |
| ranking | `best_settled`, `leaderboard`: Satellite only | both proofs rank together: a proven record is `Best.settled = true` in `best_settled` and the settled board |
| `Snip36Verifier` (`submit`'s `Snip36` kind) | program hash at index 0, any later fact a message | the protocol layout (`verifier::facts`): header checked, program at 2, `n` at 7, messages only in `[8, 8 + n)` |
| `LevelValidated` | `…, settled, program_hash` | `…, settled, program_hash, proven` (trailing felt) |
| admin | programs (`c1main`) | + the chain set (`pin_chain(chain, bundle_hash, grace_s)`, `revoke_chain`), the virtual-OS set (`pin_virtual_os`, `revoke_virtual_os`), `set_chunk_marker` |
| storage | v2's 19 variables | v2's, unchanged, then 9 new ones (`chunk_*`, `chains`, `chain_bundles`, `current_chain`, `virtual_os_programs`, `current_virtual_os`) |

`Best` keeps its 7 felts (the client checks the length): which proof validated a row is `attempt(level, player,
best.inputs_hash)` (`SETTLED` or `PROVEN`) and `LevelValidated.proven`; a proven row's `program_hash` is its chain's
bundle hash.

## The chain as the contract sees it

The contract knows a chain only by its address, its marker and its payloads (research 07 §4; it does not depend on
`slingfall_split`). A chain contract (`SplitChain`) sends one L2 to L1 message per proven transaction, `to =
chunk_marker`:

| kind (`chunks::kind`) | transaction | payload |
|---|---|---|
| `INIT` = 0 | `init(level)` | `[LEVEL_HASH, STATE_OUT_HASH]` |
| `STEP` = 1 | `step_chunk(state, inputs, shot, k)` | `[STATE_IN_HASH, INPUTS_HASH, shot, k, STATE_OUT_HASH]` |
| `OUTPUTS` = 2 | `outputs(state, inputs)` | `[STATE_IN_HASH, INPUTS_HASH] ++ outputs` (the 10 D4 felts) |

`LEVEL_HASH` is the registry's `level_hash` (both are `poseidon(level felts)`), `INPUTS_HASH` is `poseidon(inputs
felts)` = `outputs.inputs_hash`.

**A chain is a bundle.** `SplitChain` fixes the classes it library-calls at deployment, so one deployment is one
release's class-hash bundle. The admin pins chains like programs: `pin_chain(chain, bundle_hash, grace_s)` makes
`chain` current (`FOREVER`) and leaves the previous one valid for `grace_s` seconds; `revoke_chain` voids one at once.
`bundle_hash` is the admin's declaration of the bundle (e.g. Poseidon of the class hashes; the contract cannot read
them) and becomes the `program_hash` of the records the chain proves. Every link is stored under its chain, so a
walk never mixes two releases, and `finalize` refuses a chain past its grace: **a record proven with a retired bundle
is refused after its grace**, links already stored included.

## `submit_chunk(chain, kind, payload)`

Anyone, any order, any number of times (idempotent). Checks, in order:

1. `chunk_marker != 0` and `chain` valid now: `'chunk: chain'`.
2. `tx_info.proof_facts` (read once, `Slingfall::proof_facts`) are SNIP-36 facts (`verifier::parse_facts`): at least
   8 felts, `facts[0] ∈ {'PROOF1', 'PROOF2'}`, `facts[1] = 'VIRTUAL_SNOS'`, `facts[3] = 'VIRTUAL_SNOS0'`, `n =
   facts[7]` messages present (felts after them are ignored, as the OS only checks a minimum length), a `u64` base
   block: `'chunk: facts'`.
3. `facts[2]` (the virtual-OS program) valid now in `virtual_os_programs`: `'chunk: program'`.
4. The base block constraints the facts expose, which the OS of the real transaction already enforces (defence in
   depth): `facts[4] <= block_number - 10` (`BLOCK_HASH_BUFFER`) and `facts[5] != 0`: `'chunk: base block'`. The
   config hash (`facts[6]`) is left to the OS.
5. `poseidon([chain, chunk_marker, len(payload), ...payload])` among `facts[8 .. 8 + n)`: `'chunk: message'`.
6. The payload (`chunks::parse`): an unknown kind `'chunk: kind'`; the kind's length, non-zero states, and for
   `STEP` a `u8` shot, a `u32` `k >= 1` and a new state (`k = 0` is the chain's no-op, a loop here), for `OUTPUTS`
   outputs that decode and carry the payload's `INPUTS_HASH`: `'chunk: payload'` (or the level crate's `outputs:
   *`).

Then it stores the link, keyed by chain:

| kind | storage |
|---|---|
| `INIT` | `chunk_starts[(chain, LEVEL_HASH)] = STATE_OUT_HASH` |
| `STEP` | `chunk_edges[(chain, INPUTS_HASH, STATE_IN_HASH)] = Edge { shot, k, next: STATE_OUT_HASH }` (2 slots, `shot << 32 \| k` packed) |
| `OUTPUTS` | `chunk_ends[(chain, INPUTS_HASH, STATE_IN_HASH)] = poseidon(outputs)` |

An identical link again is a no-op; a different one under a taken key is `'chunk: conflict'`. A replayed proof
therefore changes nothing, and `submit_chunk` is safe to relay: it records facts, never a result.

**Several chunks per transaction.** A real transaction carries one proof, and one proof covers one virtual
transaction, so several links share a transaction only when one virtual transaction calls several chain entry points
(its facts then hold several messages; the account multicalls `submit_chunk` against the same facts,
`test_one_proof_many_chunks`). Calldata is never the limit: a `submit_chunk` call is 6 + 2 / 5 / 12 felts (init /
step / outputs) in a multicall, the facts 8 + n, against 5,000. The limit is the virtual transaction's 10M steps:
`init` (0.77M) or `outputs` (0.07M) fits beside a chunk. On research 07's reference shot, layout (e): `init` + chunk
0-90 (8.76M) and chunk 90-107 + `outputs` (7.76M), 2 proofs instead of 4.

## `finalize(chain, level_hash, inputs, outputs)`

Anyone (a relay), once per attempt:

1. `chain` valid now: `'finalize: chain'`.
2. `outputs` decode (`outputs: *`); `inputs` are exactly one `Inputs` (`'finalize: inputs'`); `outputs.level_hash =
   level_hash`, `outputs.inputs_hash = poseidon(inputs)`, `outputs.player = inputs.player`: `'finalize: outputs'`
   (P1b checks 7-8, the player bound in the inputs).
3. The walk: `H = chunk_starts[(chain, level_hash)]`; while no `chunk_ends[(chain, inputs_hash, H)]`, follow
   `chunk_edges[(chain, inputs_hash, H)]`: its shot is at least the previous step's and below `inputs.shots.len()`
   (`'finalize: shot'`), at most `chunks::MAX_EDGES = 64` steps (`'finalize: length'`); no start, or a state with
   neither step nor end (a broken or unfinished chain), is `'finalize: link'`. The end must be `poseidon(outputs)`
   (`'finalize: outputs'`).
4. The shared admission (`admit`): level registered and active (`'submit: level'`, `'submit: inactive'`), `player`
   an address, the nullifier `NONE` or `ATTESTED` (`'submit: nullifier'`); the nullifier becomes `PROVEN`.
5. `record`: `best` and the provisional board, `best_settled` and the settled board (a proof), an attested record of
   the same attempt marked `settled` with the bundle hash; `LevelValidated { settled: true, proven: true,
   program_hash: bundle_hash }`.

The checks the proven transactions make themselves (the shot in progress, the level not over, the last state
finished: research 07 §4 "What the proven transactions check themselves") are not repeated: a transaction that fails
them reverts, and the virtual OS proves no reverted transaction. The shot order and bound are checked again because
they cost one comparison per step. `k` is a budget, not a counter: the chain defines nothing monotonic about it, so
the contract only refuses `k = 0`.

## Admin

Everything through the existing two-step admin (`assert_admin`):

- `set_chunk_marker(marker)`: `to_address` of the chains' messages (`'SLINGFALL'` for `SplitChain`); zero refuses
  every chunk.
- `pin_chain(chain, bundle_hash, grace_s)` / `revoke_chain(chain)`, reads `current_chain`, `chain_valid_until`,
  `chain_bundle`; events `ChainPinned { chain, bundle_hash, previous, previous_valid_until }`, `ChainRevoked`;
  `'chain: zero'` for a zero chain or bundle.
- `pin_virtual_os(program_hash, grace_s)` / `revoke_virtual_os(program_hash)`, reads `current_virtual_os`,
  `virtual_os_valid_until`; events `VirtualOsPinned`, `VirtualOsRevoked`; `'program: zero'`. The same shape as
  `programs`: StarkWare may rotate the virtual OS per release (0.14.4 allows two hashes).
- The grace rule of the three sets is one function, `submit::grace_until`.

The virtual-OS check is made when a link is submitted: revoking a program does not void links already stored.
Revoke the chain too to void them.

## Upgrade from v2

v3's `Storage` is v2's, unchanged, followed by v3's variables (all zero after `upgrade`: the SNIP-36 tier stays
closed until the admin sets the marker, a chain and a virtual OS). `Best`'s packing is unchanged.
`submit/tests/upgrade.cairo` checks it: `SlingfallV2Storage` freezes v2's `Storage` and `Best` packing (at `2625ad1`),
writes one value of every variable, replaces its class with `Slingfall`, and v3 reads everything back (admin, keys,
Satellite, programs, level, nullifiers, both records, both boards), then proves the attempt v2 attested (its record
marked settled in place).

Configuration after `upgrade(v3_class_hash)`: `set_chunk_marker('SLINGFALL')`, `pin_virtual_os(hash, 0)` (the hash
the 0.14.4 prover emits, SN1's open question 1), `pin_chain(split_chain, bundle_hash, 0)` once `SplitChain` is
deployed and its classes declared (10 blocks before any base block).

## Tests

`submit/tests/proven.cairo`: proof facts through snforge 0.61's `start_cheat_proof_facts` (the whole
`tx_info.proof_facts`; nothing is stubbed in the contract), synthetic chains (state hashes are opaque to the contract):

- 5 and 7 chunks relayed by a third party; ranking with the settled tier; links in reverse order and twice;
  conflicts; one proof holding every message;
- refused facts: wrong program, the message of another address / marker / payload, no message, v2's layout, no
  facts, a young base block, no base block hash; malformed payload, unknown kind; no chain, no marker;
- broken link, unfinished chain, a step of another inputs hash, outputs of another player / level / result, inputs
  of another player or malformed; shots backwards or out of the inputs; 65 steps refused, 64 accepted;
- replay (`finalize` twice, then `submit` and `submit_settled` of the proven attempt), the upgrade of an attested
  attempt; a retired chain within and after its grace, a revoked chain; the virtual-OS grace and revocation; admin
  refusals; an inactive level.

`submit/chunks.cairo` (parsing, `Edge` packing), `verifier.cairo` (`parse_facts`, the fixed `Snip36Verifier`),
`submit/tests/upgrade.cairo` (v2 storage).

## Gas and size

snforge probes over their setup (`steps_submit_chunk__*`, `steps_finalize__*`), L2 gas as snforge estimates it
(`--detailed-resources`) and Cairo steps:

| entry point | L2 gas | steps | L1 data gas |
|---|--:|--:|--:|
| `submit_chunk`, a step (facts of 1 message, `Edge` written: 2 slots) | 1,204,000 | 4,231 | 192 |
| `submit_chunk`, `outputs` (outputs decoded and hashed, 1 slot) | 842,000 | 4,486 | 96 |
| `finalize`, 5 steps (first record, both boards) | 7,047,440 | 17,509 | 1,248 |
| `finalize`, 7 steps | 7,207,440 | 18,901 | 1,248 |
| `finalize`, 64 steps (`MAX_EDGES`) | 11,247,440 | 58,573 | 1,248 |
| per step of the walk ((64 − 7) / 57) | 70,877 | 696 | – |
| for reference, v2 on the same probes: `submit` (attested) / `submit_settled` (translated) | 3,875,440 / 8,007,440 | | |

`submit` and `submit_settled` cost 5,120 L2 gas more than in v2 (3,870,320 / 8,002,320): the `proven` felt of
`LevelValidated`. The owner's shot in layout (b) (research 07: `init`, 7 chunks, `outputs`) costs 7 × 1.20M for the
steps, about 0.84M each for `init` and `outputs` (`init` is not probed: one slot, no decoding) and 7.2M for
`finalize`: ≈ 17.3M L2 gas of contract execution, beside the protocol's 75M L2 gas per proof.

Class of `Slingfall` (`scarb build`; CASM from the `deploy/contract` package), limit 81,920 felts, programme gate
73,728:

| | Sierra felts | CASM felts | class bytes |
|---|--:|--:|--:|
| v2 | 10,823 | 23,892 | 562,932 |
| v3 | 14,119 (0.17x) | **32,839** (0.40x, margin 40,889 to the gate) | 746,784 |

## Known limits

- **Conflicting links.** Two valid proofs from the same state with different `k` lead to different states; the first
  stored wins, the second reverts `'chunk: conflict'`. A third party can only produce one if it knows the attempt's
  inputs and state felts (the prover's, until `finalize` publishes the inputs); the honest prover then re-proves
  from the stored state.
- **`bundle_hash` is declared, not read.** The contract cannot read `SplitChain`'s class hashes; the admin states
  them, and a chain whose classes could change after deployment would break "one chain, one bundle" (Escalations
  of the lot's `REPORT.md`). Lot W3 closes the second half: `SplitChain` has no setter (its test and the deploy
  script's entry-point check), and `pin-chain` recomputes the bundle from the deployed chain itself.
- **Not built:** finalising in the `outputs` submission (research 07 §4 option), a batch entry point (a multicall
  does it), events per link.

## Wiring (lot W3)

What speaks v3 on the devnet, and where each piece of the interface lands (no Sepolia transaction: Sepolia stays
v2 until a SNIP-36 proof can be made there, `docs/proving.md` "SNIP-36 tier"):

| v3 piece | where |
|---|---|
| `upgrade(v3)` of a v2 deployment, every v2 value read back | `deploy/v2.sh` (v2's class rebuilt from the D2 commit, its hash checked against `deploy/sepolia.json`), `deploy/slingfall.ts deploy --artifacts` / `upgrade --declare` / `snapshot`, `deploy/e2e.sh` |
| a chain deployment = a bundle: layout (e)'s classes declared, `SplitChain(build, settle, edit, world, outputs, raw = true)` (`edit` = rapier's `WorldEditClass` since B6) | `deploy/slingfall.ts deploy-split` (hashes from `slingfall_split::hashes`; refuses a `SplitChain` class with any entry point but `init`, `step_chunk`, `outputs`; reads the deployment back), `deploy/split.ts` |
| `set_chunk_marker('SLINGFALL')`, `pin_virtual_os`, `revoke_virtual_os`, `pin_chain(chain, bundle, grace)` (bundle hash = Poseidon of the ordered class hashes, recomputed from the chain's class and storage, printed), `revoke_chain`; reads | `deploy/slingfall.ts set-chunk-marker` / `pin-virtual-os` / `revoke-virtual-os` / `pin-chain` / `revoke-chain` / `chain`, `deploy/devnet.sh proven` |
| `submit_chunk` per message with the proof attached, `finalize` for `inputs.player` (a relay) | `services/prove/snip36.py` (plan, prove through `FakeProver` / `Snip36Prover`, submit, finalize), `deploy/slingfall.ts submit-proof` / `finalize` / `sign-virtual` |
| the proven tier's program check: `chain_bundle(current_chain())` = the service's bundle, `chain_valid_until > now` | `services/prove/prove_service.py` (409, `/status`, `/health` `proven`) |
| `attempt()` = 3 (`PROVEN`), `LevelValidated.proven`, a proven record's `program_hash` = its bundle hash | `client/src/chain/slingfall.ts` (`ATTEMPT.proven`, `LevelValidated.proven`, `readBoards`: each row's proof, `describeProof`), `panel.ts` (the proven path when `/health` offers it, the settled one otherwise), `deploy/slingfall.ts attempt` / `boards` |

The bundle order (`SPLIT_BUNDLE_CLASSES`, `snip36.BUNDLE_CLASSES`, both derived from
`crates/slingfall_split/classes.json`, lot H3): the crate's classes, `SplitChain`, `BuildClass`, `SettleClass`,
`WorldClass`, `OutputsClass`, `RulesClass`, then the rapier classes the game calls, `WorldEditClass` (the
constructor's `edit` since lot B6: rapier's World edits replaced the game's `EditClass`), `ContactBallClass`,
`SolveAdvanceClass`, `IslandsClass`, `BroadPhaseClass`, `MassClass`, `NarrowPhaseClass`, `ActiveSetClass` (14
classes; `ContactPolygonClass` is not called on rapier alpha.8, `SolverClass` and `ForceEventsClass` never were:
none is built or declared, `docs/research/07-split-game-step.md` "Status after B6"). On today's pins (alpha.8):
`0x8a629c64c8e6c34dcc4cd0f29fd51c2c34d19cefe83647335a98825ddd7368`, the crate's `hashes::BUNDLE_HASH` (H3's 15-class
bundle on alpha.7 was `0x31e8cf85968b72f60645e8687591a8c7dacb476f60cbfe07fb9ef3341351fbd`, H2's 17-class bundle
`0x5bb15de9dd18b5b54ac337bb16aea411064a56a7f4449991bc7e2913dcfc06f`).

`deploy/e2e.sh` runs it on the devnet: a v2 deployment with three attested records, upgraded (every value read
back), the proven tier opened, the player's attested record proven by SNIP-36 (fake prover, 4 proofs on alpha.7, 3
on alpha.8, relayed),
a second player's settled by the Satellite path, a retired chain accepted inside its grace and refused after it.
Measured costs: `docs/proving.md` "Cost sheet".
