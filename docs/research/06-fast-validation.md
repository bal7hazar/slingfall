# R6 — validating a shot on Starknet in under 5 minutes, and what to ship until then

Date: 2026-09-27. Author: R6 research agent (Opus 5.5) for the programme session. Read-only; no proving run.
Tags: **(v)** verified in the cited source; **(inf)** my inference from cited sources; **(nv)** not verified;
**(est.)** my estimate from recorded measurements. Web facts were gathered by three sub-agents through page
extraction (not byte-exact reads of files): spot-check a quoted value before copying it into code.

## Summary (one page)

**Answer.** No trustless path validates a shot on Starknet in under 5 minutes today, and none will before
November 2026. The only candidate that can reach it is **SNIP-36 with the physics in declared contract
classes**, proving the shot's chunks in parallel. It needs three things we do not have yet:

- PROOF2 enabled on Sepolia (relayed as ≈ 2026-10-08);
- the simulation split across classes that each fit 81 920 felts (alpha.6's game program is 231k felts, ≈ 2.8x);
- a chain of ≤ 10M-step virtual transactions, since shots are 8.8-48.8M steps.

A direct Stwo verifier contract, recursive aggregation, appchains and other services are not paths today.

**What to ship until then.** The current deployment already gives an instant *provisional* tier without a
redeploy: the admin sends `set_attestation_key` + `set_verifier(Stub)`, and `submit_settled` keeps working
beside it. A relay also needs no contract change: the player pre-signs a **SNIP-9 outside execution** of
`submit_settled` when they press Prove, and the service sends it when the fact lands.

M7 (a grace set of program hashes), relaying by `claim.player`, tiered leaderboards and upgradeability all
need a **contract v2 and a new deployment**: the deployed class has no upgrade entry point
(`submit.cairo:4`, "No upgradeability yet").

| path | shot → validated on chain | cost per shot | prover RAM / who | trust | today | blockers | earliest (est.) |
|---|---|---|---|---|---|---|---|
| **Today: Atlantic + SHARP + Satellite** (settled) | 53 min - 2 h 08 (measured) | free on testnet; mainnet ≈ 95-120 credits (≈ $1-1.2) + settle 0.29-0.34 STRK (Sepolia prices) | Herodotus / SHARP | SHARP L1 verifier + Herodotus bridge + upgradeable Satellite | live | SHARP batch cadence (not ours) | now |
| **1a. SNIP-36, physics in split classes, parallel chunks** | ≈ 2-4 min (est.): each chunk proven in parallel in 1-2 min, then 2-6 txs | 75M L2 gas per chunk proof (flat) + execution: 2-6 chunks ≈ 155-480M L2 gas; 3.4-10 STRK at Sepolia's observed 21.8 gFri, 0.5-1.4 STRK at 3 gFri | 96 GB / 48 vCPU recommended per prover; we run it | Starknet consensus (phase 1: gateway-verified, not yet L1-settled) | fact layout + `Snip36Verifier` written, untested | PROOF2 on Sepolia; class split (2.8x after CS2, maybe 3-4 classes, +steps); ≤ 10M steps per virtual tx; `library_call` inside the virtual OS unverified | Sepolia late Oct - Nov 2026 if the split costs ≤ ~+50 % steps; mainnet after |
| 1b. Stwo verifier contract (our local proof) | ≈ 3-5 min (est.) if it existed | ≥ 7 txs of 5k calldata felts per 1 MB proof, plus verification steps (unknown) | ours, 20 GiB whole / 10 GiB chunked | Stwo soundness + our contract | **nothing deployed**; Cairo verifier crate exists, not a contract | no split-verification scheme; Poseidon channel re-prove; verifier class size and steps unknown | 2027 (L lot, no upstream) |
| 1c. Recursive aggregation of chunk proofs | – (a component: still needs 1a/1b/SHARP to land on chain) | + ≈ 1 min per recursion level (StarkWare blog) | ours | same as the final verifier | `stwo_run_and_prove_recursive_tree` exists (circuit recursion) | leaf formats accepted (nv); no Starknet-side verifier for its root outside SNIP-36's fixed circuits | not a path alone |
| 1d-i. Optimistic claim + challenge window, settled path as fraud proof | instant visible; **final after the window** (≥ 3 h) | submit ≈ 5.6M L2 gas; proving only on dispute | our watcher re-executes each claim (seconds) | 1-of-N honest watcher + Satellite | not built | contract v2; bond / griefing economics | M lot after v2 |
| 1d-ii. Appchain / L3 (Katana + Saya), other services | = Atlantic's latency (Saya settles through Atlantic) | – | – | – | – | no faster verifier underneath | no |
| **Interim A. Provisional (attested) tier + settled upgrade** | ≈ 10-30 s provisional (est.); settled as today | ≈ 5.6M L2 gas (≈ 0.12 STRK at Sepolia prices) + the settle later | service re-executes (seconds) or proves (1-3 min, 20 GiB) | our attestation key | contract ready (`StubVerifier`, `NONE → ATTESTED → SETTLED`); service exists | 2 admin txs; attest service hosted; client flow | days |
| **Interim B. SNIP-9 relay of `submit_settled`** | player leaves after Prove; settles when the fact lands | the service pays 0.29-0.34 STRK (Sepolia) | – | none added (the player signs the exact call) | wallets: Braavos, Argent/Ready V2 (v); Cartridge v3 | wallet `signTypedData` UX (nv); Ready mainnet gated | days |

**Ranked plan** (§4):

1. Provisional tier on the current deployment (S).
2. SNIP-9 relay (S).
3. Contract v2: grace set + revoke, relay by `claim.player`, tiered boards, domain-separated attestations,
   upgradeability (M, after B4).
4. SNIP-36 round trip with a two-class toy as soon as PROOF2 is on Sepolia (S).
5. Class split of `SlingfallSim` and a real-chunk SNIP-36 proof (M-L).
6. Optimistic tier, only if mainnet needs to drop the attestation key (M).

Park 1b and 1c.

**Single most useful experiment.** Prove **one real pile10 impact chunk through SNIP-36, with the step split
across two library-called classes**, using `starknet_proveTransaction` against Sepolia. It answers four
questions at once:

- whether `library_call` works inside the virtual OS;
- the steps overhead of a class crossing;
- the proving time and RAM per ≤ 10M-step chunk;
- the proof-facts layout and message hash.

Each of these decides whether path 1a exists at all.

---

## 1. Direct paths

### Facts that bound every path

| limit | value | source |
|---|---|---|
| steps per invoke tx | `invoke_tx_max_n_steps` = 10 000 000 **(v)** | `starkware-libs/sequencer`, branch `main-v0.14.4`, `crates/blockifier/resources/blockifier_versioned_constants_0_14_4.json` |
| Sierra gas per tx | `execute_max_sierra_gas` = 1 110 000 000 **(v)** | same file |
| calldata | `max_calldata_length` = 5 000 felts, counting `calldata + proof_facts` **(v)** | same file; `crates/apollo_gateway/src/stateless_transaction_validator.rs` |
| proof size | `max_proof_size` = 480 000 **(v)**; units (u32 words or bytes) **(nv)** | versioned constants 0.14.4 |
| proof fee | `gas_per_proof` = 75 000 000 L2 gas, flat **(v)**; the SNIP text derives it from 130 L2 gas/byte × 500 KB + 10M | constants; [SNIP-36 forum](https://community.starknet.io/t/snip-36-in-protocol-proof-verification/116123) |
| class size | Sierra length ≤ 81 920 (gateway `max_contract_bytecode_size`) **and** compiled CASM ≤ 81 920 (`apollo_sierra_compilation_config`, `max_bytecode_size = 80 * 1024`) **(v)**; class JSON ≤ 4 089 446 B | `stateless_transaction_validator.rs`; `crates/apollo_sierra_compilation_config/src/config.rs`; `apollo_gateway_config/src/config.rs` |
| our program | alpha.6 `BasicStepConfig` game-shaped program 565k → 231k felts (brief B4; `SlingfallSim` CASM re-measured by B4, pending) | `briefs/game-B4.md` §1 |
| our shots | 8.8M-48.8M Cairo steps (owner's near-miss cap shot 48.75M, m9) | QA `docs/qa/2026-09-26-mac.md` m9 |
| local Stwo | whole pile10 8.78M steps: 55 s / 20.5 GiB (`canonical_without_pedersen`); K = 16 chunks: 21-36 s, 4.3-10.2 GiB each, ~1-1.5 MB per proof; verify ~1.5 s | `docs/proving.md` "Measurements (P1b)" |

Correction to earlier notes: the gateway's 81 920 check counts **Sierra**, and the compiler separately caps
**CASM** at 81 920. Both bind; G7b's "CASM is binding" still holds, since CASM is the larger of the two.

### 1a. SNIP-36 in-protocol proofs

**What it is (v).**

- Invoke V3 gains `proof` and `proof_facts`. `proof` goes to the gateway and mempool and is not kept in blocks.
- The gateway verifies an S-two proof of one Invoke transaction executed in a "virtual OS" on top of a real
  block.
- Contracts read `get_execution_info_v3_syscall().tx_info.proof_facts`.
- Timeline: live on mainnet since v0.14.2 (2026-04). v0.14.4 raises the virtual block to "any SNOS-valid
  virtual block that contains a single transaction … up to 1.1B L2 gas". v0.14.4 was planned for Sepolia on
  2026-09-15 and mainnet on 2026-10-05, pending governance
  ([notes](https://community.starknet.io/t/starknet-v0-14-4-prerelease-notes/116341)).
- PROOF2 is sequencer PRs [#15014](https://github.com/starkware-libs/sequencer/pull/15014) and
  [#15120](https://github.com/starkware-libs/sequencer/pull/15120). The gateway defaults are
  `allow_proof_version_v1: false` and `allow_proof_version_v2: true`.
- Sepolia activation of the V2 verifier is relayed by StarkWare as "~2 weeks" after 2026-09-24
  (`decisions/2026-09-26-cs1-verdict-and-cs2-deferred.md`). Neither the relayed ≈ 2026-10-08 date nor the
  current Sepolia state is verified **(nv)**. Reading of the defaults **(inf)**: until V2 is on, Sepolia may
  accept no SNIP-36 proof at all.

**Limits that matter to us.**

- **Steps per virtual tx.** ≤ 10M steps (the invoke limit) and ≤ 1.1B gas. A shot of 8.8-48.8M steps is
  therefore **1-5 virtual txs before any class-split overhead**. Chunk boundaries fall where the local
  chunker already puts them (`step_chunk`, `docs/proving.md` "Chunk binding"). One proof per transaction,
  one transaction per virtual block **(v)**.
- **Class size.** The prover takes Invoke V3 only; Declare and DeployAccount are rejected **(v)**
  (`crates/starknet_transaction_prover` README). A virtual block can therefore only call classes already
  declared through the gateway, which enforces both 81 920 limits. **The open question of the 2026-09-26
  note is answered in the negative (inf): an oversized class cannot be smuggled in through a virtual block.**
  No class-size check was found in the blockifier or the virtual OS themselves (nv), which is irrelevant
  once declaration is the gate.
- **Splitting and chaining.** The protocol does nothing for this; the application can. Two designs:
  - *Sequential:* chunk i+1's virtual execution reads chunk i's state hash from real storage. Latency is the
    sum of the chunks: 2-6 × (1-2 min + inclusion), 3-12 min.
  - **Parallel (recommended):** every chunk runs on the previous chunk's state, which the prover has from its
    own local run. Each virtual tx emits one L2→L1 message
    `(chunk_header = [STATE_IN_HASH, INPUTS_HASH, shot, k], STATE_OUT_HASH)`. This is exactly P1b's binding
    header, with `new_state` replaced by its hash.

    The real `submit_chunk` tx stores `link[state_in_hash] = state_out_hash` for the attempt. `finalize`
    walks from `init`'s `LEVEL_HASH` state to a finished `outputs` message, applying the 8 checks of
    `docs/proving.md` "What a verifier checks".

    All chunks are proven at once, so latency is the time of **one** proof (1-2 min, v0.14.4 notes) plus
    n inclusions. Inclusions are a few seconds each, and the txs can come from different accounts with no
    nonce ordering (inf).
  - The state (3 001-3 232 felts for pile10) travels as the virtual tx's calldata. Whether the 5 000-felt
    limit applies inside a virtual block is **(nv)**; pile10's state + inputs fits anyway.
- **Proof size.** Bounded by `max_proof_size`. The large-proof entry point is `privacy_recursive_prove_large`
  in `starkware-libs/proving`'s `privacy-prove` **(v)**, which recurses to a fixed-size circuit proof. Our
  1-1.5 MB local proofs are not what is sent.

**Who proves, RAM, latency.**

- We run `starknet_transaction_prover`: JSON-RPC `starknet_proveTransaction(block_id, invoke_v3)`, 2
  concurrent requests by default, "c4d-highcpu-48 (48 vCPU, 96 GB)" recommended **(v)**.
- Proving time is 3-5 s for a small block and 1-2 min for a block-sized one **(v)**.
- Parallel chunks need either several prover instances or one machine with ≥ n × the RAM of a large proof
  (nv; ~96 GB each is the safe assumption). For 2-6 chunks: 2-6 such machines, or accept sequential
  proving at ≈ 1.5 min per chunk.
- Rejected builtins: ecdsa, range_check96, add_mod, mul_mod **(v)**. Our program uses output, range_check,
  bitwise and poseidon (`docs/proving.md`), so none is excluded.

**Cost.**

- The proof is a flat 75M L2 gas per tx **(v)**. The execution inside the virtual block is "paid as a
  proof" **(v)**. The real tx's own execution is small: ~2-5M L2 gas for the link and record writes (est.,
  from the attested `submit`'s 5.65M).
- The owner's settle cost 0.3401 STRK for 15.6M L2 gas, so Sepolia's observed L2 gas price is
  ≈ 21.8 gFri/gas.
- Per chunk: 77-80M L2 gas, ≈ 1.7 STRK at 21.8 gFri, ≈ 0.24 STRK at 3 gFri.
- Per shot of 2-6 chunks: **3.4-10 STRK (Sepolia prices), 0.5-1.4 STRK (3 gFri)**.
- This is 10-30x today's settle fee. It is the price of < 5 min; batching several players' chunks into one
  virtual tx is not possible (one tx per virtual block).

**Trust.** Phase 1 SNIP-36 is verified by Starknet consensus (the gateway / sequencer), **not yet settled
on L1**, per the SNIP's security section **(v)**. That is a stronger model than an attestation key and
comparable in practice to the Satellite chain (SHARP + Herodotus bridge + upgradeable Satellite).

**Exists today versus must be built.**

- Exists: `Snip36Verifier` and `simulate` (`crates/slingfall_contract/src/verifier.cairo`); the chunk binding
  headers and chain checks (P1b); the facts layout from the sequencer (`virtual_os_output.cairo`: program
  hash at index 2, messages from index 8, D9).
- To build:
  - fix `PROGRAM_HASH_INDEX` (0 → 2) and the message offset (8);
  - confirm the OS's message hash rule (D9 still says "to be confirmed");
  - `submit_chunk` / `finalize` with per-attempt link storage;
  - **the class split**: see below;
  - a SNIP-36 prover deployment and a chunk scheduler in the prover service.

**The class split is the real blocker.**

- CS1 measured ~27k CASM and 76 942 steps per class crossing, with a 4-5-class chain costing +83-104 % per
  impact tick. That was before CS2 (`decisions/2026-09-26-cs1-verdict-and-cs2-deferred.md`).
- With 231k felts, 3-4 classes of ≤ 81 920 are needed (est.): 231k / (81 920 − 27k) ≈ 4.2 if every class
  pays the crossing, fewer if the rules and glue stay in `Slingfall`.
- That puts the overhead at roughly +50-100 % steps on impact ticks (est.). Shots would become 2-10 chunks,
  and the fee doubles with them.
- `library_call_syscall` inside the virtual OS is still unverified (CS1). A cheaper split may exist: split
  by pipeline phase (broad phase / narrow phase / solver) over a state already in memory. That is rapier
  design work.

**Earliest date (est.).** A toy round trip is possible the day PROOF2 is on Sepolia (≈ 2026-10-08, nv).
Real shots are possible 3-5 weeks later, if the split lands at ≤ +50 % steps: **Sepolia early-to-mid
November 2026**. Mainnet needs v0.14.4 on mainnet (2026-10-05, pending) and PROOF2 enabled there **(nv)**.

### 1b. A Stwo verifier contract on Starknet verifying our local proof

- **Nothing deployed (v).**
  - stwo-cairo's `stwo_cairo_verifier` is a Cairo *program* (proof in Cairo-serde as input, run with
    `scarb execute`), not a contract. Its last directory commits are 2026-07-21 (circuit work).
  - Development moved to `starkware-libs/proving` at the end of July 2026 (`proving-utils` README; that
    stwo-cairo moved with it is an inference).
  - Channel and Merkle hash are Scarb features (`poseidon252_verifier`, `qm31_opcode`, …), with Blake2s the
    default ([Scarb.toml](https://github.com/starkware-libs/stwo-cairo/blob/main/stwo_cairo_verifier/crates/cairo_verifier/Scarb.toml)).
  - Integrity is Stone-only (last functional change 2025-09-09).
  - The Satellite is a fact lookup.
  - The sequencer's `starknet_proof_verifier` accepts only StarkWare's privacy circuits (V1 / V2).
  - Atlantic's docs: "S-two is supported only for L1 verification. Support for L2 (integrity verifier) will
    be added soon."
- **Formats.** Our proofs use the Blake2s channel and `canonical_small` / `canonical_without_pedersen`.
  - Which preprocessed variants the Cairo verifier accepts is **(nv)**.
  - A Starknet-side verifier realistically needs a Poseidon252 channel (Blake2s is not a cheap Starknet
    builtin; its gas price is nv), so our prover's parameters would change.
- **Size and gas.** A 1-1.5 MB proof is ≥ 32-48k felts, at least 7-10 txs of 5 000 calldata felts (inf).
  No Stwo split-verification scheme exists **(v, none found)**; Integrity's
  `verify_proof_initial` / `step` / `final` is the model. The steps of one verification are unpublished
  **(nv)**; StarkWare's blog says proving the Cairo verifier takes "approximately 1 minute", which suggests
  millions of steps.
- **Verdict.** An L lot with no upstream to lean on: build a split verifier, fit its class under 81 920, and
  audit it. Latency would be good (prove ~1 min + 7-15 sequential txs). The engineering and audit risk
  put it in **2027**. Park.
- **Variant:** run the Cairo verifier inside a SNIP-36 virtual tx. The virtual tx must carry the ~1 MB proof
  (5 000-felt calldata, nv inside a virtual block), its class must fit 81 920, and it must stay under 10M
  steps. All three are unknown and at least one looks unlikely (inf). Park.

### 1c. Recursive aggregation of chunk proofs

- **Tooling (v).**
  - `stwo_run_and_prove_recursive_tree` (`starkware-libs/proving`, `crates/stwo_run_and_prove_recursive_tree`)
    reduces N proofs to a root circuit proof.
  - StarkWare moved recursion from the Cairo verifier (~1 min per proof, "dedicated machines with ample
    memory") to circuit recursion (~3 s) (blog 2026-03-31).
  - Whether it accepts arbitrary stwo-cairo leaves such as our executables' proofs is **(nv)**; it appears
    to be built for the privacy leaf format.
- **What it buys.** One proof per shot instead of 2-6. That matters for SHARP (one Atlantic job regardless)
  and would matter for 1b (one on-chain verification). It is **not a path to Starknet by itself**: the root
  proof still needs a Starknet-side verifier, and SNIP-36's in-protocol verifier accepts only its own
  circuits. Revisit if StarkWare opens a `proof_variant` for third-party circuits (the header has a
  `proof_variant` field, D9).

### 1d. Other options

- **Optimistic validation with a challenge window, backed by the settled path.**
  - A player (or anyone) submits a *claim* `(outputs, args)` with a bond. The record is visible at once as
    "pending".
  - Outputs are a deterministic function of `(level, inputs)` and of the pinned program. A challenger
    therefore defeats a claim by settling, through the existing Satellite path, a fact for the **same
    `args` and program hash with different outputs**. The contract recomputes both facts and slashes the
    bond.
  - After the window W with no challenge, the claim is final. W must exceed the settled path's worst case
    (2 h 08 measured, so W ≈ 6-12 h).
  - Honest case: one cheap submit and no proof. Our watcher re-executes every claim natively in seconds
    (the browser VM runs 6.3M steps/s, QA) and proves only disputed ones.
  - Trust: one honest watcher + the Satellite chain; no key.
  - Griefing: false claims force a 1-2 h proof and cost our watcher an Atlantic job, so the bond must cover
    it. Watchers can be denied the challenge by a Satellite outage, so W must have margin.
  - It does not give "final in < 5 min"; it gives "visible now, final in hours, without a trusted key".
    M lot on contract v2, only if mainnet must drop the attestation key.
- **Appchain / L3.** Dojo's Saya settles Katana through Atlantic on Piltover (v,
  [dojoengine/saya](https://github.com/dojoengine/saya)), so its latency is Atlantic's. Its TEE mode goes
  to SP1 Groth16 with no Starknet verifier found. No.
- **Other services.** No Aligned or other verification layer posting to Starknet was found (nv, likely
  none). Atlantic publishes no fast mode or latency figure **(v, absence)**. The 53 min - 2 h is SHARP's
  batch cadence; nothing we control shortens it.

## 2. Interim product design (current deployment, contract changes allowed)

### 2.0 What the deployed contract already allows (no redeploy)

`Slingfall` on Sepolia (`0x4b645f…0ae2`) has `set_verifier`, `set_attestation_key`, `submit` and
`submit_settled` (`crates/slingfall_contract/src/submit.cairo`):

- `submit_settled` checks the Satellite **whatever the active verifier** and upgrades
  `NONE/ATTESTED → SETTLED` (`admit`).
- `submit` runs the active verifier. With `Stub` it records `ATTESTED` (provisional).

Two admin transactions (`set_attestation_key(pub)`, `set_verifier(Stub)`) therefore enable the provisional
tier today. The client must then call `submit_settled` for the settled tier: it no longer goes through
`submit`'s Satellite branch.

The class has **no upgrade entry point** (`submit.cairo:4`). Every item below marked "v2" means declare +
deploy + re-register the six levels, and the Sepolia records (one row today) are lost. The whole E3b
deployment cost 31.8 STRK, 22.9 of it the declare (`docs/proving.md`).

### 2.1 Immediate provisional record (attested tier) upgraded to settled

**Flow.**

1. The client plays and gets the 10 outputs.
2. `POST /attest {level, inputs}`: the service re-executes the replay and signs `poseidon(outputs)` if the
   outputs match.
3. The player sends `submit(outputs, [r, s])` and the record is provisional.
4. In parallel, the prover service starts the Atlantic job.
5. The settled upgrade lands with `submit_settled`, relayed (§2.2).

**Re-execute rather than prove.** The existing `services/attest/attest.py` verifies a Stwo proof
(`--verify-cmd`). No browser prover exists, so the service would first have to prove the shot itself: 1-3
min and ~20 GiB for a whole shot, or 10 GiB per chunk. A service that signs after its *own* proof is no
more trustworthy than one that signs after its own *re-execution*. Re-execution takes seconds (native
cairo-vm; the browser VM does 15.9M steps in 2.4 s). Add an `--execute` mode (S). Keep `--verify-cmd` for
players who bring a proof.

**Latency** (est.): 3-10 s of re-execution + one tx inclusion, ≈ **10-30 s** to a provisional on-chain row.

**Gas.** Attested `submit` = 5 649 600 L2 gas on devnet (`docs/proving.md`), ≈ 0.12 STRK at Sepolia's 21.8
gFri. The settle upgrade later costs 15.6M (keccak path, measured) or ≈ 4.5-11.3M (Poseidon, bounded)
L2 gas.

**Storage and interface.**

- Today: none.
- v2:
  - `Entry` gains `settled: bool`, or two boards: `boards_settled`, `boards_provisional`. Today one board
    mixes both tiers and only `best()` carries the tier; the decision "leaderboard shows settled records
    first" is currently a client-side read of `best()` per row.
  - `best_settled: Map<(player, level), Record>`, so that a better provisional record does not hide the
    player's settled best.

**Attack surface.**

- *Key compromise* (the main risk): fake provisional rows sit on the board forever. Today the only remedies
  are `set_attestation_key` rotation and `set_level_active(false)`; there is no way to strike a row.
  - v2: a permissionless `expire(level, player)` demotes a provisional record older than T (e.g. 24 h) that
    was never settled.
  - Also v2: key rotation that invalidates earlier signatures, via an epoch in the signed message.
- *Replay across versions and contracts*: `attestation_hash = poseidon(outputs)` has no domain. A signature
  stays valid after a re-pin, even across the SF1 numeric change of alpha.6, where the same inputs give
  other outputs. It is also valid on another deployment that shares the key.
  - v2: sign `poseidon('SLINGFALL_ATTEST', chain_id, contract, program_hash, expiry, outputs…)`.
- *Replay by another player*: impossible. `admit` requires `claim.player == caller`, and the nullifier is
  per `(level, player, inputs_hash)`.
- *Front-running*: nothing to gain. The same claim with the same player gives the same record, and a
  second copy reverts on the nullifier.
- *Unsettleable provisional* (proof never lands, program re-pinned, M7): stays provisional. It is harmless
  if shown as such and `expire`d in v2.
- *Copying a shot*: another account replaying published inputs under its own `player` gets the same score
  later, and ties keep the earlier row (`registry::insert`). This is inherent to a deterministic game; the
  tiers do not change it. A per-player seed or commit-reveal would, out of scope.

### 2.2 The service relays `submit_settled` for the player

**B1 — no contract change: SNIP-9 outside execution (recommended now).**

- The calldata `submit_settled(outputs, args)` is fully known at Prove time. The player signs one
  `OutsideExecution { caller: relayer, nonce, execute_after: now, execute_before: now + 12-24 h, calls:
  [submit_settled…] }` (SNIP-12 typed data, [SNIP-9](https://github.com/starknet-io/SNIPs/blob/main/SNIPS/snip-9.md)).
- The service calls `execute_from_outside_v2` on the player's account when `/status` says settleable
  **and** a `simulateTransaction` of `submit_settled` succeeds (M6).
- Inside the game contract the caller is the player's account, so `caller == player` holds (inf from the
  account semantics; test on Sepolia).
- Wallets **(v)**, from the starknet.js `www/docs/guides/account/outsideExecution.md` table: Braavos v1.1.0
  and Argent (now "Ready") v0.4.0 support V2, OpenZeppelin v1.0.0 with SRC9, and Cartridge Controller has
  its own `execute_from_outside_v3`.
  - Neither the Argent nor the Braavos account contract caps the window (v; Braavos's inner
    `assert_timestamp_2` not read).
  - Ready's docs: outside execution works on Sepolia for everyone, but **mainnet support must be requested**
    **(v)**.
  - That a browser wallet will sign a dapp-built OutsideExecution through `wallet_signTypedData` is
    **(nv)**: test it with Braavos first.
- If the call reverts (for example a re-pin), the transaction's state changes, including the outside
  nonce, roll back. The relayer pays the fee and the signature stays reusable (inf from Argent / Braavos
  code + protocol revert semantics).
- Attack surface:
  - a leaked signed payload can only execute exactly that settle, to the player's benefit;
  - the relayer can withhold, but the player can still settle themselves (the nonce is unused);
  - the relayer pays gas, so rate-limit per player.
- Gas: the relayer pays the settle, 0.29-0.34 STRK on Sepolia. On mainnet a paymaster (SNIP-29, AVNU)
  could sponsor it, but whether AVNU executes a payload signed hours earlier is (nv); our own relayer
  avoids the question.

**B2 — contract v2: record for `claim.player`, any caller.**

- `submit_settled` drops `claim.player == caller` and `record` uses `claim.player` instead of
  `get_caller_address()`. This is sound because the fact commits to `args`, which contain the inputs and
  their `player` (`verifier.cairo` `atlantic_output`).
- Attack surface:
  - anyone can settle anyone's *proven* attempt: the outcome is identical to the player doing it, and
    `improves` never lowers a record;
  - relayer and player race: the loser reverts on `'submit: nullifier'` and pays a failed fee;
  - event spam needs valid facts, so it is bounded by Atlantic cost.
- Keep `caller == player` on the attested `submit`, unless the attestation also carries the player's
  consent.
- Gas: unchanged (−1 comparison).
- Removes the wallet dependency (Ready mainnet gating, Controller v3).

### 2.3 A set of accepted `child_program_hash` values with a grace period (M7)

**Storage (v2).**

- `programs: Map<felt252, u64>`: program hash → `valid_until` timestamp (`u64::MAX` for the current pin,
  0 = never or revoked). `current_program: felt252`.
- `SatelliteConfig.child_program_hash` becomes the current pin; the three other constants stay.

**Interface (v2).**

- `pin_program(hash, grace_s)`: the new hash becomes current, and the old one gets
  `valid_until = now + grace_s`.
- `revoke_program(hash)`: `valid_until = 0` at once.
- `program_valid_until(hash) -> u64`.
- `submit_settled(outputs, args, child_program_hash)`: the verifier builds `atlantic_output` with the given
  hash and asserts `programs[hash] > block_timestamp`. The hash is committed by the fact anyway, so taking
  it from calldata is safe.
- Record it: `Record.program_hash` and a `LevelValidated.program_hash` field, so the client shows the engine
  release of each row.
- The same shape serves `virtual_os_hash` for SNIP-36 (versioned per Starknet release) and the attestation
  epoch.

**Gas.** +1 storage read (≈ 10-20k L2 gas, est.) and 1 calldata felt.

**Attack surface.**

- *A stale program with a known bug*: during the grace window anyone who knows the bug can settle scores
  the new release would refuse. Hence `revoke_program`, and a rule: grace (e.g. 24 h) only for
  bit-compatible re-pins (alpha.3 → alpha.5 was bit-identical); `grace_s = 0` plus revoke for a fix of an
  exploitable defect.
- *Numeric changes* (alpha.6's SF1): with both programs valid, the same `(level, inputs)` has two valid
  outputs, and the nullifier accepts whichever settles first. Scores across engines are not strictly
  comparable. Choose the policy per release: short grace, or new level hashes and a board reset. The
  optimistic fraud rule (§1d) must key on `(args, program_hash)`.
- *Admin griefing*: a re-pin still invalidates proofs in flight beyond the grace. The service-side check
  (Q3 / S12: refuse at `POST /prove` if the hash differs; simulate before showing Settle) stays necessary.

**Redeploy.** Yes (v2). Add `upgrade(class_hash)` through `replace_class_syscall` (admin; timelocked before
mainnet), so that v3 is not another redeploy.

## 3. Recommendation

| # | lot | size | depends on | can start now | outcome |
|---|---|---|---|---|---|
| 1 | **Provisional tier on the current deployment.** `attest.py --execute` (re-execution mode) + hosting; the client submits `submit(outputs, [r,s])` first, shows "provisional", then settles; the admin sends `set_attestation_key` + `set_verifier(Stub)` | S | Q3 (service program-hash checks) for the settle half; owner's consent for the 2 admin txs and a hosted key | yes | ≈ 10-30 s to a row on chain |
| 2 | **SNIP-9 relay.** The client asks the wallet for an OutsideExecution signature at Prove; the prover service stores it, simulates, then executes on settleable; the page can be closed | S | 1 (same client panel); Braavos test first | yes | no 1-2 h vigil for the player |
| 3 | **Contract v2**: program set + grace + revoke (M7), `submit_settled` for `claim.player` (B2), tiered boards + `best_settled` + `expire`, domain-separated attestations with epoch, `Record.program_hash`, `upgrade()`; fix `Snip36Verifier` offsets (2 / 8) on the way; Sepolia redeploy | M | B4 merged (alpha.6 program hash); decision on the re-pin policy | design now, code after B4 | M7 closed; relay without wallet dependency |
| 4 | **E2-lite: SNIP-36 round trip** with a toy two-class contract (`library_call` + L2→L1 message) on Sepolia via `starknet_proveTransaction` / `snip-36-prover-backend`: facts layout, message hash, latency, fee, virtual-block calldata limit | S | PROOF2 on Sepolia (≈ 10-08, nv); a 96 GB prover box (rent) | prepare now | facts pinned; `library_call` in the virtual OS known |
| 5 | **SNIP-36 for real shots**: B4's `SlingfallSim` CASM; a split design with rapier (3-4 classes or a phase split); prove one impact chunk (the experiment below); then `submit_chunk` / `finalize` and a parallel chunk scheduler | M-L | 4; rapier escalation for the split | the size measurement, yes | < 5 min settled tier, at 2-6 × 75M L2 gas per shot |
| 6 | Optimistic tier (claim + bond + challenge by settled fact) | M | 3 | no | drops the attestation key for mainnet |
| – | Park: Stwo verifier contract (1b), aggregation (1c), appchain (1d-ii) | L | – | – | revisit if StarkWare ships a Starknet Stwo verifier or opens a SNIP-36 `proof_variant` |

**Single experiment that most reduces the uncertainty.** Take one pile10 impact chunk (~4-5M steps on
alpha.6), put its `step_chunk` body behind a two-class split (`Slingfall` → `SlingfallSimA` →
library call → `SlingfallSimB`, each declarable), and prove it with `starknet_proveTransaction` against a
Sepolia block on a rented 96 GB box. It needs no PROOF2 activation to *prove*, only to submit (nv: that the
prover runs before the gateway accepts V2).

Measure:

- (i) does `library_call` work in the virtual OS;
- (ii) steps per crossing on alpha.6;
- (iii) proving time and peak RAM;
- (iv) the returned `proof_facts` and message hash against `Snip36Verifier`.

If (i) fails or (ii) doubles the chunk, path 1a is closed and the product settles on lots 1-3 (+6).

## 4. Open questions

1. Is PROOF2 (V2 verifier) enabled on Sepolia, and on which date on mainnet? Does Sepolia accept any SNIP-36
   proof meanwhile (gateway default V1 off)? (nv)
2. Does `library_call_syscall` work inside the virtual OS, and at what cost? (CS1, nv)
3. Does the 5 000-felt calldata limit apply to the *virtual* tx? Pile10's 3.2k-felt state fits; a larger
   level would not. (nv)
4. How old may the base block of a proof be (latency of parallel chunks against a moving chain)? (nv)
5. The unit of `max_proof_size` = 480 000, and the typical large-proof size. (nv)
6. `SlingfallSim` Sierra and CASM sizes on alpha.6 (B4 measures them).
7. Will Braavos / Ready sign a dapp-built OutsideExecution through `wallet_signTypedData`? Is Ready's mainnet
   gating still in place, and is Ready staying on Starknet (press reports it moving to Base, nv)?
8. Does AVNU's paymaster execute a payload signed hours earlier? (nv)
9. Will StarkWare open SNIP-36 to third-party circuits (`proof_variant`), which would let an aggregated
   Stwo proof of our executable land directly? (nv)
10. Mainnet L2 gas price at launch, which decides whether 2-6 × 75M L2 gas per shot is acceptable.
11. Re-pin policy for numeric engine changes (grace vs level reset): an owner-level product decision.
