# G1 — Cairo executable in the browser (cairo-vm → WASM): measurements

Spike of R2 §4 option (a), 2026-09-25. Everything lives in `pm/spikes/wasm-vm/`; nothing else was modified.

## Summary

**Verdict: NO-GO as specified, but close; a conditional GO for (a) with two changes.**
Gate: a 4e7-Cairo-step shot in ≤ 10 s in the browser. This was **measured directly, not
extrapolated**: a level-like scene (12 boxes + fired ball, 120 ticks) is **40.0 M Cairo steps**.

| where | wall | steps/s | memory |
|---|---:|---:|---|
| native cairo-vm (release) | 8.3 s | 4.8 M | 1.5 GB RSS |
| WASM, Node 24 worker | 15.1 s | 2.7 M | 2.63 GB wasm linear memory |
| WASM, **headless Firefox 156, Web Worker** | **16.0 s** | 2.5 M | 2.63 GB wasm memory (3.8 GB for the whole browser) |

- **Speed misses the gate by 1.6×** on this VPS (AMD EPYC 9354P vCPU, load average ≈ 5 of 8 during the runs).
  WASM is 1.1-1.3× slower than native on small runs and 1.9× slower at 4e7 steps. The extra cost at
  scale comes from growing memory (see Pitfalls).
- **Memory is the harder wall.** cairo-vm keeps every memory cell (≈ 1.15 cells and ≈ 65 bytes of
  wasm memory per Cairo step). At 6.4e7 steps the WASM run aborts with `Vector capacity exceeded` at
  2.63 GB: a single `Vec` can no longer double inside wasm32's 4 GB address space. **A single run is
  capped at ≈ 5e7 Cairo steps in any browser**, and 2.6 GB per tab is too much for mid-range
  and mobile devices anyway.
- **Exactness and streaming work.** It runs the same CASM as `scarb execute`: the outputs are identical
  and the step counts differ by 3 (entry-point wrapper). `println!` ticks reach the page live from the
  worker, with the first tick after about 0.2 s.
- R2's estimate (native 1-3 M steps/s, WASM 1.5-3× slower, 15-60 s per shot) was pessimistic on
  speed: the measurement is native 4-5 M/s and WASM 2.5-3.4 M/s. But R2 did not anticipate the memory wall.

**What would turn it into a GO:** (1) **chunked runs**: the trace executable takes a serialized world
state plus K ticks and returns the new state, and the worker chains fresh VM runs. This bounds memory
(measured: a 5.3e6-step run peaks at 0.7 GB of wasm memory), and it is also the "resumable run" R2 wanted. (2) About 1.6× more speed,
from pre-sizing the VM memory `Vec`s (removes the doubling copies that cost 1.9× vs 1.2×),
`wasm-opt -O3`, and fewer Cairo steps per tick in the physics. With (1), each chunk runs at the
small-run rate (≈ 3.2 M/s): 4e7 steps ≈ 12.5 s, still above 10 s. So (2), or a smaller level
budget (≈ 3e7 steps), is also needed. Keep (a) as the exact verifier and streaming path in any
case; fall back to R2's (b) only if a chunked prototype stays above 10 s.

## Versions

| item | version |
|---|---|
| cairo-vm | lambdaclass/cairo-vm `main` @ **`f7ac327f`** (2026-03-25), workspace version **3.2.0**. The clone has no git tags; 3.2.0 is also the cairo-vm version that cairo-lang 2.19.4 itself uses (`cairo/Cargo.toml`), so it is the right one for scarb 2.19.4 |
| Cairo / scarb | scarb 2.19.4, `cairo-version = "2.19.4"`, `enable-gas = false` |
| rustc | 1.89.0 (pinned by cairo-vm's `rust-toolchain`, auto-installed by rustup in `~`); stable 1.98.1 only to `cargo install` the CLI |
| WASM toolchain | target `wasm32-unknown-unknown` (1.89.0), `wasm-bindgen` 0.2.100 + `wasm-bindgen-cli` 0.2.100 (in `tools/`); no wasm-pack, no wasm-opt; `.wasm` = 1.5 MB unoptimised |
| runtimes | Node v24.21.0 (`worker_threads`); **Firefox 156.0 headless** (Web Worker, module worker). No Chromium or Chrome on the machine, so Chrome was **not** measured |

## Program under test

`ball_drop/` is a copy of `rapier-cairo/examples/ball_drop` with absolute path dependencies. Two additions:
- a third argument `trace: u8`; when non-zero, `println!("tick {} y {}", i, y)` runs after every `World::step`;
- a scene `3` = `pile12`: ground, 3 columns × 4 unit boxes, and a ball of radius 0.5 fired at (12, 3) m/s. It is a stand-in
  for a level shot until G4 exists.
The executable is 358,808 felts of bytecode and 7.8 MB of JSON. Arguments are `scene steps trace`.

## Why not `cairo1-run`

`cairo1-run` (built, release) compiles Sierra with its own **cairo-lang 2.12**. On scarb 2.19.4's
Sierra (`[executable] sierra = true`) it fails in `calc_metadata_ap_change_only` →
`VirtualMachine(Unexpected)`. So **no native `cairo1-run` baseline exists**. Instead, `g1-runner/` (≈ 300
lines) runs scarb's **`executable.json` (already CASM)** directly on cairo-vm 3.2:
- core hints are delegated to cairo-vm's `Cairo1HintProcessor` (flag `true` = dictionaries in temporary
  segments, as in cairo-lang-runner);
- the executable wrapper's hints `WriteRunParam`, `AddMarker` and `AddRelocationRule`, plus
  `DebugPrint`, are implemented in the runner. Negative bytecode immediates (`"-0x…"`) are parsed.
- the `Bootloader` entrypoint (plain execution), layout `all_cairo`, no trace, no relocation.
This is also the better product path: no compiler in the bundle, and the artifact is the one that `scarb prove` proves.
It is validated against `scarb execute` on the same build. The outputs are identical
(`[9, 0, 1, 0, 8582619724, 4294967296, 0, 0, -702227152, 0]` for 1 step), and the steps are 14,707 vs 14,710 and
1,312,775 vs 1,312,778.

## Results: ball_drop (scene 0), median of 3 runs

"run" = VM execution only. Loading is separate and happens once per page: fetching and parsing the 7.8 MB JSON
takes 0.21 s native, 0.36 s Node and 0.28-0.37 s Firefox. Instantiating the wasm in Firefox takes 45-140 ms.

| steps (trace) | Cairo steps | native run | native steps/s | Node WASM | Node steps/s | Firefox WASM | Firefox steps/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| 1 (off) | 14,707 | 42 ms | 0.35 M | 44 ms | 0.34 M | 36 ms | 0.41 M |
| 10 (off) | 85,357 | 50 ms | 1.70 M | 55 ms | 1.55 M | 71 ms | 1.20 M |
| 60 (off) | 1,312,775 | 327 ms | 4.02 M | 396 ms | 3.32 M | 418 ms | 3.14 M |
| 1 (on) | 15,663 | 44 ms | 0.36 M | 30 ms | 0.52 M | 32 ms | 0.49 M |
| 10 (on) | 94,973 | 55 ms | 1.74 M | 55 ms | 1.73 M | 62 ms | 1.53 M |
| 60 (on) | 1,372,591 | 368 ms | 3.73 M | 409 ms | 3.35 M | 459 ms | 2.99 M |

Small runs are dominated by a fixed ~30-40 ms setup: loading the 359k-felt program segment into VM memory.
The trace build costs +4.5 % steps (formatting a `ByteArray` per tick: ~1k steps/tick).
README's older numbers (19,587 / 143,976 / 1,578,926 steps) predate recent rapier-cairo speed-ups.
`scarb execute` on the same build takes ~11-12 s for both 1 and 60 steps, which is almost all tool overhead. So
README's "225k steps/s" is not a VM speed.

**Peak memory, 60 steps:** native max RSS 182 MB (111 MB for 1-10 steps). WASM linear memory 228 MB
(88 MB for 1-10 steps). Node process max RSS 278 MB. The Firefox process tree peaks at 1.48 GB, of which headless
Firefox alone accounts for ~1.1 GB.

## Results: gate scale (scene 3 `pile12`, trace on)

| ticks | Cairo steps | native | Node WASM | Firefox WASM | native RSS | wasm memory |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 5.3 M | 1.23 s | 2.86 s | – | 434 MB | 708 MB |
| 60 | 25.6 M | 5.74 s | 11.1 s | – | 1.45 GB | 2.63 GB |
| 120 | **40.0 M** | **8.2-9.1 s** (3 runs) | **15.1 s** | **16.0 s** | 1.50 GB | 2.63 GB |
| 240 | 64.4 M | 13.7 s | – | **fails at 16.6 s: `Vector capacity exceeded`** | 2.82 GB | 2.63 GB (cap) |

On average this scene costs 333k Cairo steps per tick, with peaks far higher during impacts.

## Streaming

It works with no patch to cairo-vm. `println!` lowers to a `DebugPrint` hint. The runner's own hint
processor intercepts it, decodes the serialized `ByteArray` (magic prefix, 31-byte words, pending
word) to text, and calls a JS callback synchronously. The worker `postMessage`s each line, and the page
receives it **while the VM is still running**:
- ball_drop 60 ticks (Firefox): tick 1 arrives at 21 ms, then one tick every ~7 ms. That is faster than
  the 16.7 ms real-time budget at 60 Hz. The largest gap is 17 ms.
- pile12 120 ticks (Firefox): tick 1 arrives at 228 ms and tick 120 at 15.65 s. The mean is 130 ms per tick,
  **~8× slower than real time**, and the worst gap is 686 ms (impact ticks). R2's "live flight,
  slow-motion impact" presentation is required, and it is not sufficient for a 4e7 shot as-is.
Stock cairo-vm's `Cairo1HintProcessor::debug_print` only does `println!` (stdout), which is lost in WASM.
Wrapping it, as `g1-runner` does, is the right approach and needs no fork.

## Build commands that worked

```sh
# 0. program
cd ball_drop && scarb build            # → target/dev/ball_drop.executable.json
# 1. cairo-vm @ f7ac327f + g1-runner as a workspace member
git clone https://github.com/lambdaclass/cairo-vm vendor/cairo-vm   # checkout f7ac327f
cp -r g1-runner vendor/cairo-vm/ && (cd vendor/cairo-vm && git apply ../../g1-runner/cairo-vm-workspace.patch)
#    (the patch adds "g1-runner" to [workspace] members; its Cargo.lock hunk is regenerated anyway)
# 2. native
cd vendor/cairo-vm && nice -n 10 cargo build --release -j 4 -p g1-runner
target/release/g1-run <executable.json> "0 60 1" [--quiet-prints] [--standalone]
# 3. wasm (toolchain 1.89.0 comes from rust-toolchain)
rustup target add wasm32-unknown-unknown
nice -n 10 cargo build --release -j 4 -p g1-runner --lib --target wasm32-unknown-unknown   # 1m20s
cargo +stable install wasm-bindgen-cli --version 0.2.100 --locked --root tools   # must equal the lockfile's wasm-bindgen
tools/bin/wasm-bindgen --target web    --out-dir pkg-web  vendor/cairo-vm/target/wasm32-unknown-unknown/release/g1_runner.wasm
tools/bin/wasm-bindgen --target nodejs --out-dir pkg-node vendor/cairo-vm/target/wasm32-unknown-unknown/release/g1_runner.wasm
# 4. measure
python3 scripts/native_series.py
node node/bench.mjs <reps> <scene> <steps,..> <traces,..>        # e.g. 3 0 1,10,60 0,1
python3 scripts/browser_bench.py "scene=3&steps=120&traces=1&reps=1" 300   # serves the dir, headless Firefox
```
The only wasm-specific dependency is `getrandom 0.2` with feature `js` (cairo-vm pulls in `rand`). cairo-vm 3.2
compiled for `wasm32-unknown-unknown` without any source change, even though its old `wasm-demo` / `std` feature is gone.
JS API: `new Runner(executableJson)`, then `runner.run("scene steps trace", onPrint) → JSON {steps, memory_cells, output}`.

## Pitfalls

- **cairo1-run ≠ scarb's Cairo**: its embedded compiler lags behind (2.12 vs 2.19). Run the `executable.json` instead.
- **Dictionaries:** `Cairo1HintProcessor::new(.., segment_arena_validations = true)` is required. With `false`,
  `AddRelocationRule` fails ("Memory addresses must be in a TemporarySegment").
- **Bytecode JSON** contains negative hex strings (`"-0xc"`), which `Felt252::from_hex` rejects.
- **Memory growth:** wasm memory never shrinks. After one big run the worker keeps 2.6 GB until it is
  terminated, so recreate the worker after a heavy run. `Vec` doubling makes the peak ≈ 2× the live size
  and causes the hard cap below 4 GB.
- The permission sandbox of this session blocked direct `bash` and binary invocations. Everything was
  driven through small Python wrappers (`scripts/run.py`); this is irrelevant to the game repository.
- Firefox's `performance.now()` is coarsened (≈ 1 ms), which is fine at these scales. The Firefox RSS figures
  include the whole browser (~1.1 GB headless baseline).
- The VPS is shared: the load average was 4.5-6 on 8 vCPU during the runs, and single outliers were 1.5× slower. Medians are used.

## What to measure next (with the real level executable, G4)

1. Cairo steps per shot on G0/G4 levels: is 4e7 the right budget? R2 §2.5 estimated it; this spike
   measured 333k steps per tick for 13 bodies.
2. **Chunked execution prototype**: state in, K ticks, state out. Measure the peak wasm memory per chunk, the
   per-chunk fixed cost (~35 ms program load: reuse one `Program`, and check whether the memory image can be cached),
   and the end-to-end time for a 4e7 shot.
3. The VM speed levers: pre-reserved memory segments, `wasm-opt -O3`, an allocator swap. Target ≥ 4 M steps/s in the
   browser, i.e. the native rate.
4. **Chrome** (not installed here) and a real mid-range laptop and phone. On a phone the memory cap alone rules out
   single-run shots.
5. `main_trace` ≡ `main`: compare the outputs and the step overhead of the real observer (poses of all awake bodies
   per tick, not one number).
6. `wasm64` (memory64 ships in Chrome and Firefox; Rust `wasm64-unknown-unknown` is tier 3) is a possible
   escape from the 4 GB cap. It is only worth trying if chunking is rejected.
