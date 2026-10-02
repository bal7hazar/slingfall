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

## Deterministic builds

The Cairo compiler's Sierra output is not deterministic when it runs on several threads (measured by the
Grim World project, Scarb 2.19.4 and 2.20.1: 20 clean builds of a minimal case gave 20 different Sierra
files, a `withdraw_gas` check landing 12 times in one function and 8 in another; with
`RAYON_NUM_THREADS=1`, 6 of 6 builds were identical). Everything this repository hashes, sizes, declares,
snapshots or measures depends on the exact output, so **every such build runs with `RAYON_NUM_THREADS=1`,
set by the script itself**, never left to the caller (the machine's shims set 4): `tools/classsize`,
`crates/slingfall_split/scripts/{pin,heavy,levers,windows}.py`, `crates/slingfall_replay/scripts/measure.py`,
`tools/prove/prove.py`, `scripts/steps.py`, `tools/golden`, `deploy/{e2e,sepolia,v2}.sh`,
`client/vm/scripts/fetch-executables.sh`, `deploy/devnet.sh`, `scripts/play.sh`, and the whole CI
workflow (`env:` of `.github/workflows/ci.yml`). A build typed by hand for a hash (`c1main`, a pin check)
needs the variable too: `RAYON_NUM_THREADS=1 scarb build ...`. Builds that only run tests may keep more
threads. CI's `build` job builds the split classes twice from clean and fails if their bytes (hence class
hashes) differ. Cost: the clean split build takes 105 s on one thread against 44 s on four (VPS, Scarb 2.19.4).
`c1main`'s program hash on one thread is the pinned Sepolia one, `0x580ef5d1...edf75a`.
`deploy/devnet.sh` (`proven`) and `scripts/play.sh` reuse split classes already in `target/dev`; run
`scarb clean` first if they were not built on one thread (a drifted class fails loudly at declaration
against the pinned hashes).

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
   `0x674479c20ac59520857856f672b063c6896d7ef1c86d385c54bb5982c72cf99` (Atlantic's, E3b's Sepolia run).
   It changes with any change to the game, the engine, `c1main` or the Cairo compiler: pin it per
   release ("Program hash history" below). The Sepolia deployment (`deploy/sepolia.json`, contract v2
   since lot D2) pins the current release's hash with `pin_program(hash, grace_s)`: a proof made with
   an earlier program's hash settles only while that program is inside its grace period (the fact
   commits to the program that produced it; on v1 a re-pin voided it at once).
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

### Program hash history

`c1main`'s `child_program_hash` (`atlantic.py program-hash`, cairo-lang's Pedersen
`compute_program_hash_chain` over the compiled program's felts): pinned per release in
`deploy/slingfall.ts`'s `CHILD_PROGRAM_HASH`. On the v1 Sepolia deployment (retired by lot D2) it was
`deploy/sepolia.json`'s `v1.satellite.child_program_hash` (one admin `set_satellite_config`
transaction), and a proof made against an earlier hash no longer settled once the contract was
re-pinned: the fact commits to the exact program.

Contract v2 (lot V2, `docs/contract-v2.md`; wired by lot W1, deployed on Sepolia by lot D2: `deploy/sepolia.json`'s
`program`) replaces the single pin
with a set: `pin_program(hash, grace_s)` keeps the previous hash valid for `grace_s` seconds,
`revoke_program(hash)` voids one at once, and `submit_settled(outputs, args, child_program_hash)` names
the hash the proof was made with. A proof in flight across a re-pin therefore settles until the grace
period ends (QA M7). The scripts: a fresh deployment pins with no grace (`deploy/slingfall.ts deploy`:
key, `pin_program(c1main, 0)`, Satellite, levels); a re-pin is `deploy/sepolia.sh pin HASH
(--bit-compatible | --grace S | --no-grace) [--yes]` (the grace is always an explicit choice:
`--bit-compatible` = 86 400 s for a release that gives the same outputs, `--no-grace` for a numeric
change or a defect), a defect also `deploy/sepolia.sh revoke HASH`. Both warn and refuse without
`--yes` while `services/prove/out` holds jobs not known to be settled (Q3's guard, now on `pin`).
`deploy/e2e.sh` checks a re-pin with grace on the devnet: an old proof settles inside the window and
is refused with `'submit: program'` after it.

| rapier2d | lot | `c1main` felts | `child_program_hash` | pinned on Sepolia |
|---|---|---:|---|---|
| alpha.2 | E3a | 454 101 | `0x128791df23988bef1c8aef3be7ce36ad68278d19878369e5fb7ed2515d5b053` | no (E3a: local / Atlantic round trip only, before the Sepolia deployment) |
| alpha.3 | B2 / E3b | 459 803 | `0x674479c20ac59520857856f672b063c6896d7ef1c86d385c54bb5982c72cf99` | 2026-09-26 (E3b's deployment) |
| alpha.5 | B3 | 582 399 | `0x3f961b5c5b590fbc720048672b0ddeda96aa52ab16b56365f6d1583c5ed27ec` | 2026-09-27 (`set_satellite_config` tx `0x1f3652885aec68ea61add59bb3814dbd44e55669f8e5727d74c347dc28a1447`) |
| alpha.6 | B4 | 271 833 | `0x580ef5d1896ce36ddc0309eed11218303ed39d1c30ad8ccea4d194be3edf75a` | 2026-09-27 (v1: `set_satellite_config` tx `0x4a77159da8decd6f2659649e642b488d154e737618566e4219ea589845d4bdf`; v2, lot D2: `pin_program(hash, 0)` in the `configure` tx `0x6079548cffbd0d81aae63468e0fb4a36833b0377983982b2e150461eb4fe3b0`) |
| alpha.7 | B5 | 271 833 | `0x580ef5d1896ce36ddc0309eed11218303ed39d1c30ad8ccea4d194be3edf75a` (the alpha.6 hash) | no transaction: the program hash is unchanged (`fixtures/proofs/atlantic/child-hash-alpha7.json`) |
| alpha.8 (`fixed` 0.4.0, `glam_core` 0.4.1) | B6 | 271 833 | `0x580ef5d1896ce36ddc0309eed11218303ed39d1c30ad8ccea4d194be3edf75a` (the alpha.6 hash) | no transaction: the program hash is unchanged (`fixtures/proofs/atlantic/child-hash-alpha8.json`) |

The felt count jumps 26.6 % from alpha.3 to alpha.5 (CC1 + CC2 + LO2 + SH2a: shape casts, the CCD
solver, Polyline / HeightField), well past a rapier2d MINOR version's usual size drift; none of it
runs on Slingfall's own shapes (D5: CCD stays off), consistent with `SlingfallSim`'s own Sierra size
growing from 196 801 to 273 632 felts over the same bump (`scarb build`, `crates/slingfall_contract`).

alpha.6 (B4) cuts it back: every step of the game is `step_with::<BasicStepConfig>` /
`step_with_force_events_with::<BasicStepConfig>` (balls, cuboids, convex polygons, half-spaces; no
joint, sensor or composite shape), so the joint solver, the sensor tests, the composite manifolds
and the other shapes' generators are no longer in the program: `c1main` 582 399 -> 271 833 felts
(-53.3 %), `SlingfallSim` 273 632 -> 140 568 Sierra felts (-48.6 %). The SF1 numeric change
(exactly closed contact gaps solve rigidly) changes the `final_state_hash` of the goldens whose
pile is hit; scores, wins and ticks are unchanged.

alpha.7 (B5) changes nothing the game runs: the 11 golden cases are bit-identical (outputs,
`final_state_hash`) and take exactly the same Cairo steps, the replay executables and `ball_drop`
rebuild byte-identical, and `c1main`'s program hash is the alpha.6 one, so the Sepolia
v2 pin needs no `pin_program` (the contract's `current_program()` already is that hash).

alpha.8 (B6, with `fixed` 0.4.0 and `glam` replaced by `glam_core` 0.4.1) changes nothing the game runs
either: the 11 goldens are bit-identical with the same Cairo steps, the replay executables and
`ball_drop` rebuild byte-identical, and `c1main`'s Sierra differs from alpha.7's only by the ids of
24 user types (hashes of their paths, `glam::` -> `glam_core::`), which the CASM does not carry: same
program hash, no `pin_program` (read back on Sepolia: `current_program()` is that hash, valid
forever).

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

**Contract v2** (lot V2, `docs/contract-v2.md`) changes steps 1, 2 and 5; the fact (steps 3-4) is
unchanged:

1. Calldata: `submit_settled(outputs, args, child_program_hash)`. `SatelliteConfig` keeps three fields
   (`atlantic_bootloader_hash`, `sharp_bootloader_hash`, `satellite_address`); the program hash comes
   with each call and must be valid now in the contract's program set (`'submit: program'`), then goes
   into `atlantic_output` (a valid hash other than the proven one fails as `'submit: proof'`).
2. Bind: no `outputs.player == caller` any more: the record is `claim.player`'s whoever sends the
   transaction (a relay), since the fact binds the player. The attested `submit` keeps the check.
5. Tiers: `best` / `leaderboard_provisional` rank either tier, `best_settled` / `leaderboard` settled
   attempts only; `Best.program_hash` and `LevelValidated.program_hash` name the program. `submit` no
   longer takes the run's argument as evidence (`verifier = Satellite` closes `submit`).

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

Contract v2 (snforge L2 gas over setup, `docs/contract-v2.md` "Gas and size"): a first settled record
costs 8.0M (translated) / 11.0M (keccak) against v1's 6.1M / 9.0M on the same probe, since it now writes
`best` and `best_settled` and both leaderboards; the attested `submit` drops from 4.3M to 3.9M (the record
packed in three slots).

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

Sepolia, contract v2 (2026-09-27, lot D2; `deploy/sepolia.json`,
`fixtures/proofs/atlantic/pile10-reference-sepolia-v2.json`, `docs/e2e.md` "Sepolia, contract v2"):
`Slingfall` `0x292f4b7dcbdb3ee7e5c3d1873e36ac03c71f3d4d5146ff009bcdf6e8bca4a02` (class
`0x256e46a924bc9e435d8de5015fd6ec1b1bbe0e1eaf84d887a75961ea82a749f`), verifier `Stub` (both tiers),
program alpha.6. The pile10 reference for the admin account, first attested (`submit` 5,494,931 L2 gas,
0.118 STRK, 18 s from the attestation request), then proven through the prover service (`POST /prove`,
`serve --relay --no-translate`): PIE 100 s, Atlantic query `01M3J20R8B8P1VSQSWSS8D1Y94` (declared L, ran as
S; trace 86 s, SHARP 3 966 s, bridge 224 s: 71.3 min), Atlantic's facts equal to the service's, keccak fact
`0x4be7eef9…77a69` on the Satellite; the relay sent `submit_settled`
`0x369d3bde2bfb4447c1774135fa7370086d64a7b0ea54df8565354a5ed97a8fe` 29 s after the bridge (32 s to the block):
17,746,555 L2 gas, 896 L1 data gas, **0.381 STRK** (the upgrade of the attested attempt on the keccak path:
`best` marked settled, `best_settled` and the settled board written). `POST /prove` to the settled
record: 73.5 min. The whole v2 deployment and both tiers: 40.25 STRK (declare 30.96).

### Client / service flow

Contract v2 (lot W1): "play → provisional record in seconds → proof requested in the background →
settled by the relay or by the player"; the page need not stay open while the proof runs.

1. The client plays the level with the browser VM (same Cairo) and gets the 10 outputs. It asks the
   **attestation service** (`services/attest/attest.py serve --execute`) with the level, the inputs and
   its outputs: the service re-executes the replay natively (`scarb execute`, seconds), signs
   `verifier::attestation_message(chain_id, contract, program_hash, epoch, expiry, outputs)` when the
   outputs match (epoch read from the contract, rate limited per player), and the player sends the
   attested `submit(outputs, [program_hash, expiry, r, s])`: a provisional record and a row on
   `leaderboard_provisional`. `--verify-cmd` stays for players who bring a proof.
2. The page then requests the proof on its own. The **prover service** (`services/prove/prove_service.py`;
   it holds the Atlantic API key, never the browser) receives `POST /prove {level, inputs}`. Before
   anything else (M6, below), once its own `child_program_hash` is known it asks the contract
   `program_valid_until(hash)`; a program past its grace or revoked answers `409` at once instead of
   spending the run and Atlantic's ~1.5 h on a proof the contract will refuse. It then runs `cairo1-run` on `c1main` (≈ 2 min for pile10
   plus ≈ 90 s of Python Pedersen for the program hash, cached per Sierra), checks the outputs, computes
   both facts, submits the PIE with `result = PROOF_VERIFICATION_ON_L2` (`--result` also takes
   `…_WITH_TRANSLATION`), `declaredJobSize` M (run steps + 3.6M bootloader ≤ 8M) else L, `dedupId` =
   the job id (`sha256(level_hash, inputs, c1main Sierra, result)`: retries are idempotent). Jobs live
   on disk (`services/prove/out/<id>/job.json`).
3. Latency on Sepolia: trace generation 40-100 s, SHARP proof + L1 verification ≈ 1.5 h, bridge ≈ 4
   min. `GET /status/<id>` answers Atlantic's stages and the Satellite's two reads: `settleable_poseidon`
   (translated fact, cheap), `settleable_keccak` (bridged fact only) and `settleable` (either) —
   all three also require `program_match` (M6: the job's `program_hash` is valid on the contract now,
   `program_valid_until > now`; `null` never blocks, only a confirmed refusal does), since a fact that
   exists on the Satellite can no longer settle once its program is past its grace period or revoked.
   The Satellite read is the one of the contract's `satellite_config()`. `translation` describes what
   the service does about the Poseidon fact (E3c, below); `relay` / `relayed` /
   `relay_transaction_hash` what the relay did (step 4).
4. Settling. Contract v2 records `submit_settled(outputs, args, child_program_hash)` for `claim.player`
   whoever sends it. With `serve --relay` (off by default; the account of the environment pays, as for
   the translations) the service sends it itself once the job is `settleable`, the attempt is not
   settled yet (`attempt(...)`) and a `simulateTransaction` of it succeeds (at most 3 attempts, 5 min
   apart; `relay.py` drives `deploy/slingfall.ts submit-settled [--simulate]`); `/status` then reports
   `relayed` and the transaction hash, and the page shows the settled record without the player
   signing anything. The player can still settle themselves ("Settle (cheap)" when the Poseidon fact is
   on the Satellite, else "Settle"; the contract tries the Poseidon fact first and falls back to the
   keccak one): whoever comes second reverts on `'submit: nullifier'`, and the relay then records
   `settled` and sends nothing. `prove_service.py relay <job>` runs one pass now (`deploy/e2e.sh` uses
   it with a third devnet account). Nothing Atlantic-specific is signed by the player.

### Program match (M6, M7): refusing a proof the contract will not accept

The QA run of 2026-09-26/27 (`docs/qa/2026-09-26-mac.md`) lost an hour of Atlantic proving because
lot B3 re-pinned `satellite_config().child_program_hash` (alpha.3 → alpha.5) while a proof of the
old program was in flight: the fact was valid on the Satellite, but `submit_settled` reverted with
`'submit: proof'` since the contract recomputes the expected fact from its *current* pin, not from
whichever program actually produced the proof. Neither `/prove` nor `/status` checked this before.

The service asks the contract (v2; `SLINGFALL_ADDRESS`, else `deploy/sepolia.json`'s `address`;
`STARKNET_RPC_URL`, cached 30 s; `--no-program-check` disables it) `program_valid_until(own hash)`,
`current_program()` and the latest block's timestamp, and calls its own `child_program_hash` valid
while `valid_until > now`: the current program, or the previous one during its grace period. Its
hash is known once a run of this process has computed one (there is no way to derive it from the
Sierra alone without running it once, so a freshly started service's very first job is not checked,
nor is any job when the RPC read fails: the check only ever refuses a *confirmed* invalid program,
never blocks on uncertainty; a failed read keeps the last known answer). `POST /prove` answers `409
{"error", "program_hash", "contract_program_hash", "program_valid_until", "program_match"}`; `GET
/status/<id>` (for the job's own program) and `GET /health` carry the same fields so the page can
disable Prove with a clear sentence before a wasted click, not after an hour. (Against the v1
deployment, which has no `program_valid_until`, the reads fail and the check stays open.) The
re-pin side is `deploy/sepolia.sh pin` with an explicit grace, guarded by the unsettled-jobs warning
("Program hash history" above).

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
  service only ever reports `settleable_keccak`, and `translation.state` is `off` from the very first
  status read (m13: not `grace` for ten minutes on a service that can never translate, which the page
  used to read as "a cheaper path follows in minutes"). `/status`'s `translation.state`: `waiting`,
  `grace`, `translate`, `translated`, `backoff`, `gave-up`, `off`, `unknown`
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
to the service, it does not reduce the total. Contract v2 on Sepolia (lot D2) settled on the keccak path
again, by design of the brief (no translation transaction): 17,746,555 L2 gas for the upgrade of an
attested attempt (v2 on the devnet: 13,994,080; the real Satellite about 3.75M more), so the Poseidon path
on Sepolia remains unmeasured.

### Runs, latency, cost

See `fixtures/proofs/atlantic/<case>.json` and the lot's `REPORT.md` for the per-stage timings. Costs: testnet
queries are free (Atlantic pricing: S 70 credits, M 120, L 220 on mainnet, trace generation 1 credit per
started minute, L2 mainnet verification 25 credits); the job-size tier that works for our program is
**M** for one_block (S is OOM-killed at trace generation: the bootloaded run is 6.3M steps, 3.6M of them
Pedersen-hashing the 454k-felt program) and **L** for pile10 (M is OOM-killed).

## SNIP-36 tier

Contract v3 (lot V3, `docs/contract-v3.md`) accepts a shot proven in-protocol as a chain of virtual transactions of a
chain contract (`init`, `step_chunk` × n, `outputs`; `docs/research/07-split-game-step.md` §4). What a prover service
does with its proofs:

1. **Prove.** Run the chain locally, then prove every transaction (in parallel, each in its own virtual block on the
   same base block, at least 10 blocks old when submitted). Each proof's `proof_facts` hold one message hash per
   `send_message_to_l1` of its virtual transaction: `poseidon([chain, 'SLINGFALL', len(payload), ...payload])`.
2. **Submit the links.** One real Invoke per proof, carrying `proof` and `proof_facts`, calling
   `submit_chunk(chain, kind, payload)` once per message of that proof (a multicall when a virtual transaction called
   several entry points): `kind` 0 `init` `[LEVEL_HASH, STATE_OUT_HASH]`, 1 `step_chunk` `[STATE_IN_HASH,
   INPUTS_HASH, shot, k, STATE_OUT_HASH]`, 2 `outputs` `[STATE_IN_HASH, INPUTS_HASH] ++ outputs`. Any account, any
   order; resubmitting a link is a no-op.
3. **Finalize.** `finalize(chain, level_hash, inputs, outputs)` from any account once every link is stored: the
   contract walks `init` → steps → `outputs` and records the outputs for `inputs.player` (tier `PROVEN`, ranked with
   the Satellite's settled tier).

The contract checks the facts as the protocol lays them out (SN1 §4): `'PROOF1'`/`'PROOF2'`, `'VIRTUAL_SNOS'`, the
virtual-OS program at index 2 in the admin's set, `'VIRTUAL_SNOS0'`, the base block at index 4 at least 10 blocks old
with a non-zero hash at 5, `n` at 7, the message hashes in `[8, 8 + n)` only. The same parser now backs `submit`'s
`Snip36` verifier (a whole-level `simulate` proof), whose v2 offsets (program at 0, messages anywhere after it) were
wrong.

Costs (snforge, contract execution only): `submit_chunk` 0.84-1.20M L2 gas per link, `finalize` 7.0-7.2M for 5-7
steps plus 71k per further step (at most 64), on top of 75M L2 gas per proof. Measured on the devnet: "Cost sheet"
below.

### The prover service's SNIP-36 path (lot W3)

`services/prove/prove_service.py --snip36 fake|snip36` (`snip36.py`) runs the three steps above for an attempt,
beside Atlantic's path: `POST /prove {level, inputs, "tier": "proven"}` (or `prove --tier proven`), all transactions
from the service's own account (`STARKNET_ACCOUNT_ADDRESS` / `STARKNET_PRIVATE_KEY` / `STARKNET_RPC_URL`, the relay's):
the record is `inputs.player`'s.

1. **Plan.** The chain of the contract's `current_chain()` (layout (e), `SplitChain` over `WorldClass`) runs through
   the node's simulation (`starknet_simulateTransactions` without signature or fee: the devnet, or any RPC 0.10
   node). Each call's return value is the next call's state; the messages are the node's. `k` is picked per chunk so
   that each **virtual transaction stays under `--budget` L2 gas** (default 1.0e9: the node reports L2 gas, not
   steps; the reference shot's chunk 0-90 costs 1,024M L2 gas for 8.76M snforge steps, ~111 L2 gas per step, so
   1.0e9 is about 9M steps, under the protocol's 1.1e9 cap). First guess from the previous chunk's gas per tick;
   an overrun shrinks `k` in proportion (a node out of steps, which reports no figure, halves it). Consecutive
   calls share a transaction while they fit (`init` with the first chunk: one proof, several messages). Each packed
   transaction is then simulated whole and split at a call boundary when the node refuses it: the devnet's block
   capacity counts builtins apart (2.0e9 of its weighted "sierra gas"), and `init` + four chunks at 961M L2 gas
   weighs 2.02e9 there.
2. **Prove**, in parallel (`--parallel`, default 4), through the prover interface:
   * `fake` (devnet): the node executes the transaction at the base block (the latest one) and the facts are laid
     out as the 0.14.4 virtual OS lays them out: `[PROOF2, VIRTUAL_SNOS, 0x53f6…daa1, VIRTUAL_SNOS0, B, hash(B),
     config, n, message hashes]`. The devnet (`deploy/devnet.sh`, starknet-devnet **0.10.0** with `--proof-mode
     none`) ignores the proof but checks the facts' header on the real Invoke as the OS does: the program must be one
     of 0.14.4's two allowed hashes, `B` at least 10 blocks old with its stored hash, the config hash the devnet's
     (`0x57ed…dc57`, recorded from its own prover). Its own `starknet_proveTransaction` (mode `devnet`) is not used:
     its facts put a hash at index 7, not the message count (`services/prove/fixtures/devnet-prove-0.10.0.json`),
     so contract v3 would refuse them. `ripen` closes the 10 blocks (`devnet_createBlock`).
   * `snip36`: `starknet_proveTransaction({block_number: B}, tx)` of `--prover-url` (SN1 §5, §7), `tx` the account's
     virtual Invoke of the transaction's calls signed by `deploy/slingfall.ts sign-virtual` (nonce at `B`, every
     price and the tip zero, `l2_gas.max_amount` 1.1e9, no facts). The answer's facts must be in the protocol layout
     and name exactly the answer's messages (`check_facts`), else the proof is refused before any transaction.
     Written and unit-tested on recorded answers (`services/prove/fixtures/`), **not run**: no prover answers PROOF2
     today (SN1 §5), and the large proof path needs a large machine.
3. **Submit** each proof once `latest >= B + 10`: one Invoke with `proof` and `proof_facts`, one
   `submit_chunk(chain, kind, payload)` per message (`slingfall.ts submit-proof`). Then **finalize**
   (`slingfall.ts finalize`), unless the attempt is proven already.

A job is resumable: its plan (`plan.json`) and each proof (`proof-<i>.json`) are stored; asking again after a failure
proves only what is missing. `/status/<id>` says `"tier": "proven"`, the job's `state` (`planning`, `proving`,
`submitting`, `finalizing`, `proven`, `failed`), `plan` (transactions, their L2 gas, ticks), each proof's state in
`proofs` (`pending`, `proving`, `proved`, `ripening`, `submitted`, with its transaction and gas), `finalize`.

**Program check.** The service's release is a *bundle*: Poseidon of the ordered class hashes of
`crates/slingfall_split/src/hashes.cairo` (`SplitChain`, its four constructor classes of the crate, `RulesClass`,
then rapier's `WorldEditClass` and the seven stage classes the game calls: 14 classes since lot B6, one list in
`crates/slingfall_split/classes.json`; `snip36.BUNDLE_CLASSES`, `client/src/chain/slingfall.ts`
`SPLIT_BUNDLE_CLASSES`). The crate pins the value itself (`hashes::BUNDLE_HASH`, alpha.8:
`0x8a629c64c8e6c34dcc4cd0f29fd51c2c34d19cefe83647335a98825ddd7368`), and the Cairo, Python and TypeScript tests
check that the three computations agree. A
proven job is refused with 409 unless `chain_bundle(current_chain())` is that bundle and `chain_valid_until(chain) >
now`; `/health`'s `proven.available` says so before any request, and the client then offers the settled path.

### Cost sheet (lot W3)

The pile10 reference shot (107 ticks, one shot, layout (e)) proven end to end on starknet-devnet 0.10.0 by the fake
prover (`deploy/e2e.sh`, `deploy/out/e2e/cost.json`), budget 1.0e9 L2 gas per virtual transaction. The devnet charges
the protocol's flat 75,000,000 L2 gas per proof on any Invoke carrying proof facts (measured: the same call costs
75,086,080 more with facts than without). Prices: Sepolia block 15,781,794 (2026-09-28 19:00 UTC, Starknet 0.14.4),
public RPC: L2 gas 21.390 gFri, L1 data gas 530.55 gFri.

| | virtual tx L2 gas | messages | Invoke L2 gas | of which proof | of which `submit_chunk` + account | L1 data gas | STRK |
|---|--:|--:|--:|--:|--:|--:|--:|
| proof 0: `init` + chunk 0-60 | 501,227,200 | 2 | 78,209,840 | 75,000,000 | 3,209,840 | 384 | 1.673 |
| proof 1: chunks 60-74, 74-81, 81-84 | 434,475,520 | 3 | 80,252,640 | 75,000,000 | 5,252,640 | 576 | 1.717 |
| proof 2: chunk 84-96 | 903,286,080 | 1 | 77,321,760 | 75,000,000 | 2,321,760 | 320 | 1.654 |
| proof 3: chunk 96-107 + `outputs` | 876,396,480 | 2 | 78,341,040 | 75,000,000 | 3,341,040 | 384 | 1.676 |
| `finalize` (8 links walked, record and both boards) | | | 5,646,560 | | 5,646,560 | 768 | 0.121 |
| **shot** | 2,715,385,280 | 8 | **319,771,840** | 300,000,000 | 19,771,840 | 2,432 | **6.84** |

* **4 proofs** per shot at a 1.0e9 budget; the 75M L2 gas per proof is 94 % of the cost (6.42 of 6.84 STRK), so the
  number of proofs is the lever. The plan fills each transaction (small chunks to top one up cost ~1.3M L2 gas each,
  a proof 75M), and the devnet's block capacity split `init` + chunks 0-84 in two. Research 07 §4 counted 2 proofs
  for layout (e) by snforge steps (8.76M + 7.76M); in L2 gas the chunk 0-90 alone is 1.024e9, so 2 proofs need a
  budget at the cap and a prover whose block accepts ~2.2e9 weighted gas: unmeasured.
* The virtual transactions pay nothing (zero prices); their proving is the prover's machine time (not measured: no
  prover). Planning took 41 s on the devnet (the chain simulated call by call, then each transaction whole), the fake
  prover a few seconds per transaction.
* Compare: the settled tier's `submit_settled` of the same shot on the devnet costs 6.7M L2 gas (0.14 STRK) plus
  Atlantic's proof (free on testnet, L-size credits on mainnet, ≈ 1.5 h); the attested `submit` 5.2M (0.11 STRK).

### Cost sheet on alpha.8 (lot B6)

The same measurement as W3's, on rapier alpha.8 (layout (e), `WorldClass` 71,076 CASM, rapier's
`WorldEditClass`), both pile10 shots proven end to end on a local starknet-devnet 0.10.0 by the fake prover
(`prove_service.py prove --tier proven --snip36 fake`, budget 1.0e9 L2 gas per virtual transaction, outputs equal to
main's golden). Prices: Sepolia block 15,804,508 (2026-09-29 05:47 UTC, Starknet 0.14.4), public RPC
(`starknet-sepolia-rpc.publicnode.com`): L2 gas 21.102 gFri, L1 data gas 522.73 gFri.

**The owner's shot** (player `'player'`, pull (-1022, -63), 151 ticks, 5,300 points):

| | virtual tx L2 gas | messages | Invoke L2 gas | of which proof | of which `submit_chunk` + account | L1 data gas | STRK |
|---|--:|--:|--:|--:|--:|--:|--:|
| proof 0: `init` + chunks 0-45, 45-53 | 961,487,680 | 3 | 79,675,280 | 75,000,000 | 4,675,280 | 512 | 1.682 |
| proof 1: chunk 53-72 | 929,610,240 | 1 | 77,321,760 | 75,000,000 | 2,321,760 | 320 | 1.632 |
| proof 2: chunks 72-91, 91-92 | 962,560,320 | 2 | 78,787,200 | 75,000,000 | 3,787,200 | 448 | 1.663 |
| proof 3: chunks 92-105, 105-114 | 970,665,280 | 2 | 78,787,200 | 75,000,000 | 3,787,200 | 448 | 1.663 |
| proof 4: chunk 114-135 | 904,435,200 | 1 | 77,321,760 | 75,000,000 | 2,321,760 | 320 | 1.632 |
| proof 5: chunk 135-151 + `outputs` | 716,254,720 | 2 | 78,341,040 | 75,000,000 | 3,341,040 | 384 | 1.653 |
| `finalize` (10 links walked) | | | 9,060,560 | | 9,060,560 | 1,024 | 0.192 |
| **shot** | 5,445,013,440 | 11 | **479,294,800** | 450,000,000 | 29,294,800 | 3,456 | **10.12** |

**The reference shot** (107 ticks): 3 proofs (`init` + chunks to tick 84; chunks 84-97; chunk 97-107 + `outputs`),
virtual L2 gas 955.2M / 941.6M / 748.2M, Invokes 248,634,960 L2 gas (225M of it the proofs), `finalize` 8.9M:
**5.25 STRK** (W3 on alpha.7: 4 proofs, 6.84 STRK at 21.39 gFri).

* In snforge steps the owner's shot is 35.29M in 6 transactions of at most 9.22M (`init` 0.83M, chunks 0-60 8.41M,
  60-90 9.22M, 90-120 8.19M, 120-151 8.56M, `outputs` 0.08M; research 07 "Status after B6"); alpha.7: 37.50M in 7.
  The node's L2 gas is what the planner budgets (about 150 L2 gas per step on the heavy ticks), hence 6 proofs at
  1.0e9 rather than 4 by steps.
* The 75M L2 gas per proof is 94 % of the cost (9.50 of 10.12 STRK): the proof count is still the lever.

