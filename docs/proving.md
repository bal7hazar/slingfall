# Proving a level locally (Stwo, lot P1)

Local proofs of the replay executables (`crates/slingfall_replay`, `docs/DESIGN.md` D1) use
stwo-cairo's own `run_and_prove` on the **standalone executable**, with the `canonical_small`
preprocessed trace (research 05, spike E1L). `scarb prove` is not used: it proves only the
bootloader target, which adds ~6.6M Cairo steps (the Blake2s hash of the 414k-felt bytecode)
before any physics. On-chain verification is D9's business, not this tool's: see
"What a verifier must check" below.

## Set up

```sh
tools/prove/setup.sh [--native]
```

The script clones `starkware-libs/stwo-cairo` at rev **`467d5c6`** into `tools/prove/vendor/`
(git-ignored) and applies two patches. It builds `run_and_prove`, `prove` and `verify`
(`cargo build --release -j 4 -p stwo-cairo-dev-utils`) and prints the binaries' directory.

- The toolchain comes from the clone's `rust-toolchain.toml` (`nightly-2025-06-23`); rustup
  installs it.
- The build takes ~10 min cold on 4 cores and ~1 min after a patch change. A stamp file makes
  the script a no-op when the binaries are up to date.
- `--native` adds `-C target-cpu=native` for local runs. Never use it for a build that CI caches:
  the next runner may have another CPU.

The two patches:

| patch | why |
|---|---|
| `vm_utils-standalone-context.patch` | `adapt()` hardcodes the bootloader's 11 builtins; a scarb 2.19 standalone entry point declares only its own (`output`, `range_check`, `bitwise`, `poseidon` for `main`). Without the patch, every standalone proof fails verification (the verifier reads program memory as the ECDSA segment). Public-input metadata only. |
| `verify-proof-format.patch` | `verify` at this rev reads JSON proofs only. The patch adds `--proof_format json|binary`, and `verify` prints `VERIFICATION_OUTPUT {"program_hash", "output"}` (stwo's `get_verification_output`) before verifying. |

The replay executables come from `scarb --manifest-path crates/slingfall_replay/Scarb.toml build`.

## Prove a level

```sh
python3 tools/prove/prove.py --case one_block-miss --out out/ob           # a golden case, whole
python3 tools/prove/prove.py --level pile10 --shot=-604,-392 --out out/p  # any shots
python3 tools/prove/prove.py --case pile10-reference --chunks 2 --out out/p2   # chunked
```

Every proof is one `run_and_prove --program_type executable --params_json
tools/prove/params.canonical_small.json --proof-format binary --verify`. It runs under
`measure.py` (wall time, the child's peak RSS, the cgroup's sampled peak), one proof at a time.
The arguments are encoded as `tools/tracec` encodes them (`[len(L), L…, len(I), I…]`, `0x` felts).

- **Whole**: one proof of `main(level, inputs)`. Its public output is `[10, outputs…]`, the D4
  felts.
- **Chunked** (`--chunks N`, or `--k K`): proofs of `init(level)`, then
  `step_chunk(state, inputs, shot, K, 0)` until each shot is over, then `outputs(state, inputs)`.
  - Each proof's public output is its binding header, then the state it returns (the 10 felts
    for `outputs`): see "Chunk binding". The next proof runs on the state.
  - `--chunks N` sets K = ceil(ticks_run / N). `ticks_run` comes from the golden with `--case`,
    otherwise from one `scarb execute` of `main`.
  - A one-shot level gives N `step_chunk` proofs. A multi-shot level can give more, because a
    chunk never crosses a shot's end.

`--out` receives:

- the proofs (`*.proof.bin`, ~1 MB each, never committed);
- `outputs.json`: the 10 felts, the level and inputs felts, the proving executable and its
  program hash;
- `report.json`: per proof, the steps, wall time, peak RSS, proof bytes and sha256, the verify
  result, the public output, its binding header and the recorded input state (the chain);
- the logs.

With `--case`, the outputs must equal `fixtures/golden/<case>.json`; the script fails otherwise.
`fixtures/proofs/<case>-<mode>/` keeps the measured `outputs.json` and `report.json` (hashes,
never proofs).

## Verify a proof

```sh
python3 tools/prove/verify.py out/ob/main.proof.bin out/ob/outputs.json
python3 tools/prove/verify.py --run out/p2          # every proof of a run and its chain
```

`verify.py` checks four things:

1. **The STARK verifies**: the patched `verify` binary exits 0.
2. **The public output is the outputs**: the proof's output segment is `[n, header…, outputs…]`
   (no header for `main`, `[state_in_hash, inputs_hash]` for `outputs`). It is read twice, by
   `proofdata.py` from the proof file and by the binary; the two must agree.
3. **The program is the one claimed**: the proof's program hash equals `outputs.json`'s
   `program_hash`. That value is recomputed from the executable's bytecode when
   `crates/slingfall_replay/target/dev/<name>.executable.json` is present.
4. **The identity fields**: `level_hash` and `inputs_hash` are the Poseidon hashes of the level
   and inputs felts recorded in `outputs.json`.

`--run <dir>` verifies every proof of the directory (`main`, or `init`, `chunkNN`, `outputs`),
pins each program hash to the executables' (`--executables`, default
`crates/slingfall_replay/target/dev`) and checks the chain's links from the public outputs
("Chunk binding"). It does not read `report.json`.

`tools/prove/test_prove.py` holds the decoding tests and the chain-link tests on synthetic public
outputs. With `PROVE_RUN=<dir>`, it also runs the tamper tests: a changed score, program hash or
level felt, or a truncated proof, is rejected; and it proves `one_block-miss` with `--k 16` into
`<dir>-k16`, then checks that `verify.py --run` accepts it and rejects a copy whose middle chunk
was proven on a fabricated state (`PROVE_CHAIN=skip` skips this part, ~2-3 min on a runner).

### Where the output lives in a proof

A binary proof is `bzip2(bincode(CairoProofForRustVerifier))`: bincode 1.3 with fixed-size
little-endian integers, `u64` lengths and a one-byte `Option` tag. Its first field is
`claim.public_data.public_memory`:

- `program`: the bytecode cells, `(id: u32, value: [u32; 8])`;
- `public_segments`: the output range, then 10 optional builtin ranges;
- `output`: the output segment, same cell layout;
- `safe_call_ids`.

A JSON proof has the same path. The output segment of a scarb 2.19 standalone executable that
returns `Array<felt252>` holds the array's length, then its felts. There is no panic flag: `main`
writes 11 output cells, as `scarb execute --print-resource-usage` reports.

The **program hash** is stwo's own (`get_verification_output`):

- Blake2s-256 over the program cells;
- each cell is encoded as 2 `u32` limbs when it is < 2^63, otherwise as 8 limbs with the top
  bit set;
- the digest is read as a little-endian integer and reduced mod P.

The program section is the executable's bytecode (`initial_pc .. initial_ap - 2`), so the hash is
a function of the `*.executable.json` alone:

| executable (rapier alpha.3, P1b's binding headers) | program hash |
|---|---|
| `main` | `0x11d8b326a39850ca6ac8937cbc5854f3463c0d2dcee2449e05ab1fe347e052e` (the same as without P1b) |
| `init` | `0x6a092dd77a4e6a562ddf053cc7ce2199ed42043a76ad49de44e7c1fa8e7ef9` |
| `step_chunk` | `0x28fa5446f08fcbdd5ebf9bed3d6fc3a678f9aade28e5cd9b1ec139e91030010` |
| `outputs` | `0xa8f41b36cf8e5d484c9f5f32baa222e3256aec40c79e7dcd13c7bf46471d3f` |

The bytecode writes jump offsets as negative numbers (`-0xc`), which are the felts `P - x`. The
`main` value is the one a CI proof carried.

These change with every change to the replay, the rules or rapier. A verifier pins them per
release.

## What a verifier must check

For a whole-level proof of `main`:

1. The STARK verifies with the expected parameters: the `canonical_small` preprocessed trace,
   `blake2s` channel, `pow_bits` 26, 70 queries, log blowup 1 (96 bits). The proof carries its
   `preprocessed_trace_variant`, and the verifier rejects a mismatch with its own tables.
2. The program hash is `main`'s pinned hash. Without this check, any program that writes the
   right 10 felts would pass.
3. The public output is `[10, outputs]`, with `version` 1.
4. `level_hash` is the hash of the level the verifier expects (the registry's level), and
   `inputs_hash` is the hash of the submitted inputs, whose `player` is the submitter.

The **arguments of a standalone executable are private**. `run_and_prove` passes them through
hints (`CairoHintProcessor.user_args`); they are witness, not public memory. The proof alone says
"some level and inputs, whose hashes are these, give these outputs". The binding to the actual
level and inputs is the `level_hash` / `inputs_hash` check of point 4.

## Chunk binding

A chunked run is `init` → `step_chunk` × n → `outputs`, each proof separate, each proof's
arguments private (see above). Since lot P1b every chunked executable **returns a binding header
before its payload**, so that the public outputs alone tie the proofs together
(`slingfall_game::chunk::{init_header, step_header, outputs_header}`):

| executable | public output (the returned array) |
|---|---|
| `init(level)` | `[LEVEL_HASH] ++ state` |
| `step_chunk(state, inputs, shot, k, trace)` | `[STATE_IN_HASH, INPUTS_HASH, shot, k] ++ new_state` |
| `outputs(state, inputs)` | `[STATE_IN_HASH, INPUTS_HASH] ++ outputs` (the 10 D4 felts) |
| `main(level, inputs)` | `outputs` (unchanged: it binds `level_hash` / `inputs_hash` itself) |

**The hash.** `LEVEL_HASH = poseidon(level felts)`, `INPUTS_HASH = poseidon(inputs felts)`,
`STATE_IN_HASH = poseidon(state felts)`: `poseidon_hash_span` over the `Serde` felts of the
argument, **without the array's length prefix**. For a state these are exactly the felts the
previous proof returned after its header, i.e. `slingfall_level::hash::serde_hash` of the
`ChunkState`. The same function everywhere: Cairo `hash_felts` (the corelib sponge, 16 felts per
loop iteration, without `multi_pop_front`, whose hint the client's cairo-vm cannot run), Python `tools/levelc/poseidon.py` `hash_span`. The executables hash the argument
felts they received, before decoding them: a proof commits to the exact felts it ran on.

**What a verifier checks** (`verify.py --run`, `verify.check_chain`), from public data only (the
proofs, their public outputs, the level and inputs felts; never `report.json`):

1. every proof verifies (the STARK, as for `main`), and its program hash is the pinned hash of the
   executable at its position: `init`, then `step_chunk` × n, then `outputs` (`verify.py`
   recomputes the hashes from `--executables`);
2. `chunk_0.STATE_IN_HASH == poseidon(init.state)` and
   `chunk_{i+1}.STATE_IN_HASH == poseidon(chunk_i.new_state)`;
3. `outputs.STATE_IN_HASH == poseidon(last.new_state)` (`init.state` when there is no chunk);
4. every `INPUTS_HASH` (the chunks' and `outputs`') equals the 10-felt `inputs_hash`, which is the
   hash of the submitted inputs;
5. each chunk's `shot` is the shot in progress in its input state (`shots_used`, felt 1), that
   state is not over (felt 2), and `shot` < the number of shots in the inputs: the shots run in
   order;
6. the last state is finished: over, or `shots_used` equals the number of shots (a chain cut
   short would give the outputs of a partial game);
7. `init.LEVEL_HASH` equals the 10-felt `level_hash`, which is the expected level's hash;
8. the outputs are the 10 felts after `outputs`' header, checked as for `main` (points 3-4 of
   "What a verifier must check").

`k` is public but free: any K sequence gives `main`'s run bit for bit (G4), and `k = 0` is a no-op.
With these checks a chain is as sound as `main`: each link is a Poseidon collision otherwise. A
dishonest prover who proves a middle chunk on a fabricated state (say a higher score) and every
later proof honestly from it gets valid proofs and consistent outputs, and one broken link:
`chunkNN: STATE_IN_HASH is not the hash of the previous proof's state`
(`test_prove.py`, `ChainTamper`, on real proofs; `Chain` on synthetic outputs).

**Cost.** ~7 Cairo steps per state felt (`scarb execute`, rapier alpha.3, against `main`'s
executables): +21.4k to +23.1k per pile10 `step_chunk` / `outputs` (3 001-3 232 felts), +4.5k to
+5.8k on one_block (774 felts), +0.6-1.1k per `init`. On a K = 16 chunk: +1.8-2.4 % on one_block,
+4.9-6.0 % on pile10's light pre-impact chunks (~390k steps), +0.5-0.7 % on its impact chunks;
**+1.73 % over the whole pile10 K = 16 chain** (9 898 547 → 10 069 549). The corelib
`poseidon_hash_span` costs ~1.9× as much (probes `slingfall_game::chunk::tests::steps_*hash*`).

A verifier on chain (D9) needs the same checks over the proofs' public outputs, or a recursive
layer that performs them.

## Size limit of `canonical_small`

`canonical_small` has the sequence columns `seq_4 .. seq_20` only (stwo-cairo
`SMALL_MAX_SEQUENCE_LOG_SIZE = 20`; the other variants go to 2^25). A trace in which one
component has more than 2^20 rows panics after the commitment phase, whatever the memory:
`Preprocessed column … "seq_21" is missing from static allocation`. `prove.py` reports this panic
as a "more than 2^20 rows" error.

On the replay executables, the component that crosses the limit is the **range_check builtin
segment**, padded to the next power of two. The evidence (P1, CI):

- every failing run used more than 2^20 = 1 048 576 range checks: the pile10 impact chunk of
  9.6M steps used 1 155 700 (padded to 2^21);
- every passing run used fewer: pile10's 5.3M-step chunk used 651 635, cores3's 6.5M-step chunk
  578 535;
- range checks are ~6-12 % of the steps, depending on the physics.

A proof therefore has to stay under ~1.05M range checks, not under a step count. That is roughly
8.5M steps during a pile10 impact and more on lighter ticks.

Runs that hit the limit: the whole pile10 reference shot (10.7M steps), the whole cores3
reference shot (13.5M), and pile10 in 2 or 3 equal-tick chunks (see Measurements). Such a proof
has two options:

- chunk more finely: K = 16 proves both levels;
- `--params tools/prove/params.canonical_without_pedersen.json`, whose preprocessed trace alone
  is ~7 GiB. A whole pile10 or cores3 shot with it killed the 16 GB CI runner, so the whole levels
  need more than 16 GB.

## Memory model

Research 05, `canonical_small`: **RSS ≈ 2.6 GiB + 1.5 GiB per million Cairo steps**. It is
stepwise, because each component pads to a power of two. RAYON threads do not change the peak;
the trace columns dominate. The proof is ~1 MB in binary whatever the size.

| steps | predicted peak |
|---:|---:|
| 2.8M (one_block miss) | ~6.8 GiB |
| 5.4M (half of pile10) | ~10.7 GiB |
| 10.7M (pile10 reference) | ~18.7 GiB |
| 13.5M (cores3 reference) | ~22.9 GiB |

The limits that follow:

- ~7.5M steps per proof under 14 GiB;
- ~11.5M under 20 GiB;
- ~8.5M on a 16 GB GitHub runner.

The measurements below agree: 2.8M steps → 6.0 GiB, 5.3M → 9.4 GiB, 6.5M → 12.1 GiB. With
`canonical_small`, the range-check limit above binds before memory does on a 16-20 GiB machine.

## Measurements (P1)

Setup of these runs:

- GitHub `ubuntu-latest` runners: 4 vCPU, 16 GB, no cgroup limit visible (`memory.max` =
  `max`), the prover built without `target-cpu=native`;
- `canonical_small`, binary proofs;
- steps are `run_and_prove`'s `Num steps`, and the peak is the child's `ru_maxrss`;
- verify is the separate `verify` binary, ~1.5 s per proof.

Per-run files: `fixtures/proofs/<case>-<mode>/summary.json`.

| case | mode | proofs | steps (sum) | largest proof | wall (sum) | peak RSS | proof bytes (sum) | result |
|---|---|---:|---:|---:|---:|---:|---:|---|
| one_block-miss | whole | 1 | 2 801 412 | 2 801 412 | 30 s | 6.02 GiB | 1 538 769 | verifies, outputs = golden |
| pile10-reference | whole | 1 | 10 692 530 | – | 44 s | 14.64 GiB | – | range-check limit (2^21) |
| pile10-reference | whole, `canonical_without_pedersen` | 1 | 10 692 530 | – | killed at ~54 s | > 16 GB | – | runner out of memory |
| pile10-reference | `--chunks 2` (K 54) | init + 2 | – | 9 594 383 | – | 14.60 GiB | – | chunk 1: range-check limit |
| pile10-reference | `--chunks 3` (K 36) | init + 3 | – | 9 300 016 | – | 14.65 GiB | – | chunk 2: range-check limit |
| pile10-reference | `--k 16` | 9 | 11 806 510 | 5 334 069 | 168 s | 9.41 GiB | 10 592 959 | verifies, outputs = golden |
| cores3-reference | whole | 1 | 13 537 066 | – | 70 s | 14.73 GiB | – | range-check limit (2^21) |
| cores3-reference | whole, `canonical_without_pedersen` | 1 | 13 537 066 | – | killed at ~63 s | > 16 GB | – | runner out of memory |
| cores3-reference | `--chunks 3` (K 60) | 5 | 13 877 995 | 6 473 040 | 176 s | 12.13 GiB | 6 055 264 | verifies, outputs = golden |
| cores3-reference | `--k 16` | 14 | 14 618 516 | 2 345 691 | 227 s | 5.23 GiB | 16 366 119 | verifies, outputs = golden |

How to read the table:

- **Equal ticks are not equal steps.** On pile10 the first ~70 ticks cost ~25k steps each; the
  impact ticks average ~330k. With `--chunks 2`, chunk 0 has 1.1M steps and chunk 1 9.6M.
  Chunks balanced by steps would need a step estimate per tick, which is not done here.
- **The chunking overhead** is `init` plus the `step_chunk` round trips, plus `outputs`: +10 % on
  pile10 K = 16, +8 % on cores3 K = 16, +2.5 % on cores3 K = 60.
- **Proof bytes** are ~1.0-1.5 MB per proof whatever its size, so the total grows with the
  number of chunks.
- **Proofs are deterministic**: the same inputs give the same proof bytes. The `init`, `outputs`
  and `main` proofs had identical sha256 across CI runs.

## Measurements (P1b, binding headers)

Setup: rapier alpha.3, the lot's final code, the shared VPS (8 cores, a 22 GiB systemd unit, no
swap), the prover built with `setup.sh --native`, `canonical_small` unless stated, one proof at a
time; `verify.py --run` green on every run. Per-run files:
`fixtures/proofs/<case>-<mode>-p1b/summary.json`.

| case | mode | proofs | steps (sum) | largest proof | wall (sum of proofs) | peak RSS | proof bytes (sum) | result |
|---|---|---:|---:|---:|---:|---:|---:|---|
| one_block-miss | whole | 1 | 2 425 011 | 2 425 011 | 27 s | 5.65 GiB | 1 558 919 | verifies, outputs = golden |
| one_block-miss | `--k 16` | 10 | 2 821 056 | 488 202 | 179 s | 3.52 GiB | 14 654 632 | verifies, chain linked, outputs = golden |
| pile10-reference | `--k 16` | 9 | 10 069 549 | 4 312 754 | 203 s | 10.17 GiB | 13 225 744 | verifies, chain linked, outputs = golden |
| pile10-reference | whole, `canonical_without_pedersen` | 1 | 8 783 663 | 8 783 663 | 55 s | 20.53 GiB (cgroup 21.00 GiB sampled) | 1 583 677 | verifies, outputs = golden |

- The headers add 171 002 steps to the pile10 K = 16 chain (+1.73 %), against the same chain of
  `main`'s executables (`scarb execute`).
- Per proof on pile10 K = 16: ~21 s and ~4.3 GiB for a light chunk, 36 s and 10.17 GiB for the
  4.31M-step impact chunk, 15 s for `outputs`.
- The whole pile10 shot (alpha.3: 8.78M steps) fits the 22 GiB unit with
  `canonical_without_pedersen`, ~1.5 GiB under the limit. P1's 16 GB runner was killed on it
  (alpha.2, 10.7M steps).

## Atlantic + Integrity

Lot E3a (2026-09-26): the fallback of `docs/DESIGN.md` D9 (research 01 §4) run end to end on Starknet
Sepolia through Herodotus Atlantic. Tool: `tools/atlantic/atlantic.py` (Python 3 stdlib); the proven
program: `tools/atlantic/c1main`; the committed runs: `fixtures/proofs/atlantic/<case>.json`.

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
  `translateFactHash(program_hash, output)` (not observed completing on 2026-09-26: both such queries
  stalled after trace generation) re-derives the keccak fact from the public output and
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
   'output', 'range_check', 'bitwise', 'poseidon', data…])` over the felts of the compiled program.
   The committed runs (rapier2d alpha.2, 454 101 felts): `CHILD_PROGRAM_HASH =
   0x128791df23988bef1c8aef3be7ce36ad68278d19878369e5fb7ed2515d5b053` (Atlantic's `child_program_hash`,
   recomputed locally by `atlantic.py program-hash`). `c1main` on alpha.3 (B2, 459 803 felts):
   `0x674479c20ac59520857856f672b063c6896d7ef1c86d385c54bb5982c72cf99` (Atlantic's, E3b's Sepolia run; the
   `child_program_hash` of the Sepolia deployment). It changes with any
   change to the game, the engine, `c1main` or the Cairo compiler: pin it per release.
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

### Contract side (E3b): `SatelliteVerifier`

Implemented in `crates/slingfall_contract/src/verifier.cairo` (lot E3b). Constants in storage, admin-set
through `ISlingfallSatellite::set_satellite_config(SatelliteConfig { child_program_hash,
atlantic_bootloader_hash, sharp_bootloader_hash, satellite_address })` (any zero field rejects
everything); `PEDERSEN_0_0` is a code constant. Satellite addresses: Sepolia
`0x00421cd95f9ddabdd090db74c9429f257cb6bc1ccc339278d1db1de39156676e`, mainnet
`0x01ba7d4b5707f8878c22fb335763abfc26c2ae157c434d597f6416fe6a79bf2e` (Integrity's `lib_utils.cairo`).

1. Calldata: `submit_settled(outputs, args)`, `args` = `c1main`'s argument `[len(level), level…,
   len(inputs), inputs…]` (what `tracec.py args` writes; also the `evidence` of `submit` when
   `verifier = Satellite`). Nothing else is trusted from the caller.
2. Bind: nothing to recompute. The proven program decodes `args` (exactly one level, one `Inputs`,
   nothing left) and computes `level_hash`, `player` and `inputs_hash` into the outputs, and the fact
   commits to outputs and `args` together; the contract checks the registry (`level_hash` registered
   and active), `outputs.player == caller` and the nullifier, as for `submit`.
3. Recompute `task = [0, 10, outputs…, len(args), args…]`, `output = [0, PEDERSEN_0_0, 1, len(task) + 2,
   child_program_hash, task…]` (`atlantic_output`), then `fact = poseidon(sharp_bootloader,
   poseidon_hash_span([1, len(output) + 2, atlantic_bootloader, output…]))` (`integrity_fact`).
4. Check `Satellite.isCairoFactValid(fact, false)` (the translated fact, 96 bits); if false, the
   bridged keccak fact: `sharp = keccak_be(atlantic_bootloader ‖ keccak_be(output))` over 32-byte
   big-endian words (`sharp_fact`; `keccak_u256s_be_inputs` returns little-endian digests, reversed)
   and `Satellite.isKeccakVerifiedFactHashValid(sharp)`. The keccak read is today's path (below); it
   rests on the same SHARP verification as the translated fact, before translation.
5. Tiers: nullifiers are `NONE → ATTESTED → SETTLED` or `NONE → SETTLED` (`attempt(level_hash, player,
   inputs_hash)` reads it); `Record.settled` and `LevelValidated.settled` carry the tier; settling an
   attested attempt that is the player's best record marks it settled, anything else is refused
   (`'submit: nullifier'`).

Golden vectors: the two E3a runs (`crates/slingfall_contract/src/submit/fixtures.cairo`, from
`fixtures/proofs/atlantic/*.json`): both facts of both runs are recomputed bit for bit
(`test_atlantic_facts_are_the_e3a_facts`), and the deployed contract accepts them against a fake
Satellite that knows exactly those facts (`submit/tests/settled.cairo`).

**What is on-chain today (2026-09-26).** Only the bridged keccak fact: `isKeccakVerifiedFactHashValid(
sharp_fact)` is `true` on the Satellite for both E3a runs. The two E3a
`PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION` queries were still stuck after trace generation 2.5 h
later (`01M3EMT5TPVX00M8TC1K6HS841`, created 10:40Z: `IN_PROGRESS`, step `TRACE_AND_METADATA_GENERATION`, at 13:12Z),
so the prover service submits `PROOF_VERIFICATION_ON_L2` by default and `SatelliteVerifier` accepts the
keccak fact. Anyone may call the Satellite's permissionless `translateFactHash(
ATLANTIC_BOOTLOADER_PROGRAM_HASH, out, false)` to register the Poseidon fact from the keccak one (a
transaction, not sent by E3a or E3b; lot E3c sent it: "Translation" below), after which the cheaper
Poseidon path applies.

Trust: the fact rests on Ethereum's SHARP verifier plus Herodotus's L1 → L2 bridge and Satellite owner
(the Satellite is upgradeable), not on an on-chain Starknet verification of the proof.

### Settled submit

Cost of `submit_settled(pile10 reference)` (`args` = 154 felts):

| path | snforge (Cairo steps, over setup) | starknet-devnet L2 gas | vs attested `submit` (5,649,600) |
|---|---|---|---|
| translated fact (`isCairoFactValid`) | 23,860 | 4,453,840 (upgrade) | 0.79x |
| keccak fact only (`isKeccakVerifiedFactHashValid`) | 56,817 | 11,973,840 (upgrade) | 2.12x |

The level felts come in calldata: reading the 146 felts of pile10 from the registry costs ≈ 3.9M L2
gas (snforge probe of `level_data`), calldata ≈ 5k L2 gas per felt. The keccak path spends 42 Keccak
rounds (5,504 bytes of output, then the 64-byte outer hash) plus the byte reversals of 172 words;
it is over the 2x budget until the translated fact is available.

Sepolia (2026-09-26, `deploy/sepolia.json`, `fixtures/proofs/atlantic/pile10-reference-sepolia.json`):
`Slingfall` `0x4b645fe7cf06775c99c61148097b3aecabb67eacfd2937e0431affef5000ae2` (class
`0x46bff3841120701543560f801b66ad9f9eb35dd73484d2cf0422be533442e5f`), `verifier = Satellite`.
`pile10-reference` proven for the deployment account by the prover service: Atlantic query
`01M3ESEE4N7T8AWBF6YTZ1Z8ZM` (declared L, trace 96 s, SHARP 3 590 s, bridge 269 s: 66 min), keccak fact
`0xced287ce…3fb5d6` on the Satellite (the translated `0x5c02aa91…9caf5` is not), Atlantic's facts equal
to the service's. `submit_settled` `0x636874a6904bee1882e14b65663080bef78525bc8ea906bcea02e1576fc50eb`:
18,819,885 L2 gas, 1,056 L1 data gas, 0.399 STRK (a first settlement on the keccak path, Braavos
account; a first record and leaderboard row); `best` = `{5200, won, settled}`, the leaderboard lists
the account. The whole deployment (declare 22.9 STRK, deploy, configure, six levels, the submit):
31.81 STRK.

### Client / service flow

1. The client plays the level with the browser VM (same Cairo) and gets the 10 outputs; it submits
   them attested (`submit(outputs, [r, s])`, provisional) where an attestation service exists.
2. The **prover service** (`services/prove/prove_service.py`; it holds the Atlantic API key, never the
   browser) receives `POST /prove {level, inputs}`, runs `cairo1-run` on `c1main` (≈ 2 min for pile10
   plus ≈ 90 s of Python Pedersen for the program hash, cached per Sierra), checks the outputs, computes
   both facts, submits the PIE with `result = PROOF_VERIFICATION_ON_L2` (`--result` also takes
   `…_WITH_TRANSLATION`), `declaredJobSize` M (run steps + 3.6M bootloader ≤ 8M) else L, `dedupId` =
   the job id (`sha256(level_hash, inputs, c1main Sierra, result)`: retries are idempotent). Jobs live
   on disk (`services/prove/out/<id>/job.json`).
3. Latency on Sepolia: trace generation 40-100 s, SHARP proof + L1 verification ≈ 1.5 h, bridge ≈ 4
   min. `GET /status/<id>` answers Atlantic's stages and the Satellite's two reads: `settleable_poseidon`
   (translated fact, cheap), `settleable_keccak` (bridged fact only), `settleable` (either), and
   `translation` (E3c, below).
4. The player sends `submit_settled(outputs, args)` from their wallet ("Settle (cheap)" when the
   Poseidon fact is on the Satellite, else "Settle"; the contract itself tries the Poseidon fact first
   and falls back to the keccak one); it recomputes and checks the fact (above). Nothing
   Atlantic-specific is signed by the player.

### Translation (E3c): the service translates the fact itself

The Satellite's `translateFactHash(program_hash: felt252, output: Span<felt252>, is_mocked: bool)`
(`HerodotusDev/satellite`, `cairo/src/cairo_fact_registry.cairo`; the ABI of the class deployed on
Sepolia matches) re-derives the keccak fact and the Poseidon fact from `program_hash` and `output`,
asserts `keccak_facts[(keccak_fact, is_mocked)]` (`KECCAK_FACT_HASH_NOT_SAVED` otherwise), sets
`translated_fact_hashes[(poseidon_fact, is_mocked)]` and emits `TranslatedFactHashSet(keccak_fact_hash: u256,
integrity_fact_hash, is_mocked)`. Nobody is authorised or paid: `isCairoFactValid(fact, false)` is then
true (`get_all_verifications_for_fact_hash` shows one `translated` verification, 96 security bits).
For a Slingfall run `program_hash` = `ATLANTIC_BOOTLOADER_PROGRAM_HASH` and `output` = Atlantic's output
(`encoding.run_output`: 172 felts for pile10, 175 felts of calldata with the program hash, the length
and `is_mocked`), which the tool recomputes from the level, the inputs and the run's outputs and checks
against the keccak fact before sending anything.

- **Tool.** `tools/atlantic/atlantic.py translate <sharp_fact> (--fixture NAME | --query ID | --output
  FILE) [--dry-run]`: checks the output hashes to the keccak fact, that the Poseidon fact is not
  valid yet and that the keccak fact is on the Satellite, sends the transaction with
  `node deploy/slingfall.ts translate --output FILE` (starknet.js; the account of the environment:
  `STARKNET_*` or `SLINGFALL_*`), checks `isCairoFactValid` afterwards. `deploy/sepolia.sh translate JOB`
  does it for a prover-service job.
- **Service.** When Atlantic's status is `DONE` (the keccak fact is bridged) and the Poseidon fact is
  still absent `TRANSLATE_GRACE` seconds after Atlantic's `completedAt` (default 600; the first sighting
  when there is none), `serve`'s background thread (a pass every 120 s) translates it: one transaction,
  three attempts at most, ten minutes apart, recorded in `job.json` (`translation`). Atlantic's own
  translation, when it comes, wins (the fact is then already valid). Without an account
  (`STARKNET_ACCOUNT_ADDRESS`, `STARKNET_PRIVATE_KEY`, `STARKNET_RPC_URL`) or with `--no-translate` the
  service only reports `settleable_keccak`. `/status`'s `translation.state`: `waiting`, `grace`,
  `translate`, `translated`, `backoff`, `gave-up`, `no-account`, `unknown`
  (`prove_service.translation_decision`, table-tested).
- **Client.** The panel shows "Settle" on the keccak path and switches the button to "Settle (cheap)"
  when `settleable_poseidon` turns true (it keeps polling while the service can still translate).

Sepolia (2026-09-26, `fixtures/proofs/atlantic/pile10-reference-sepolia.json`, `translation`): the E3b
fact `0xced287ce…3fb5d6` translated by `atlantic.py translate`, transaction
`0x40c081d32d2b150122c0e2ad25178b16681bd95b91de290a3e4247c30f0a624`: 13,731,733 L2 gas, 288 L1 data gas,
**0.290 STRK**; `isCairoFactValid(0x5c02aa91…9caf5)` went from `false` to `true` (`check-fact`: one
`translated` verification, 96 bits).

Cost of the settled submit by path (`deploy/e2e.sh`, starknet-devnet 0.10.0 with the `FakeSatellite`,
pile10 reference, L2 gas): Poseidon fact 4,453,840 (0.79x the attested `submit`, 5,649,600), keccak
fact 11,973,840 (2.12x); both figures are E3b's, reproduced. On Sepolia the keccak path cost 18,819,885
(E3b). The Poseidon path was **not** measured on Sepolia: the deployed verifier is the Satellite-only
one (no attested `submit` exists there) and the only funded attempt's nullifier is settled, so a
second `submit_settled` reverts; a fresh attempt needs a new Atlantic proof (about 66 min). What the
numbers bound: the real Satellite costs about 6.85M L2 gas more than the fake over the keccak path
(18.82M against 11.97M), so the Poseidon path on Sepolia is at most about 4.45M + 6.85M ≈ 11.3M (an
inference, not a measurement), below the keccak path's 18.8M in any case. The translation itself is a
transaction of 13.7M L2 gas that the service pays: translating moves cost from the player's settlement
to the service, it does not reduce the total.

### Runs, latency, cost

See `fixtures/proofs/atlantic/<case>.json` and the lot's `REPORT.md` for the per-stage timings. Costs: testnet
queries are free (Atlantic pricing: S 70 credits, M 120, L 220 on mainnet, trace generation 1 credit per
started minute, L2 mainnet verification 25 credits); the job-size tier that works for our program is
**M** for one_block (S is OOM-killed at trace generation: the bootloaded run is 6.3M steps, 3.6M of them
Pedersen-hashing the 454k-felt program) and **L** for pile10 (M is OOM-killed).
