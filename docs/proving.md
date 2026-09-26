# Proving

## Atlantic + Integrity

Lot E3a (2026-09-26): the fallback of `docs/DESIGN.md` D9 (research 01 §4) run end to end on Starknet
Sepolia through Herodotus Atlantic. Tool: `tools/atlantic/atlantic.py` (Python 3 stdlib); the proven
program: `tools/atlantic/c1main`; the committed runs: `fixtures/proofs/<case>.json`.

### What Atlantic offers today (and what the brief assumed)

- **No Stone.** The submit endpoint (`POST /atlantic-query`, OpenAPI of 2026-09-26) accepts
  `sharpProver` = `stwo` | `stwoHerodotus` only; `stone` is rejected (`ZOD_INVALID_BODY_STRING`,
  "Expected 'stwo' | 'stwoHerodotus'"). The docs page "sending-query" still says `stone` is the default:
  it is stale. Every query below ran with `sharpProver = stwo` (the default).
- **L2 verification is a bridged SHARP fact, not an Integrity proof verification.** With
  `result = PROOF_VERIFICATION_ON_L2` the stages are `TRACE_AND_METADATA_GENERATION` →
  `PROOF_GENERATION_AND_VERIFICATION` (SHARP, Stwo, verified on Ethereum Sepolia) → `BRIDGE_FACT_HASH`
  (the keccak fact goes to Herodotus's **Satellite** on Starknet Sepolia,
  `0x00421cd95f9ddabdd090db74c9429f257cb6bc1ccc339278d1db1de39156676e`). With
  `PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION` a `TRANSLATE_FACT_HASH` stage follows: the Satellite's
  `translateFactHash(program_hash, output)` re-derives the keccak fact from the public output and
  registers the Poseidon ("Integrity") fact, reported by `get_all_verifications_for_fact_hash(fact,
  false)` with `security_bits = 96` and settings `'translated'` (Satellite source,
  `HerodotusDev/satellite` `cairo/src/cairo_fact_registry.cairo`). Integrity's own FactRegistry
  (`0x4ce7851f…371b8c`) is still live (Stone6 `recursive_with_poseidon` registrations by third parties on
  2026-09-26) but Atlantic no longer writes to it for us.
- **Layouts.** Submit accepts `auto`, `plain`, `recursive`, `recursive_with_poseidon`,
  `recursive_large_output`, `all_solidity`, `all_cairo`, `dynamic`, `small`, `dex`, `starknet`,
  `starknet_with_keccak`. `auto` resolved to `dynamic` (Atlantic's `optimal_layouts`: `sharp_l1 =
  dynamic`, `integrity_l2 = recursive_with_poseidon`). Integrity verifies `dex`, `recursive`,
  `recursive_with_poseidon`, `small`, `starknet`, `starknet_with_keccak` (not `dynamic` / `all_cairo`);
  irrelevant on the Stwo lane, where Ethereum's SHARP verifier checks the proof.
- **Fields** (OpenAPI names): `declaredJobSize` (required: `XS` | `S` | `M` | `L`), `layout`, `result`,
  `network` (`TESTNET` | `MAINNET`), `cairoVersion` (`cairo1`), `cairoVm` (`rust`), `mockFactHash`,
  `sharpProver`, `pieFile` | `programFile` + `inputFile`, `externalId`, `dedupId`. There is no `chain`
  input field: the response's `chain` (`L2`) follows from `result`.

### Program lanes

| lane | artefact | outcome |
|---|---|---|
| (a) `scarb execute --output cairo-pie --target bootloader` of `slingfall_replay::main` | 44 MB PIE, 9.95M steps | **fails** at trace generation: the scarb PIE is a *simple bootloader running our executable* (a 3 169-felt program declaring all 11 builtins, output `[1, 13, hash, …]`, +7.1M steps hashing the 447 800-felt bytecode). Atlantic bootloads it again and its bootloader has no `add_mod` / `mul_mod`: `select_input_builtins.cairo:36` `DiffAssertValues` (9 of 11 builtins selected), for `auto`, `all_cairo` and `dynamic`. Size S: OOM. `--target standalone` cannot write a PIE. |
| (c) program + input (`programFile` = Sierra, `inputFile` = text) | Sierra of `c1main` | **fails**: `Failed to run cairo1 rust vm: VirtualMachine(Unexpected)`. Atlantic's `cairo1-run` (cairo-vm on `cairo-lang 2.12.0-dev.0`, as upstream) cannot compile Cairo 2.19.4 Sierra: `local_into_box` is unknown to cairo-lang-sierra 2.12. |
| (b) local PIE with Herodotus's cairo-vm fork (the known-issues workaround) | `c1main` Sierra → `cairo1-run --layout all_cairo --append_return_values --cairo_pie_output` | fork as is: same `VirtualMachine(Unexpected)`. **Fork ported to cairo-lang 2.19.4** (`tools/atlantic/cairo-vm-cairo-lang-2.19.4.patch`, 3 API changes): **works**, 12 MB PIE (one_block), 43 MB (pile10), builtins `output, range_check, bitwise, poseidon`. |

`c1main` is `slingfall_replay::main::main` with one `Array<felt252>` argument (the felts of `main`'s two
arguments, `[len(L), L…, len(I), I…]`): `cairo1-run --append_return_values` only runs a `main` taking
and returning `Array<felt252>`. It returns the same 10 felts (checked against the goldens).

Reproduce (from the repository root; the fork and PIEs live in the git-ignored `tools/atlantic/out/`):

```sh
git clone https://github.com/HerodotusDev/starkware-cairo-vm tools/atlantic/out/starkware-cairo-vm
git -C tools/atlantic/out/starkware-cairo-vm checkout da8e48c62ab1383f6d7a410e5d2151033e40b544
git -C tools/atlantic/out/starkware-cairo-vm apply ../../cairo-vm-cairo-lang-2.19.4.patch
cargo +stable build --manifest-path tools/atlantic/out/starkware-cairo-vm/Cargo.toml -p cairo1-run --release
scarb --manifest-path tools/atlantic/c1main/Scarb.toml build
python3 tools/tracec/tracec.py args fixtures/levels/one_block.felts.json --shot=-150,-150 --out args.json
python3 tools/atlantic/atlantic.py c1-input --args args.json --out input.txt
tools/atlantic/out/starkware-cairo-vm/target/release/cairo1-run \
  tools/atlantic/c1main/target/dev/c1main.sierra.json --layout all_cairo --append_return_values \
  --cairo_pie_output pie.zip --args_file input.txt --print_output
python3 tools/atlantic/atlantic.py submit --pie pie.zip --size M --record submit.json
python3 tools/atlantic/atlantic.py status <query-id> --watch
python3 tools/atlantic/atlantic.py fact <query-id> --golden fixtures/golden/one_block-miss.json --args args.json
python3 tools/atlantic/atlantic.py check-fact <integrityFactHash> --keccak <sharpFactHash>
```

### Fact formula

Every step is re-derived by `tools/atlantic/encoding.py` and tested against the committed runs
(`tools/atlantic/test_atlantic.py`, `FactChain`):

1. **Task output** (what `c1main` under `cairo1-run --append_return_values` writes to the output
   builtin): `task = [0, 10, outputs[0..10], len(args), args…]`: the panic flag (0), the returned
   `Array<felt252>` with its length, then the **argument array with its length** (the fork appends the
   input). The proof therefore commits to the level felts and the inputs, not only to the outputs.
   Lengths: 93 felts (one_block, 80 argument felts), 167 (pile10, 154).
2. **Child program hash**: the bootloader's hash of the task program (cairo-lang
   `compute_program_hash_chain`, **Pedersen**): `compute_hash_chain([n + 3 + 4, 0, main = 0, 4,
   'output', 'range_check', 'bitwise', 'poseidon', data…])` over the 454 101 felts of the compiled
   program. `c1main` today: `CHILD_PROGRAM_HASH = 0x128791df23988bef1c8aef3be7ce36ad68278d19878369e5fb7ed2515d5b053`
   (Atlantic's `child_program_hash`; recomputed locally by `atlantic.py program-hash`). It changes with
   any change to the game, the engine, `c1main` or the Cairo compiler.
3. **Bootloader output** (Atlantic's bootloader, `ATLANTIC_BOOTLOADER_PROGRAM_HASH =
   0x288ba12915c0c7e91df572cf3ed0c9f391aa673cb247c5a208beaa50b668f09`, a 728-felt program):
   `output = [0, pedersen(0, 0), 1, len(task) + 2, CHILD_PROGRAM_HASH, task…]`; `pedersen(0, 0) =
   0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804` (the first two felts are the
   bootloader's configuration; the same in every query).
4. **SHARP fact** (Ethereum, bridged to the Satellite as a u256): `keccak(ATLANTIC_BOOTLOADER_PROGRAM_HASH
   ‖ keccak(output))`, 32-byte big-endian words (`sharpFactHash`).
5. **Integrity fact** (registered by translation, what a Starknet contract checks):
   `fact = poseidon(SHARP_BOOTLOADER_PROGRAM_HASH, poseidon(1, len(output) + 2,
   ATLANTIC_BOOTLOADER_PROGRAM_HASH, output…))` with Integrity's constant `SHARP_BOOTLOADER_PROGRAM_HASH =
   0x5ab580b04e3532b6b18f81cfa654a05e29dd8e2352d88df1e765a84072db07`, i.e. Integrity's
   `calculate_bootloaded_fact_hash(SHARP_BOOTLOADER_PROGRAM_HASH, ATLANTIC_BOOTLOADER_PROGRAM_HASH, output)`
   (`integrityFactHash`). The D9 shape `poseidon(PROGRAM_HASH, output_hash)` holds with
   `PROGRAM_HASH = SHARP_BOOTLOADER_PROGRAM_HASH` and `output_hash` the Poseidon of the doubly
   bootloaded output.

### Contract side (E3b): `IntegrityVerifier::check(outputs, evidence)`

Constants: `CHILD_PROGRAM_HASH` (step 2, pinned per release of the proven program),
`ATLANTIC_BOOTLOADER_PROGRAM_HASH`, `SHARP_BOOTLOADER_PROGRAM_HASH`, `PEDERSEN_0_0`, the Satellite address
(Sepolia above; mainnet `0x01ba7d4b5707f8878c22fb335763abfc26c2ae157c434d597f6416fe6a79bf2e`, from
Integrity's `lib_utils.cairo`).

1. Inputs: `outputs` (the 10 felts of `Outputs`), `level` felts and `inputs` felts (calldata, D9 "full
   inputs go in calldata"); `evidence` is empty on this lane (the fact is recomputed, nothing to trust
   from the caller).
2. Bind: `level_hash == poseidon_hash_span(level)`, `inputs_hash == poseidon_hash_span(inputs)` (the
   contract already does this for the nullifier) and `outputs.player == caller`.
3. Recompute `args = [len(level), level…, len(inputs), inputs…]`, `task = [0, 10, outputs…, len(args),
   args…]`, `output = [0, PEDERSEN_0_0, 1, len(task) + 2, CHILD_PROGRAM_HASH, task…]`, then
   `fact = poseidon(SHARP_BOOTLOADER_PROGRAM_HASH, poseidon_hash_span([1, len(output) + 2,
   ATLANTIC_BOOTLOADER_PROGRAM_HASH, output…]))` (Integrity's `calculate_bootloaded_fact_hash`).
4. Check: `ISatellite.get_all_verifications_for_fact_hash(fact, is_mocked = false)` has an element with
   `security_bits >= 96`, **and** its `verifier_config` is `'translated'` ×4 (the only kind Atlantic
   produces now) or, if Stone verifications come back one day, the expected Integrity settings
   (`recursive_with_poseidon` / `keccak_160_lsb` / `stone6` / `strict`, verifier config hash from
   `get_verifier_config_hash`). Simpler equivalent: `isCairoFactValid(fact, false)` (the Satellite
   requires 96 bits for FactRegistry facts and accepts translated ones). Interface (Integrity package
   `IFactRegistryWithMocking`):
   `get_all_verifications_for_fact_hash(fact_hash: felt252, is_mocked: bool) -> Span<VerificationListElement>`,
   `VerificationListElement { verification_hash, security_bits: u32, verifier_config:
   VerifierConfiguration { layout, hasher, stone_version, memory_verification } }`.
5. Cost: one Poseidon over ≈ `len(level) + len(inputs) + 20` felts (≈ 110 for one_block, ≈ 180 for
   pile10) plus one contract call; no proof bytes in calldata.

Trust: the fact rests on Ethereum's SHARP verifier plus Herodotus's L1 → L2 bridge and Satellite owner
(the Satellite is upgradeable), not on an on-chain Starknet verification of the proof.

### Client / service flow

1. The client plays the level with the browser VM (same Cairo) and gets the 10 outputs.
2. A **prover service** (ours; it holds the Atlantic API key, never the browser) receives `(level id,
   inputs)`, re-runs `cairo1-run` on `c1main` (5-10 s), checks the outputs, submits the PIE with
   `result = PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION`, `declaredJobSize = M` (L for ≥ 9M-step runs),
   `dedupId` = hash of the inputs (idempotent retries), and polls `GET /atlantic-query/{id}` until `DONE`.
3. The service returns `integrityFactHash` (the client can recompute it offline with the formula above)
   and the query id; the client polls `check-fact` (a view call) until the Satellite knows the fact.
4. The player sends `submit(level, inputs, outputs)` from their wallet; the contract recomputes and
   checks the fact (above). Nothing Atlantic-specific is signed by the player.

### Runs, latency, cost

See `fixtures/proofs/<case>.json` and the lot's `REPORT.md` for the per-stage timings. Costs: testnet
queries are free (Atlantic pricing: S 70 credits, M 120, L 220 on mainnet, trace generation 1 credit per
started minute, L2 mainnet verification 25 credits); the job-size tier that works for our program is
**M** for one_block (S is OOM-killed at trace generation: the bootloaded run is 6.3M steps, 3.6M of them
Pedersen-hashing the 454k-felt program) and **L** for pile10 (M is OOM-killed).
