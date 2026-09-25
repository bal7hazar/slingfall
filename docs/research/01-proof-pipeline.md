# R1 — Proof pipeline: from a Cairo executable to an on-chain validation on Starknet

Date: 2026-09-25. Author: R1 research sub-agent (claude CLI, Opus 5.5) for the project-manager session.
Scope: research only, no repository changed. Conventions: `(source)` = figure taken from a cited
document or from a rapier-cairo measurement file; `(est.)` = my estimate; figures without a tag
were observed by me on this VPS today.

## Executive summary

On Starknet today, the production path for proving work done off-chain and checking it on-chain is
**not** "`scarb prove` + a verifier contract". It is **SNIP-36 in-protocol proof verification**
(Starknet v0.14.2, mainnet since 2026-04-20). A Starknet transaction is executed off-chain in a
"virtual OS" and proven with S-two (Stwo). The resulting proof and its `proof_facts` are attached
to a normal Invoke V3 transaction, and the sequencer verifies them natively. A contract reads the
facts through `get_execution_info_v3_syscall` and trusts the L2→L1 messages the virtual execution
emitted. SNIP-36 proves only Starknet transaction executions, not arbitrary `#[executable]`
programs. So the game's physics should run as a **contract entry point**: rapier-cairo's crates
already compile with gas enabled for snforge. The executable remains useful for local tests.
Starknet v0.14.4 (Sepolia 2026-09-15, mainnet 2026-10-05 pending governance) raises provable
transactions to **1.1B L2 gas**. That cap, not prover RAM, becomes the level budget.

With today's rapier marginals (~6M Sierra gas and ~48k Cairo steps per awake contacting body per
tick, 4 substeps), 1.1B gas is ~180 body-ticks. A 20-body, 200-tick level exceeds that 5-50×, so a
level must either be shrunk (fewer substeps, 30 Hz, sleeping, optimisation lots) or proven as a
chain of chunked transactions.

The fallback that already works for arbitrary Cairo executables is **Stone + Herodotus Integrity**
(fact registry on Sepolia and mainnet), most easily reached through the **Atlantic** service
(~$0.70–2.20 per proof, free on testnet). Local `scarb prove` is useful for development only. It
carries a soundness disclaimer, has no Starknet verifier for its output, and on this VPS it is
blocked by an unexplained memory floor that the first experiment must measure.

---

## 1. Local proving with Stwo through scarb 2.19.x

### What is installed and what it does

| item | value |
|---|---|
| `scarb --version` | `scarb 2.19.4 (b45b74c03 2026-07-21)`, cairo 2.19.4, sierra 1.9.3 |
| prover binaries | `scarb-prove`, `scarb-verify`, `scarb-execute` under `~/.asdf/installs/scarb/2.19.4/bin/` |
| `scarb prove` flags (read from the binary's strings; `--help` needed an approval I could not get, and the `scarb` shim was held by the machine-wide lock for >2 min) | `--execution-id <N>` (prove a saved `scarb execute` run) or `--execute` plus the execute flags (`--arguments`, `--arguments-file`, `--executable-name`, `--executable-function`, `--print-program-output`, `--print-resource-usage`, `--save-profiler-trace-data`); target kinds `standalone` / `bootloader` / `cairo-pie`. **No memory, chunking or prover-parameter flag was found.** |
| embedded prover | stwo-cairo; the binary contains `PreProcessedTrace::canonical` and `canonical_small`, `blake2s` / `poseidon252` Merkle channels, and Pedersen tables |
| output | `target/execute/<target>/execution<N>/proof.json` (source: Scarb docs) |
| official caveats | "Soundness of the proof is not yet guaranteed by Stwo, use at your own risk". Prebuilt binaries are slower than a `RUSTFLAGS="-C target-cpu=native"` build, and for production the docs say to use `stwo-cairo` directly (source: Scarb docs) |
| security parameters | 96 bits of conjectured soundness, `pow_bits=26`, `log_blowup_factor=1`, `n_queries=70` (source: stwo-cairo README). SHARP's L1 verifier: 96 bits + 30 PoW bits (source: L2BEAT) |
| repository | stwo-cairo moved to `starkware-libs/proving` at the end of July 2026; S-two 2.0.0 released 2026-01-27 on crates.io (source) |

### Builtins

| builtin | Stwo-Cairo AIR | SNIP-36 virtual OS | used by rapier `ball_drop` |
|---|---|---|---|
| output | yes | yes | yes (10 cells) (source: rapier README) |
| range_check (+ range_check96) | yes | yes | yes (760 for 1 tick) (source) |
| bitwise | yes | yes | yes (33 for 1 tick) (source) |
| pedersen | yes (preprocessed tables) | yes | no |
| poseidon | yes | yes | no (a `inputs_hash` will need it) |
| ec_op | yes | yes | no |
| add_mod / mul_mod | yes | **excluded** in phase 1 | no |
| keccak | **not listed** among the Stwo-Cairo components | **excluded** | no; do not use it |

(source: stwo-cairo README component list; SNIP-36 forum post)

### Proof size, time and memory

| data point | steps | prover input | proof | time | memory | source |
|---|---:|---:|---:|---:|---:|---|
| rapier `ball_drop`, 1 tick | 19,587 (README) / 4,781 (PLAN) | 105 MB | none | none | **OOM-killed above a 22 GB cgroup cap**; `memory.address_to_id` = 2.7M cells | (source: rapier README, docs/PLAN.md) |
| rapier `ball_drop`, 10 ticks | 143,976 | – | – | execute 23 s wall incl. startup | – | (source: rapier README) |
| rapier `ball_drop`, 60 ticks | 1,578,926 | – | – | execute 28 s | – | (source: rapier README) |
| broody/vdf 512-bit, scarb 2.18 | 8,491,007 | ~660 MB | ~590 MB `proof.json` | ~90 s | fits in a 64 GB box | (source: github.com/broody/vdf, "historical, pre-optimisation") |
| SNIP-36 small proof | small virtual block | – | ~500 KB used as the fee example | 3–5 s | – | (source: SNIP-36; v0.14.4 notes) |
| SNIP-36 large proof (≤ 1.1B L2 gas) | ~9M Cairo steps (est.) | – | – | 1–2 min | – | (source: v0.14.4 notes; steps est.) |

Scaling laws (est.):

- **Time.** Stwo proving is quasi-linear in the padded trace length: each component is padded to a
  power of two. The VDF point gives ~10 µs per Cairo step, i.e. ~1.1 min per 8.5M steps on a 64 GB
  box with the prebuilt binary. A native build should be ~1.5–3× faster (est.).
- **Memory.** Also linear in the padded trace. From the VDF point, ~64 GB proves ~8.5M steps, so
  the rule of thumb is **~7 GB per million steps**, giving ~8M steps on 64 GB and ~16M steps on
  128 GB (est.).
- **The rapier data point contradicts this.** 20k steps needing more than 22 GB implies a large
  **fixed floor**. The 105 MB prover input (vs 660 MB for 8.5M steps) and the 2.7M memory cells for
  ~5–20k steps point at program size, i.e. the heavily inlined rapier bytecode in the memory
  segment, and/or the canonical preprocessed trace with Pedersen tables, rather than at the step
  count. Unmeasured; experiment E1 below separates the two.
- **Proof size.** A STARK proof grows with log(trace); a binary Stwo proof is hundreds of KB (est.;
  SNIP-36 uses 500 KB as its example). The `scarb prove` `proof.json` is a verbose JSON (590 MB in
  the VDF point) and is **not** an on-chain format.
- **Chunking.** `scarb prove` has no continuations. Proving beyond one machine's RAM needs
  application-level chunking: the executable proves ticks `[a, b)` from a committed state hash to
  the next one. Herodotus has written about Cairo continuations (March 2026), but no scarb
  integration was found.

## 2. On-chain verification on Starknet

| verifier | what it verifies | networks | status (2026-09) | cost of one verification | program binding and public output |
|---|---|---|---|---|---|
| **SNIP-36 in-protocol S-two verification** (Starknet sequencer / gateway, Rust verifier) | S-two proof of a **Starknet transaction** executed in the virtual OS (program hash `0x53f6c9fc…6daa1`, snip36 backend v1.2.5) | mainnet since v0.14.2 (2026-04-20); Sepolia; v0.14.4 large proofs: Sepolia 2026-09-15, mainnet 2026-10-05 pending | production, in protocol; used by STRK20 privacy. SNIP text was still "Draft" in Feb 2026. v0.14.3 proofs are rejected by v0.14.4, so **the proof format is versioned per Starknet release**. Audit status unknown | 125 L2 gas per proof byte + 5 L2 gas per byte for storage + 10M L2 gas reserved; **500 KB proof ≈ 75M L2 gas** (source). At the 3 gFri minimum L2 gas price that is **≈ 0.23 STRK** (est.) + the game logic | `proof_facts` = (virtual OS program hash, reference block hash, L2→L1 message hashes). The contract reads them with `get_execution_info_v3_syscall().tx_info.proof_facts`; the raw messages travel in calldata and are hashed and compared. Output = message payload, e.g. `(level_id, seed, inputs_hash, score, won, player)`, with `from_address` = the game contract |
| **Herodotus Integrity** | Stone proofs (Stone5 / Stone6) of Cairo 0 **and Cairo 1** programs; layouts dex, recursive, recursive_with_poseidon, small, starknet, starknet_with_keccak; hashers keccak / blake2s | Sepolia (FactRegistry `0x4ce7851f…371b8c`) and mainnet (FactRegistry `0xcc63a1e8…4f00b`), 12 verifier contracts each | in production use (Atlantic L2 target); Stwo support "next" / planned, **no evidence it shipped**; audit status not published | not published. Monolith proof in one tx when it fits, otherwise "split proof" across several txs (calldata and steps limits). Atlantic charges $0.25 per mainnet verification, testnet free (source) | `fact_hash = poseidon(program_hash, output_hash)`; `verification_hash = poseidon(fact_hash, security_bits, settings)`. The game contract recomputes the fact from `PROGRAM_HASH` and the claimed outputs, then asks the registry for verifications with ≥ 96 security bits |
| **stwo_cairo_verifier** (Cairo code in stwo-cairo / `starkware-libs/proving`) | Stwo proofs, inside the Cairo VM (recursion, aggregation) | no deployed Starknet contract found | used inside SHARP; not packaged as a contract; a Stwo proof is "tens of thousands of felts" vs a 5K-felt tx calldata limit (source: SNIP-36) | a direct contract call does not fit one tx (source); as the payload of a SNIP-36 virtual tx it might, unmeasured | would have to be built by us |
| SHARP / Stwo GPS verifier on Ethereum `0x4956bda1…72b6` | bootloaded Cairo programs, Starknet OS | Ethereum L1 only | production | L1 gas | L1 fact registry; irrelevant to a Starknet game |
| stwo-gnark-verifier (Herodotus) | Stwo → Groth16/Plonk wrap | EVM | experimental | – | – |

Conclusion for question 2: **there is no deployed contract on Starknet that verifies a
`scarb prove` proof of a standalone executable.** What exists is (a) SNIP-36 for proofs of Starknet
transactions, which is production and cheap, and (b) Integrity for Stone proofs of arbitrary
Cairo 1 programs, which is production.

## 3. Prover services

| service | prover | inputs | Starknet verification | price | latency | limits / caveats |
|---|---|---|---|---|---|---|
| **Herodotus Atlantic** | SHARP, `sharpProver`: `stone` (default) or `stwo` | Cairo 0/1 program + input, or a `pie.zip` | `PROOF_VERIFICATION_ON_L2` via Integrity (**Stone only**); **S-two jobs are L1-only** today | job size S (0–13M steps) 70 credits ≈ $0.70, M (13–30M) ≈ $1.20, L (>30M) ≈ $2.20; trace generation $0.01 per started minute; L2 mainnet verification $0.25; **testnet free and unlimited** (source) | not published (est.: minutes for Stone on 10–100M steps) | Cairo 1 lane: programs combining **`Felt252Dict` with extra builtins** fail at trace generation until upstream PR #2389 lands (workaround: build the PIE locally with Herodotus's cairo-vm fork). rapier uses `Felt252Dict` (arena, union-find, islands, body store) together with bitwise, so it is **likely affected**. Public output capped at ~3,700 felts. Integrity cannot verify `dynamic` / `all_cairo` layouts directly |
| **SNIP-36 proving** (`snip36 prove virtual-os`, starknet-innovation/snip-36-prover-backend v1.2.5; `starknet_proveTransaction` JSON-RPC in the sequencer's `starknet_os_runner`) | S-two | a Starknet Invoke tx + an RPC node (reference block) | native (SNIP-36) | free software; the prover's hardware cost is ours | 3–5 s small, 1–2 min large (source) | pins scarb / Cairo **2.15.0** and sncast 0.60.0; ~10 GB disk; prebuilt Linux x86_64/arm64 binaries and Docker images. RAM for large proofs not published (est. 32–64 GB). Whether rapier's Sierra 1.9.3 (Cairo 2.19.4) classes can be declared and virtual-executed needs checking |
| Sigillo (hosted SNIP-36 proving, forum proposal) | S-two | – | SNIP-36 | not priced | – | prototype |
| StarkWare SHARP directly | Stwo | bootloaded jobs | L1 fact registry | not self-serve | – | reached through Atlantic |
| Client-side proving (stwo-cairo-ts, Wasm64 in the browser) | Stwo | compiled executable + arguments | produces a Stwo proof; no Starknet verifier for it outside SNIP-36 | – | – | needs Memory64 and COOP/COEP headers; RAM-bound. FibRace (2025): ≥ 3 GB for small programs on phones (source) |

## 4. Fallback paths

What counts as "Stwo on Starknet" matters. SNIP-36 is Stwo on Starknet and it is production. What
is not ready is Stwo verification of **arbitrary executables**. Ranked fallbacks if SNIP-36 does
not fit (tx gas cap, versioning churn, tooling gaps):

| rank | path | trust | cost / latency | why this rank |
|---|---|---|---|---|
| 1 | **Stone + Integrity via Atlantic** (arbitrary Cairo 1 executable; fact registry on Starknet) | trustless (Stone proof, Integrity contract; Herodotus operates the service, but verification is on-chain) | ~$1–2.5 per level (source); latency minutes (est.); testnet free | works today for executables of any size (L tier >30M steps); binds `program_hash` + output. Risk: the `Felt252Dict` trace-generation bug, Stone slowness |
| 2 | **Off-chain Stwo verification + on-chain attestation**: the project's server runs `scarb verify` (or the Rust verifier) and signs `(level_id, seed, inputs_hash, score, won, player)`; the contract checks the signature. Optional upgrade: optimistic mode with a challenge window | trusted server (a key) | ~0 on-chain beyond one signature check; seconds | cheapest and simplest; right for a testnet MVP or a dev mode, wrong as the end state |
| 3 | **Recursive aggregation**: verify N Stwo proofs (chunks of a level, or many players' levels) with `stwo_cairo_verifier` inside one SNIP-36 virtual tx, or via SHARP to L1 | trustless | one on-chain proof per batch; engineering heavy | research-grade; only worth it if chunked levels × players make per-tx fees dominate |

## 5. Budget model for a level

### Inputs (all from rapier-cairo, `docs/BUDGETS.md` and the example README, 2026-09-22/25)

| quantity | Sierra gas | Cairo steps | source |
|---|---:|---:|---|
| free-fall body, per tick (4 substeps) | 0.50M | 4.3k | (source: BUDGETS marginals, current) |
| ball on ground, per contact body | 3.4M | 26k | (source) |
| cuboid in a stack, per box (2 points) | 4.3M | 34k | (source) |
| mixed pile of 8 (15 pairs, 20 points) | 48.1M | 382k → **~48k per body** | (source) |
| box stack of 3 | 12.8M (11.7M in the brief) | 105k | (source) |
| sleeping body | not measured; assume ≤ 1k steps, ≤ 0.1M gas | – | (est.) |
| gas per Cairo step in contact scenes | ~125 | – | (est., from the rows above) |

Note that the brief's "4 781 Cairo steps for one tick of one ball" disagrees with the example
README (19,587 for 1 tick including scene setup; ~14.4k per tick over 10 ticks; 4.3k per free-fall
body in BUDGETS). I use the BUDGETS marginals.

### Level scenarios (one shot; "awake" = average number of awake, contacting bodies per tick)

| scenario | bodies | ticks | avg awake | Cairo steps / tick | **Cairo steps / level** | **Sierra gas / level** |
|---|---:|---:|---:|---:|---:|---:|
| S (small, sleeping works) | 20 | 200 | 8 | ~400k | **~80M** | **~10B** |
| M | 40 | 250 | 15 | ~740k | **~185M** | **~23B** |
| L (large, everything awake) | 60 | 300 | 60 | ~2.9M | **~870M** | **~110B** |
| S', S retuned: 1 substep instead of 4 (solver ≈ 81 % → assume ÷2.5), 30 Hz (100 ticks) | 20 | 100 | 8 | ~160k | **~16M** | **~2B** |
| target for one SNIP-36 tx | – | – | – | – | ≤ ~9M | **≤ 1.1B** |

All level rows are (est.). Assumptions: the level starts asleep (pre-settled); game rules, input
hashing and output cost < 5 %; Sierra gas is charged worst-branch (branch_align), so gas overstates
the executed path, which is what the prover pays (rapier PLAN finding, 2026-09-21).

### Proving and on-chain cost per path (est.)

| path | S (~80M steps / 10B gas) | M (~185M / 23B) | L (~870M / 110B) |
|---|---|---|---|
| local `scarb prove`, 64 GB, chunks of ~8M steps at ~10 µs/step | 10 chunks, ~13 min | 23 chunks, ~31 min | 110 chunks, ~2.4 h |
| local `scarb prove`, 128 GB, chunks of ~16M steps | 5 chunks, ~13 min (time is linear, RAM only sets chunk size) | 12 chunks, ~31 min | 55 chunks, ~2.4 h |
| proof size | ~0.3–1 MB binary per chunk; `proof.json` far larger | same | same |
| SNIP-36, chunks of ≤ 1.1B gas | ~9 proven txs, ~1.5 min each, ~0.25 STRK each → **~2.3 STRK** | ~21 txs, ~5 STRK | ~100 txs, ~25 STRK: unacceptable |
| SNIP-36, retuned S' | **2 txs, ~0.5 STRK** | – | – |
| Atlantic Stone + Integrity, one job | L tier $2.20 + $0.25 | L tier (if SHARP accepts the size) | likely beyond practical Stone job sizes |

The memory figures depend on the VDF data point, and the rapier fixed-floor anomaly could shift
them. E1 settles this.

**Budget rule proposed for level design:** one shot ≤ **1.1B Sierra gas**, i.e. ≤ ~180
awake-body-ticks at today's cost, or ~450 after the substep / Hz retune. Treat anything above as a
multi-transaction level.

## 6. Recommended architecture for the MVP

### Who proves

For the MVP, the **project's prover server** (one 64 GB machine) runs the SNIP-36 prover on
request. The player's client sends `(level_hash, inputs)`, receives `proof` + `proof_facts` +
`raw_messages`, and submits the transaction from the player's own account. The server is untrusted
for correctness: it can only refuse service. Once proof RAM for one level is known to be ≤ 4–8 GB,
**client-side proving** (stwo-cairo in Wasm64, or native in a desktop client) is the next step.

### Which verifier

**SNIP-36** (primary), on Sepolia first, since v0.14.4's large-proof support is live there as of
2026-09-15. **Integrity via Atlantic** is kept as the fallback for levels that exceed the per-tx
gas cap and for arbitrary-executable proofs.

### Contracts

```
PhysicsLevels (one contract, or two: Registry + Game)
  storage
    levels: Map<level_hash, LevelMeta { author, data_ptr/level blob, par, active }>
    best:   Map<(player, level_hash), Record { score, won, inputs_hash, block }>
    used:   Map<(player, level_hash, inputs_hash), bool>           // replay protection
    virtual_os_hash: felt252   (admin-updatable: proofs are versioned per Starknet release)
  register_level(level_blob) -> level_hash                         // hash = poseidon(blob)
  simulate(level_hash, inputs) -> ()                               // run ONLY in the virtual OS:
      reads the level from storage, runs rapier2d::World::step for N ticks + game rules,
      emits send_message_to_l1(to = MARKER, payload = [level_hash, seed, inputs_hash,
      score, won, player = get_caller_address()])
  submit(raw_message) -> ()                                         // real tx carrying the proof
      facts = get_execution_info_v3().tx_info.proof_facts
      assert facts.program_hash == virtual_os_hash
      assert poseidon(from = this, to = MARKER, payload) ∈ facts.message_hashes
      assert facts.block_hash is a known recent block                // optional freshness
      assert payload.player == get_caller_address()                  // anti front-running
      assert !used[(player, level, inputs_hash)]; used[...] = true
      update best / leaderboard; emit LevelValidated
```

The seed is derived deterministically (for example `poseidon(level_hash, player, attempt_nonce)`)
inside `simulate`, never chosen by the client. The `simulate` path needs no `rapier_starknet` state
packing: the world lives in memory for the duration of the virtual tx.

For long levels, split into chunks: `simulate_chunk(session, state_in_hash, ticks) -> message(
session, state_in_hash, state_out_hash)`, with `submit` chaining the hashes and accepting the last
chunk's score. The same design applies to the Integrity fallback, with
`fact = poseidon(PROGRAM_HASH, output_hash)` checked against the FactRegistry instead of
`proof_facts`.

### The three cheapest experiments to run first

| # | experiment | answers | hardware | cost / time (est.) |
|---|---|---|---|---|
| E1 | `scarb prove` on a **rented 64 GB box** (e.g. Hetzner dedicated / hourly cloud): (a) a trivial `fib` executable, (b) `ball_drop` 1 / 10 / 60 ticks, (c) `box_stack3` 10 ticks; `/usr/bin/time -v` for peak RSS, wall time, `proof.json` size, `scarb verify`; repeat (b) with scarb-prove built with `target-cpu=native` | the fixed memory floor vs per-step slope (program size or preprocessed trace?), the time law, milestone M3 "one step proven and verified" off-chain | 64 GB, 8–16 cores, ~2 h | < €10 |
| E2 | **SNIP-36 round trip on Sepolia**: a minimal contract whose `simulate(scene, ticks)` calls `rapier2d::World::step` (1, 10, 60 ticks of `ball_drop`) and emits the result message; prove with `snip36 prove virtual-os`, submit, consume `proof_facts` in `submit` | whether Cairo 2.19.4 / Sierra 1.9.3 classes work in the virtual OS, actual proof size, fee, proving time and RAM vs gas; confirms the architecture | VPS for the contract; the prover first on the VPS under a 20 GB cap, else on the E1 box | a Sepolia faucet; 1–2 days of an executor |
| E3 | **Atlantic Stone + Integrity on Sepolia** (free): submit `ball_drop` (1 and 10 ticks) with `PROOF_VERIFICATION_ON_L2`, layout `auto` / `recursive`; if trace generation fails on `Felt252Dict`, build the PIE locally with Herodotus's cairo-vm fork; then read the fact with `poseidon(program_hash, output_hash)` from a Sepolia test contract | the fallback path end to end, latency, the exact output layout of a scarb executable (panic flag / length prefix) in the fact | this VPS only (network calls) | free; half a day |

## Recommendation

1. **Adopt SNIP-36 as the target verifier.** Run the level logic as a contract entry point executed
   in the virtual OS. `scarb prove` of a standalone executable stays a development tool. Owner
   decision for `decisions/PENDING-proving-hardware.md`: rent a 64 GB machine by the hour for E1
   and E2 rather than buy one; the 128 GB tier only helps if E1 shows a large fixed floor.
2. **Make 1.1B Sierra gas per shot the level budget** and send it to the rapier orchestrator with
   G0. The scene should measure Sierra gas **and** Cairo steps per tick for substeps = 1, 2 and 4.
   Priority optimisation lots: solver sweeps (81 %), sleeping of settled structures, the O(n²)
   `find_pairs`.
3. **Keep Stone + Integrity via Atlantic as the fallback.** Run E3 in parallel because it is free.
4. **Revisit `rapier_starknet`**: it is still not needed (no persistent world), but the game crate
   must compile as a Starknet contract with gas enabled, not only as an `#[executable]`.
5. Update PLAN phase C: the proof pipeline item becomes "SNIP-36 round trip on Sepolia" (E2), and
   "a proven step" is E1.

## Open uncertainties

| # | uncertainty | effect | how to resolve |
|---|---|---|---|
| U1 | why one rapier tick OOMs above 22 GB while an 8.5M-step VDF proof fits in 64 GB | could make local and client proving impractical, or be a trivial fix (bytecode size, preprocessed-trace variant) | E1 |
| U2 | RAM and time of the SNIP-36 **large** prover for ~1B gas; whether a public proving endpoint exists | server sizing | E2 |
| U3 | whether classes compiled with Cairo 2.19.4 / Sierra 1.9.3 can be declared on Sepolia and run in the virtual OS (the backend pins 2.15.0) | E2 might need a compiler downgrade of the game crate | E2, day 1 |
| U4 | how long the 1.1B L2 gas cap and the proof format stay stable (v0.14.3 proofs rejected by v0.14.4) | admin-updatable `virtual_os_hash`; re-prove on upgrades | follow Starknet release notes |
| U5 | Integrity verification gas and number of transactions for a split proof; audit status of Integrity and of SNIP-36 | fallback cost | E3; ask Herodotus |
| U6 | the `Felt252Dict` + bitwise trace-generation bug on Atlantic's Cairo 1 lane | E3 might need the local-PIE workaround | E3 |
| U7 | sleeping-body cost and the real average awake count of a shot | the level budget could be off by 2–5× | G0 scene |
| U8 | I could not run `scarb prove/verify/execute --help` (approval needed; shim lock held); flags were read from the binary | a missed flag, e.g. a preprocessed-trace variant switch | run `--help` once the lock is free |
| U9 | the 4,781 vs 19,587 Cairo steps per tick discrepancy between PLAN and the example README | only the headline figure | ask the rapier orchestrator |
| U10 | STRK price, and whether SNIP-36 proof-carrying txs can be sponsored (paymaster) | player UX | later |

## Sources

- Scarb docs, prove and verify: https://docs.swmansion.com/scarb/docs/extensions/prove-and-verify.html (read 2026-09-25)
- stwo-cairo README and CLAUDE.md: https://github.com/starkware-libs/stwo-cairo ; development moved to https://github.com/starkware-libs/proving (July 2026)
- S-two 2.0.0 (2026-01-27): https://starkware.co/blog/s-two-2-0-0-prover-for-developers/
- Recursive circuit proving (2026-03-31): https://starkware.co/blog/minutes-to-seconds-efficiency-gains-with-recursive-circuit-proving/
- S-two live on Starknet mainnet (2025-11-03): https://www.starknet.io/blog/s-two-is-live-on-starknet-mainnet-the-fastest-prover-for-a-more-private-future/
- Stwo proving record: https://starkware.co/blog/starkware-new-proving-record/
- L2BEAT Stwo verifier: https://l2beat.com/zk-catalog/stwo
- SNIP-36, in-protocol proof verification (forum, Feb 2026): https://community.starknet.io/t/snip-36-in-protocol-proof-verification/116123
- Starknet v0.14.2 (mainnet 2026-04-20): https://www.starknet.io/blog/starknet-v0-14-2-the-privacy-engine-arrives/
- Starknet v0.14.4 prerelease notes (Sepolia 2026-09-15, mainnet 2026-10-05 pending): https://community.starknet.io/t/starknet-v0-14-4-prerelease-notes/116341
- SNIP-36 prover backend (v1.2.5, status 2026-08-10): https://github.com/starknet-innovation/snip-36-prover-backend
- Sigillo hosted SNIP-36 proving: https://community.starknet.io/t/sigillo-hosted-snip-36-proving-compliance-templates-for-strk20/116173
- Starknet fees: https://docs.starknet.io/learn/protocol/fees
- Herodotus Integrity: https://github.com/HerodotusDev/integrity and `deployed_contracts.md` in that repository
- Atlantic: https://docs.herodotus.cloud/atlantic-api/introduction , `/atlantic-api/stwo`, `/atlantic-api/sending-query`, `/atlantic-api/dynamic`, `/atlantic-api/known-issues`, `/atlantic-api/steps/l2-proof-verification`; pricing: https://www.herodotus.cloud/pricing.md
- broody/vdf (scarb execute/prove figures): https://github.com/broody/vdf
- stwo-cairo-ts: https://github.com/clealabs/stwo-cairo-ts ; FibRace: https://arxiv.org/pdf/2510.14693
- stwo-gnark-verifier: https://pkg.go.dev/github.com/HerodotusDev/stwo-gnark-verifier
- Local: `rapier-cairo/examples/ball_drop/README.md`, `rapier-cairo/scripts/prove-example.sh`, `rapier-cairo/docs/PLAN.md` (lines 276–345), `rapier-cairo/docs/BUDGETS.md` (lines 40–99)
