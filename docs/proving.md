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
  - Each proof's public output is the state it returns, or the 10 felts for `outputs`. The next
    proof runs on it.
  - `--chunks N` sets K = ceil(ticks_run / N). `ticks_run` comes from the golden with `--case`,
    otherwise from one `scarb execute` of `main`.
  - A one-shot level gives N `step_chunk` proofs. A multi-shot level can give more, because a
    chunk never crosses a shot's end.

`--out` receives:

- the proofs (`*.proof.bin`, ~1 MB each, never committed);
- `outputs.json`: the 10 felts, the level and inputs felts, the proving executable and its
  program hash;
- `report.json`: per proof, the steps, wall time, peak RSS, proof bytes and sha256, the verify
  result, and the public output and recorded input state (the chain);
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
2. **The public output is the outputs**: the proof's output segment is `[10, outputs…]`. It is
   read twice, by `proofdata.py` from the proof file and by the binary; the two must agree.
3. **The program is the one claimed**: the proof's program hash equals `outputs.json`'s
   `program_hash`. That value is recomputed from the executable's bytecode when
   `crates/slingfall_replay/target/dev/<name>.executable.json` is present.
4. **The identity fields**: `level_hash` and `inputs_hash` are the Poseidon hashes of the level
   and inputs felts recorded in `outputs.json`.

`tools/prove/test_prove.py` holds the decoding tests. With `PROVE_RUN=<dir>`, it also runs the
tamper tests: a changed score, program hash or level felt, or a truncated proof, is rejected.

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

| executable (rapier alpha.2, this commit) | program hash |
|---|---|
| `main` | `0x6ba8179d6dc26c57e1fb681d303c986f5d074e8ee2f7d9cf8771b72cdc972cc` |
| `init` | `0x2fbad83ae98d17fde2a224b810aa5131bb845f035a5d755488682bf60d909d1` |
| `step_chunk` | `0x79a883fcc8f3aaba3a921cfc5e1453f661bf41ff7f09901a00fded757e96f7d` |
| `outputs` | `0x540e51231eb36e1d9d028c5734868262e98ed70412569117b34c2b00ddf714b` |

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

## The chunk trust model

A chunked run is `init` → `step_chunk` × n → `outputs`, each proof separate. Each proof's public
output is its returned state (a `ChunkState`: the 7-felt header, the level, the rules'
`GameState`), and the prover feeds that output to the next proof as its argument. **The binding
between two proofs is only that the next chunk's input state is the previous proof's output, and
that input is private** (see above). The proofs as they stand therefore prove less than the
whole-level proof:

- `step_chunk`'s proof says: *some* state, *some* inputs, shot and K lead to this state.
- `outputs`' proof says: *some* state and *some* inputs give these 10 felts. Its `level_hash`
  comes from the level carried in the state, and its `inputs_hash` from the inputs argument.

Nothing in the proofs ties chunk *i + 1*'s input to chunk *i*'s output, or all chunks to the same
inputs. A dishonest prover could start the last chunk from a fabricated state with a high score.
`verify.py --run` checks the links **as recorded by the prover** (`report.json`'s `input_state`
equals the previous public output). That is a consistency check for an honest prover, not a
soundness guarantee.

To make a chain sound, each `step_chunk` and `outputs` proof must commit to its input as well as
its output. The simplest form: return `poseidon(state_in)` and `inputs_hash` with the new state
(or its hash). A verifier then checks:

- `init`'s output hash is chunk 1's input hash, and each chunk's output hash is the next chunk's
  input hash;
- every chunk carries the same `inputs_hash`;
- `init`'s level is the expected level.

The prover-side scaffolding is ready (`prove.py` chains, `verify.py --run` checks links). The
executables' outputs are a Cairo change (`slingfall_replay::chunk`, `slingfall_game::chunk`),
outside P1: see its report, "Escalations". Until then, **only the whole-level proof of `main` is
a trustless proof of a level**. Chunked proofs are a memory-bounded development tool, or need a
recursive/aggregating layer that checks the links.

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
