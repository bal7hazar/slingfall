# E1L: prove physics ticks locally with a smaller preprocessed trace (Stwo)

Date: 2026-09-26. Author: E1L sub-agent (claude CLI, Opus 5.5) for the project-manager session.
Scope: everything lives under `pm/spikes/stwo-local/`; no other directory was modified.
Every run was sequential, inside unit `pm-E1L-local-prove-preprocessed-trace.service`
(`memory.max` = 15 032 385 536 B = 14 GiB, no swap). `systemd-run --scope` was refused by the sandbox.

## Verdict

**Yes. One physics tick is proven and verified on this VPS far under 14 GiB, with every variant.**
The results table below has the figures for each variant.

- `canonical_small`: **2.68 GiB** peak RSS, 31 s wall, verify OK.
- `canonical_without_pedersen`: 7.0 GiB.
- `canonical` (what `scarb prove` uses): 12.7 GiB. It *also* fits, contrary to the brief's expectation.

The 22 GB OOM of R1 §1 **is not the preprocessed trace**. `scarb prove` only accepts the
*bootloader* target ("only bootloader execution can be proven with `scarb prove` command").
The bootloader hashes the whole program bytecode (413 889 felts) inside Cairo with Blake2s. That
turns **1 tick into 6 659 310 Cairo steps** (60 777 `blake_compress`, 7.2M memory cells) instead
of **16 357 steps** standalone: a 407× inflation. The "fixed floor" (U1) is the program-hash
trace, and the canonical tables come on top of it. The figures agree: 12.7 GiB (canonical at
16k steps) + ~1.5 GiB/M × 6.6M ≈ 22-23 GiB, the OOM that R1 saw.

Recommended local path: **stwo-cairo's own `run_and_prove` on the standalone executable** with
`"preprocessed_trace": "canonical_small"` (no Pedersen in our programs), plus the 15-line
`vm_utils.rs` patch below. Memory is then **~2.6 GiB floor + ~1.5 GiB per million Cairo steps**.

## Results

`ball_drop` = scene 0 (one ball; it falls asleep, so steps/tick collapse after ~60 ticks).
`pile12` = scene 3 (ball + 12 boxes, the level-like proxy). Arguments `[scene, ticks, trace=0]`.
Wall is the whole `run_and_prove` (VM run + adapt + preprocessed-tree build + prove + JSON write
+ verify). "prove" is the `prove_cairo` span (trace-dependent part). Proof size: JSON ≈ 99-100 MB
for every run (verbose format). The **binary format is 1.09 MB** (measured on t1-small, prover
estimate 762-814 KB).

| run | variant | Cairo steps | wall | prove | peak RSS (ru_maxrss) | verify |
|---|---|---:|---:|---:|---:|---|
| ball_drop 1 tick | canonical_without_pedersen | 16 357 | 42.4 s | 15.4 s | **7.00 GiB** | OK |
| ball_drop 1 tick | canonical_small | 16 357 | 31.1 s (23.5 s rerun) | 14.5 s | **2.68 GiB** (2.64) | OK |
| ball_drop 1 tick | canonical | 16 357 | 58.5 s | 7.5 s | **12.73 GiB** (cgroup 13.88) | OK |
| ball_drop 10 ticks | canonical_small | 90 562 | 23.3 s | 7.4 s | 2.80 GiB | OK |
| ball_drop 60 ticks | canonical_small | 865 380 | 27.5 s | 10.6 s | 3.34 GiB | OK |
| ball_drop 300 ticks | canonical_small | 1 242 205 | 33.1 s | 15.9 s | 3.70 GiB | OK |
| ball_drop 700 ticks | canonical_small | 1 662 205 | 32.8 s | 14.6 s | 3.78 GiB | OK |
| pile12 10 ticks | canonical_small | 2 535 025 | 34.9 s | 17.3 s | 5.64 GiB | OK |
| pile12 20 ticks | canonical_small | 5 122 951 | 63.6 s | 42.2 s | **9.34 GiB** | OK |
| pile12 30 ticks | canonical_small | 7 707 907 | killed 66 s | – | ≥ 13.72 GiB (cgroup 14.00) | – |
| pile12 30 ticks, `RAYON_NUM_THREADS=1` | canonical_small | 7 707 907 | killed 221 s | – | ≥ 13.72 GiB | – |
| `scarb prove` 1 tick (bootloader) | canonical (built in) | 6 659 310 | killed 148 s | – | ≥ 13.73 GiB (cgroup 14.00) | – |
| scarb's bootloader `prover_input.json` → `prove` | canonical_small | 6 659 310 | killed 432 s | – | ≥ 13.72 GiB | – |

Notes:

- The first t1-cwp attempt proved fine (6.97 GiB). It then panicked in the verifier with
  "ECDSA segment is not empty" (left 413 892 = bytecode length + 3). Cause: `adapt()` hardcodes
  `PublicSegmentContext::bootloader_context()` (11 builtins), while scarb 2.19's standalone
  entrypoint declares only `[output, range_check, bitwise]`. The verifier therefore read program
  memory as the ECDSA pointers. Fixed by the patch below. The patch touches only public-input
  metadata, not the trace or memory.
- `RAYON_NUM_THREADS=1` does not lower the peak (same kill, 3.3× slower): memory is the trace
  columns themselves, not per-thread buffers.
- 415 of the 432 s of the bootloader-input run are spent in `prove`'s unbuffered
  `serde_json::from_reader(File)` on the 291 MB JSON. It is irrelevant for `run_and_prove`, which
  never serialises the input.
- Wall times are pessimistic. The binaries are built **without** `-C target-cpu=native`:
  the sandbox refused both the `RUSTFLAGS` env prefix and a `.cargo/config.toml`. The VPS was
  also shared with other agents (cgroup base 0.3-2.5 GiB before each run).
- Step counts differ from the rapier README (19 587 / 143 976 / 1 578 926 for 1/10/60 ticks). This
  copy is `main(scene, steps, trace)` on the current path deps (rapier alpha.2 era).

## Where the memory goes (1/10/60 series and beyond)

- **Floor ≈ 2.6 GiB with `canonical_small`**: t1 = 2.68 GiB and t10 = 2.80 GiB, for 16k-90k
  steps. It holds the preprocessed trace (10.2M cells) with its commitment, the 9 MB executable
  loaded into the VM (the bytecode is public memory: 435k cells for 16k steps) and the runtime.
  The variant alone moves the 1-tick peak from 2.7 → 7.0 → 12.7 GiB
  (10.2M / 73.3M / 543.1M preprocessed cells). For tiny traces the variant **is** the floor.
- **Slope ≈ 1.4-1.6 GiB per million Cairo steps**, stepwise because each component pads to a
  power of two:
  - (1.66M → 5.12M steps: +5.56 GiB, i.e. 1.61 GiB/M);
  - (2.54M → 5.12M: 1.43 GiB/M).
  - For comparison, R1's rule of thumb from the VDF point was ~7 GB/M. Stwo at this rev is ~4-5×
    leaner, or the VDF point included the bootloader and canonical.
- Model: **RSS ≈ 2.6 GiB + 1.5 GiB × (Cairo steps / 1M)**. It predicts 13.5 GiB at 7.7M steps,
  and that run was killed at 13.7 GiB.

## What it implies for a whole shot

- The level budget (plan v1.8) is **10.7M Cairo steps per level** on rapier alpha.2.
  - Model: ~2.6 + 1.5 × 10.7 ≈ **18-19 GiB** in one proof (component padding may push it to
    ~20 GiB).
  - It does **not** fit the 14 GiB cap of this run.
  - It should fit the 31 GB VPS if the prover runs alone. The user slice is capped at
    `MemoryMax=24G` / `MemoryHigh=22G`, which leaves little headroom next to other agents.
  - Expected wall ~2-3 min with this non-native build (5.1M steps took 64 s).
- **Chunked proving fits comfortably.** Two chunks of ~5.4M steps would take ≈ 10 GiB each;
  pile12 20 ticks = 5.1M steps measured 9.3 GiB. The G1b chunk state (`pm/spikes/wasm-vm`)
  already provides the save/restore to split a shot.
- **Upper bounds**:
  - under 14 GiB: ~7.5M steps per proof;
  - under ~22 GiB (slice `MemoryHigh`): ~12-13M steps;
  - on a 64 GB box: ~40M steps (est.).
- Proof size is flat at ~1.1 MB binary (log-scale growth; 762-814 KB estimates from 16k to 5.1M
  steps).
- **Do not use `scarb prove` for local proving**:
  - its bootloader costs ~6.6M steps per proof before any physics (≈ 10 GiB), and it gives no
    variant choice;
  - if a bootloader proof is ever required (program-hash binding, e.g. Integrity/Atlantic), the
    413 889-felt bytecode is the thing to shrink (less inlining).
  - For SNIP-36 the question is moot: the virtual OS proves contract execution, not this
    executable.

## Exact commands

Build (in `vendor/stwo-cairo/stwo_cairo_prover`, toolchain from `rust-toolchain.toml`):

```
git clone https://github.com/starkware-libs/stwo-cairo vendor/stwo-cairo
git -C vendor/stwo-cairo checkout 467d5c6
cargo build --release -j 4 -p stwo-cairo-dev-utils --bin run_and_prove --bin prove --bin verify
```

Program (in `ball_drop/`): `scarb build` produces `target/dev/ball_drop.executable.json`.
`args/t1.json` = `["0x0", "0x1", "0x0"]`; `t10` = `0xa`, `t60` = `0x3c`, etc.; `pile12-t20` =
`["0x3", "0x14", "0x0"]`.

Prove (measured through `measure.py`: `python3 measure.py <label> <log> [KEY=VAL..] -- <cmd>`;
it records `ru_maxrss` of the child and samples the cgroup's `memory.current`, because
`/usr/bin/time` was rejected by the sandbox):

```
vendor/stwo-cairo/stwo_cairo_prover/target/release/run_and_prove \
  --program ball_drop/target/dev/ball_drop.executable.json --program_type executable \
  --program_arguments_file args/t1.json --params_json params/canonical_small.json \
  --proof_path out/t1-small.proof.json [--proof-format binary] --verify
```

Sanity runs:

- `scarb prove --execute --no-build --target bootloader --arguments 0,1,0`
  (standalone is refused by scarb);
- `prove --prover_input_path target/execute/ball_drop/execution3/prover_input.json --params_json
  params/canonical_small.json --proof_path … --verify`.

Params JSON (`params/*.json`; only `preprocessed_trace` differs: `canonical_small` /
`canonical_without_pedersen` / `canonical`). All fields are required: `ProverParameters` has no
serde defaults.

```json
{ "channel_hash": "blake2s", "channel_salt": 0,
  "pcs_config": { "pow_bits": 26,
    "fri_config": { "log_blowup_factor": 1, "log_last_layer_degree_bound": 0, "n_queries": 70, "fold_step": 1 },
    "lifting_log_size": null },
  "preprocessed_trace": "canonical_small",
  "store_polynomials_coefficients": false, "include_all_preprocessed_columns": false }
```

Patch `vm_utils-standalone-context.patch` (in `crates/dev_utils/src/vm_utils.rs`). For
`--program_type executable`, it sets `input.public_segment_context =
PublicSegmentContext::new(&standalone_entrypoint.builtins)` after `adapt()`. Without it every
standalone scarb-2.19 executable fails verification.

## Build notes

- stwo-cairo rev **`467d5c6`** (exists; 2026-03-16, "Bump stwo for circle-to-line", crate version
  1.1.0). It pins stwo `aeceb74c` (2.1.0) and cairo-lang-runner/executable `=2.15.0`, which still
  read scarb 2.19.4 executables. The repository HEAD (2026-08-13) only points to
  `starkware-libs/proving`.
- Toolchain `nightly-2025-06-23` (rustup auto-installed it from `rust-toolchain.toml`).
- Build: 9 min 56 s (`-j 4`, release, **no** `target-cpu=native`, not `nice`d: the sandbox
  refused the prefixes). Rebuild after the patch: 51 s. `vendor/` is 1.6 GB.
- Files:
  - `build.sh`: not usable here, it needed an approval;
  - `measure.py`, `summarize.py` (log → steps/spans/size), `inspect_input.py` (ProverInput
    breakdown);
  - `results.txt` (raw measurements), `logs/`, `out/t1-small.proof.{json,bin}`;
  - the larger JSON proofs were deleted; `.gitignore` excludes `vendor/ out/ logs/ ball_drop/target/`.

## Follow-ups (not done)

- Rebuild with `-C target-cpu=native` for honest timings (needs approval of an env prefix).
- Measure a whole 10.7M-step level (pile12 ~42 ticks) under a ~24 GiB cap to pin the model.
- Report the `bootloader_context` hardcoding upstream (`starkware-libs/proving`) if still
  present.
