# G1b — chunked execution of the physics in the browser: measurements

Continuation of G1 (`REPORT.md`), 2026-09-25. All work is in `pm/spikes/wasm-vm/`; the Cairo repositories were only read.

## Verdict

Gate: a 4e7-step shot in ≤ 10 s with ≤ 1 GB per chunk. **Memory and exactness pass. Speed fails by 1.2-1.4× on this VPS.**

| criterion | result |
|---|---|
| bit-exactness | **PASS.** Chunks of K = 1, 10, 30 and 60 (native), and K = 5, 10, 20, 30 and 60 (Node and Firefox wasm), end on the same 2,050-felt state as one uninterrupted 120-tick run. A 0-tick chunk returns its input unchanged |
| memory ≤ 1 GB per chunk | **PASS.** Peak wasm memory is 300 MB (K=5) or 407 MB (K=10) with pre-sizing, and 710 MB (K=10) without. It stays flat for the whole shot in one worker, and the shot length is no longer capped (G1: one run was capped at ≈ 5e7 steps and used 2.6-3.8 GB) |
| 4e7-step shot ≤ 10 s | **FAIL.** Best configuration: **Firefox 13.6 s** (K=5, 2 runs), **Node 11.9-12.2 s** (K=10). Native cairo-vm runs the same chunks in 7.6 s. Load average was 5.5-9 on 8 vCPU during the runs |
| time to first streamed tick | 0.21-0.31 s in every configuration (the worker is preloaded) |

Chunking is the right architecture. It removes the memory wall and the growth slowdown, and it is also the resumable run R2 asked for. Of the three speed levers, only pre-sizing helps (+13 %). `wasm-opt -O3` and `talc` gain nothing.

The remaining 1.3× must come from **fewer Cairo steps per tick** (rapier), a faster VM loop (not profiled: no `perf` here), a
lower level budget (**≈ 3e7 steps fits in 10 s** in Firefox here), or a product decision to accept ≈ 12-14 s streamed
in slow motion. Measure on a real, idle laptop before deciding: this VPS was loaded throughout (see Pitfalls).

## What was built

- **`ball_drop/src/lib.cairo`** (the G1 original is kept as `lib.cairo.g1`) now has
  `main(mode, scene, steps, trace, state: Array<felt252>) -> Array<felt252>`:
  - mode 0 = G1's `simulate`;
  - mode 1 = `init(scene) -> state`;
  - mode 2 = `step_chunk(state, steps, trace) -> state'`;
  - mode 3 = build, step `steps` ticks in one world, save (the exactness reference).

  `Scarb.toml` gains `rapier_dynamics2d` (see E3).
- **`g1-runner`**:
  - `run_with(RunOpts { reserve_exec, skip_secure })` inlines `cairo_run_program`, so the execution segment can be reserved between `initialize` and `run_until_pc`;
  - `returned_array`; `parse_args` now accepts negative felts;
  - wasm `Runner.run_opts(args, onPrint, reserve, skip)` returns `{steps, memory_cells, exec_len, exec_cap, returned}`;
  - native `g1-chain` checks exactness;
  - optional feature `talc`.

  Vendored cairo-vm patch (`g1-runner/cairo-vm-reserve.patch`, +16 lines): `Memory::reserve_segment` and `segment_capacities`.
- **Harness** (`web/shot.mjs` is shared by `node/chain.mjs` and `web/chain.html`): the main thread chains the chunks.
  - "same" mode: one preloaded worker, optionally warmed up with a 1.3M-step run.
  - "fresh" mode: a new worker per chunk; the page passes it the compiled `WebAssembly.Module` and the JSON text.
  - Also: `node/fixed.mjs` (per-chunk fixed cost), `scripts/levers.py` (lever matrix), `scripts/build_wasm.py` (variants in `pkg/<variant>/`).

## State layout (`ChunkState`, `Serde`, `STATE_VERSION = 'g1b-state-1'`)

`version, tick, events, observed: Array<Handle>, gravity, integration_parameters, bodies: Array<(Handle, RigidBody)>,
colliders: Array<(Handle, Collider)>, joints: Array<(Handle, ImpulseJoint)>, pairs: Array<ContactPair>`.

This is D9's persistent world, taken from what `World` exposes publicly: `bodies.iter()`, `colliders.iter()`,
`impulse_joints.to_array()`, `narrow_phase.pairs`.
- Sleep timers live in `RigidBody.activation`.
- Warm-start impulses and event status live in each `ContactPair`'s manifold.
- Joint impulses live in `ImpulseJoint`.

Size: **1,218 felts at tick 0 and 2,050 at tick 120** for pile12 (13 bodies, 13 colliders, the contact pairs).

**Restore:**
1. `WorldTrait::new`.
2. Insert all bodies, then all colliders standalone, and assert that every returned handle equals the saved one.
3. `set` every body and collider (restores the parent links, the collider lists and the change flags).
4. Insert and `set` the joints.
5. Assign `narrow_phase.pairs`.

**Not reachable from outside the crate:** the arenas' generation counter, capacity and free list. The sets' `bodies`,
`colliders` and `joints` fields are private, although `rapier_core::data::arena` already has `ArenaState<T>` and
`from_state`. Replaying inserts therefore reproduces the handles **only if nothing was ever removed**. The real game
removes destroyed blocks and spent projectiles, so this breaks (the restore asserts `g1b: handle mismatch`).

Cost of one save/restore round trip: 73k Cairo steps at tick 0 and 110k at tick 120. With the VM setup, **≈ 47-53 ms per chunk in Node wasm**.

## Measurements

pile12 is the 12-box pile hit by a ball, 120 ticks, trace on. The table gives Cairo steps per shot including every chunk's round trip. Every row is bit-exact.

**Chaining, no speed lever** (G1 build, persistent worker "same" vs worker recreated per chunk "fresh"):

| | K | chunks | Node total | Firefox total | peak wasm / chunk | first tick (N/FF) | worst tick gap (N/FF) | steps |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| single run (mode 3) | – | 1 | 14.96 s | 15.86 s | **3,836 MB** | – | – | 39.9 M |
| same | 10 | 12 | **12.36 s** | **13.74 s** | 710 MB | 312 / 239 ms | 353 / 371 ms | 41.3 M |
| same | 30 | 4 | 12.81 s | 14.34 s | 1,350 MB | 285 / 260 ms | 516 / 590 ms | 40.5 M |
| same | 60 | 2 | 13.29 s | 14.69 s | 2,630 MB | 301 / 251 ms | 689 / 927 ms | 40.3 M |
| fresh | 10 | 12 | 21.42 s | 21.95 s | 230-710 MB | 1,273 / 1,229 ms | 845 / 785 ms | 41.3 M |
| fresh | 30 | 4 | 17.71 s | 16.62 s | 710-1,350 MB | 1,216 / 984 ms | – | 40.5 M |
| fresh | 60 | 2 | 16.42 s | 16.82 s | 1,350-2,630 MB | 1,430 / 1,218 ms | – | 40.3 M |

Native (`g1-chain`, same state, exact) runs the chunked shot in 9.9 s (K=1: 120 chunks, 53.1M steps), 7.59 s (K=10), 7.93 s (K=30) and 8.99 s (K=60), against 8.54 s for one run.

- **Memory does come back** within one worker. The wasm heap never shrinks, but the allocator reuses it, so the heap plateaus at the largest chunk's peak.
  Recreating the worker is **not needed**, and it costs +350-450 ms per chunk: wasm instantiation, JSON parse (0.3 s)
  and a cold JIT (the fresh chunks run at 2.4-2.7 M/s against 3.0-3.4 M/s).
- **The per-chunk fixed cost** (Node, `fixed.mjs`, median of 10) is 24-28 ms for a near-empty run (VM setup and the 380k-felt program copied into memory).
  A 0-tick pile12 chunk costs 47 ms at tick 0 and 53 ms at tick 120. That is +5 % of a shot at K=10 and +10 % at K=5.
- **Heavy ticks dominate:** the first 40 ticks (the impact) cost 5.4M steps per 10 ticks, and the rest cost 2-3M. The worst chunk in a shot is
  therefore the first one, so a fixed K sizes the memory by the impact.

**Speed levers.** Node, the pile12 first-10-tick chunk (5.4M steps), rates over the whole call, median of 5 interleaved rounds:

| lever | median M steps/s (min-max) | peak wasm | note |
|---|---:|---:|---|
| baseline (G1 build) | 2.69 (2.08-2.73) | 710 MB | |
| (a) reserve exec segment (700k cells/tick) | **3.05 (2.48-3.10), +13 %** | **320 MB** | 60-tick single run: 8.18/8.33 s vs 10.66/9.37 s; 1,282 vs 2,630 MB |
| (a′) skip `verify_secure_runner` | 2.54 (2.15-2.74) | 710 MB | within noise: not a lever |
| (b) `wasm-opt -O3` (binaryen 133) | 2.65 (2.12-2.83) | 710 MB | within noise; `.wasm` 1.55 → 1.27 MB |
| (c) `talc` global allocator | 2.34 (2.15-2.64) | 709 MB | slightly worse than the default dlmalloc |
| all four | 2.81 (2.21-3.01) | 303 MB | talc drags it down |
| reserve + O3 + skip (dlmalloc) | 3.03 (2.52-3.20) | 320 MB | = reserve alone |

**Best combination on the full shot** (reserve 700k cells/tick, default allocator, warmed-up persistent worker, 2 runs each):

| K | Node total | Firefox total | peak wasm | first tick (N/FF) | worst gap (N/FF) |
|---:|---:|---:|---:|---:|---:|
| 5 | 12.40 / 14.14 s | **13.63 / 13.66 s** | **300 MB** | 238 / 218-239 ms | 248 / 242 ms |
| 10 | **11.86 / 12.21 s** | 14.76 / 18.56 s | 407 MB | 234-250 / 270-281 ms | 260-297 / 264-392 ms |
| 20 | 15.06 / 15.96 s | 20.47 / 17.21 s | 620 MB | 214-312 / 321-372 ms | 333-579 / 439-795 ms |

The K=20 row is slow because its first chunk (16M steps) outgrew a reserve sized per tick. **Size the reserve from the previous chunk's
cells, not from K.** The Firefox K=10 spread (14.8 against 18.6 s) coincides with a load average of 7-9.

## Extrapolation

- **A 4e7-step shot, chunked with the best combination:** 12-14 s in Firefox and ≈ 12 s in Node on this VPS; 300-410 MB of wasm per chunk
  (plus ≈ 1.1 GB of headless-Firefox baseline). The chunked total barely depends on K between 5 and 10.
- **Largest shot under 10 s:** Firefox ≈ 3.0-3.1 M steps/s all-in, so **≈ 3e7 steps**; Node ≈ 3.4e7. Passing 4e7 needs ≈ 4 M/s all-in,
  i.e. 1.3× the measured rate.
- **Largest shot under 1 GB:** memory is now bounded per chunk, not per shot. The warmed-up worker's baseline is ≈ 190 MB (program,
  loaded executable, heap), plus 32 B per reserved cell (≈ 37 B per step at 1.15 cells/step). This matches the measured 300 MB (K=5) and 407 MB (K=10).
  1 GB therefore allows **≈ 22M steps per chunk**, and the shot length is unbounded.
  Step-budgeted chunks of 2-5M steps (≈ 265-375 MB) are the sweet spot for memory, for the tick gaps and for a per-chunk overhead below 3 %.

## Escalations for the rapier orchestrator

- **E1 (blocking for the game):** add `to_state() -> ArenaState<T>` and `from_state(ArenaState<T>)` to `RigidBodySet`, `ColliderSet` and
  `ImpulseJointSet`, wrapping the existing `rapier_core` `ArenaState`. Without it, a world in which anything was removed cannot be restored with the same
  handles, generations and free list.
- **E2:** `WorldTrait::{to_state, from_state}` with a versioned `WorldState: Serde` that owns D9's list. The game would then never re-derive which
  fields persist, and a future persistent piece (island manager, broad-phase cache, CCD) would be covered automatically. Its golden test:
  `step^n ≡ (from_state ∘ to_state ∘ step)^n`, bit for bit, on the golden scenes with removals and sleeping.
- **E3:** `Collider`, `ImpulseJoint`, `ContactPair` and the set traits are missing from `rapier2d::prelude`, so the spike had to depend on
  `rapier_dynamics2d` (moot if E2 lands).
- **E4 (perf):** the state serialises full values, static parts included (shapes, mass properties, damping and so on), at 1.2-2k felts and 73-110k steps
  per round trip. A compact form (dynamic fields only, with the static parts rebuilt from the level) would cut 2-5 % of a shot.
- **E5 (the gate):** pile12 costs 333k Cairo steps per tick on average, with 540k per tick during the impact. **1.3× fewer steps per tick passes the 10 s
  gate at 4e7 on this machine**, and it also shortens proving.

## Build commands

```sh
# once: vendor/cairo-vm/g1-runner is now a symlink to ../../g1-runner (it was a copy in G1)
(cd vendor/cairo-vm && git apply ../../g1-runner/cairo-vm-reserve.patch)   # memory.rs, +16 lines
cd ball_drop && scarb build                                                 # 380k felts of bytecode
cd vendor/cairo-vm && nice -n 10 cargo build --release -j 4 -p g1-runner    # g1-run, g1-chain
python3 scripts/build_wasm.py base                                          # pkg/base/{node,web}
python3 scripts/build_wasm.py base-o3 --wasm-opt=-O3                        # tools/binaryen (v133, sha256 checked)
python3 scripts/build_wasm.py talc --features=talc
# measure
vendor/cairo-vm/target/release/g1-chain ball_drop/target/dev/ball_drop.executable.json 3 120 1,10,30,60 --trace
node node/chain.mjs base 3 120 5,10 same 2 700000 0 1 --ref --warm   # variant scene ticks Ks mode reps rpt skip trace
node node/fixed.mjs base 10
python3 scripts/levers.py 5 10 10 700000
python3 scripts/browser_bench.py "variant=base&ks=5,10&modes=same&reps=2&rpt=700000&warm=1&ref=1" 580 chain.html
```

The argument string is `mode scene steps trace <len> <state felts…>`. G1's `node/bench.mjs`, `web/index.html` and
`scripts/native_series.py` were updated to pass `0 scene steps trace 0`.

## Pitfalls

- **The Bootloader output is `[len, values…]`**, with no panic flag (a Cairo panic aborts the run instead). G1's comment in `lib.rs` said otherwise.
- **The G1 vendored runner was a copy**, so edits to `g1-runner/` were silently not built. It is now a symlink. After the switch, `touch` the sources:
  cargo's mtime fingerprint thought the library was fresh.
- **The single uninterrupted 120-tick run (mode 3, trace off) peaked at 3.84 GB of wasm** in both engines. G1's mode-0 run of the same length
  saw 2.63 GB; the cause was not investigated (the new executable is larger and a `Vec` doubling crossed a threshold). It is one step from the
  4 GB cap, which confirms single runs are not viable.
- **Reserve by steps, not ticks.** The steps per tick vary 3× between flight and impact.
- The VPS is shared: load averages of 5.5-9 during every series and single-run spreads up to 1.5×. Medians and interleaved rounds were used.
  Absolute seconds are pessimistic for an idle machine, but the ratios between levers hold.
- The `.gitignore` rule `spikes/*/*` keeps only `REPORT.md`: **this `REPORT-G1b.md` is ignored until `!spikes/*/REPORT-*.md` is added.**
- As in G1, this session's sandbox refuses compound shell commands, so everything ran through `scripts/run.py` and Python wrappers.

## Next steps

1. **The real laptop and phone, plus Chrome** (not installed here): rerun `chain.html` with K=5-10 and a reserve. This is the gate's actual reference machine.
2. **Step-budgeted chunks in the worker:** choose K from the previous chunk's steps per tick and reserve 1.1× its cells. That bounds memory to ≈ 200 MB and smooths the tick gaps.
3. **Profile cairo-vm natively** (install `perf`): the hint dispatch (`HashMap` per pc, dict hints), `MaybeRelocatable` conversions,
   memory validation. Also cache the program's memory image across chunks (≈ 25 ms per chunk).
4. **E1/E2 with the rapier orchestrator**, then redo this spike on G0/G4 with removals, the real observer, and `main_trace` ≡ `main`.
5. **Owner decision:** either a level budget of ≈ 3e7 steps per shot, or accept ≈ 12-14 s streamed in slow motion, or wait for E5.
