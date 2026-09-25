# R2 — Game design and client architecture for a provable slingshot game on Cairo

Date: 2026-09-25. Author: R2 research sub-agent (claude CLI, Opus 5.5), for the project-manager session.
Scope: `PLAN.md` phases B and D. Read-only research; no repository was modified.
Figures are measured (with their source) unless marked `(est.)`.

## Executive summary

- **The engine already covers the MVP mechanics.** Launch (`RigidBody::set_linvel`), damage input
  (`World::step_with_force_events`, EV #114), end-of-shot detection (`is_sleeping`, `sleep`, SL #95),
  despawn (`World::remove_body`), per-collider materials and tags (`ColliderBuilder::{density, friction,
  restitution, contact_force_event_threshold, user_data}`) are all on rapier-cairo `main`. **RB, SE and CW
  do not block the game**: targets and out-of-bounds can be pose checks, and RB/CW only add convenience.
  The real blockers are elsewhere: **(1) `rapier2d` is not published** (the example consumes it by path,
  but the owner's rule is "registry versions only"), and **(2) the cost of a level**.
- **Cost is the dominant design constraint.** From `docs/BUDGETS.md`, an awake box costs about 35k Cairo
  steps per `World::step`. A 20-block level whose blocks wake on impact costs about 700-900k Cairo steps per
  tick, so **about 1e8 Cairo steps per shot** `(est.)`. With 10 blocks it is about 4e7. The level format,
  the end-of-shot rule and the client all have to be designed around this: blocks start asleep
  (pre-settled), a "calm" rule forces sleep instead of waiting for rapier's 2 s sleep timer, projectiles
  are removed at the end of their shot, and the MVP targets **8-12 blocks per level**.
- **Replay model:** `main(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252>`. It runs at
  60 Hz with 4 substeps (the golden-validated configuration), shot cap 360 ticks, early stop on calm or all
  asleep, 3 shots by default. That is ≤ 1 080 `World::step` calls per level, typically ~450 `(est.)`.
  Outputs: `version, level_hash, seed, player, inputs_hash, score, won, shots_used, ticks_run,
  final_state_hash`.
- **Damage** is computed from contact-force events: `damage = max(0, F − F_thr[m]) · k[m]`, where `F` is
  `total_force_magnitude` (a sum of magnitudes, so no square root) and `k[m] = dt / toughness[m]` is
  precomputed at level load. That is one fixed-point multiply per event side and no square root. HP is an
  integer.
- **Client, recommended for the MVP: (a) run the Cairo executable itself in the browser.** It runs through
  lambdaclass `cairo-vm` compiled to WASM, in a Web Worker. Per-tick poses are streamed through a trace
  variant of the same program, and rendering uses **PixiJS**. This is the only option that displays
  exactly what the proof proves by construction. **It is gated by a measurement spike (lot G1):** if a
  budgeted shot takes more than ~10 s to simulate in the browser, the planned upgrade is (b), a bit-exact
  Rust transliteration of rapier-cairo (not rapier-rs) with differential tests in CI. Option (c), "server
  replays", is rejected for play and kept only as the prover-service path.
- **Lots:** 8 lots for the game repository. **G1 (the VM-in-WASM spike) can start today** on rapier's
  `ball_drop` example. G2 (level format) and G6 (client renderer on recorded traces) can also start
  immediately. G3 (game rules) needs only what is on `main`, but needs `rapier2d` published.

## 1. Game model

Original names only (placeholders until the owner names the game): the projectile is a **pebble**, the
targets are **cores**, and the three materials are **timber**, **slate** and **frost**.

### 1.1 Feature set (MVP)

| element | MVP definition | later |
|---|---|---|
| projectile | one type, "pebble": ball r = 0.25 m, density 4, friction 0.5, restitution 0.2, damage multiplier 1 | a splitter (spawns 3 balls at `ability_tick`), a heavy one (density ×3), a boost (impulse at `ability_tick`); the input field already exists |
| blocks | cuboids and convex polygons (≤ 8 vertices, CP1/CP2), one material each, HP | round shapes (RS/SH1), joints for hinged or rope structures (already ported) |
| materials | timber: density 1, friction 0.6, restitution 0.1, HP 100, threshold 40 N, toughness 1 · slate: 2.5 / 0.8 / 0.05 / 300 / 120 N / 3 · frost: 0.9 / 0.05 / 0.2 / 40 / 15 N / 0.5 `(est., to be tuned in G8)` | per-material score, fracture into debris |
| targets | "cores": ball or small cuboid, own material (HP 30, threshold 10 N), destroyed by damage **or** by leaving the bounds | armoured cores |
| static geometry | ground half-space, fixed cuboids and polygons | one-way platforms (EV), kinematic movers (KD) |
| slingshot | anchor point `A`; input = pull vector `(px, py)` in integer units in `[-1024, 1024]²`, clamped to a disk of radius `R_pull`; launch velocity `v = −pull · launch_scale`; the pebble spawns at `A`; `delay` ticks before release (0 in MVP levels) | angle + power UI mapped onto the same pull vector |
| end of shot | (1) all dynamic bodies asleep, or (2) **calm**: every awake dynamic body has `|v|² < ε_v²` and `ω² < ε_ω²` for 20 consecutive ticks, then all bodies are forced asleep with `sleep()`, or (3) cap of 360 ticks; then the pebble is removed | – |
| scoring | destroyed block: 50 timber / 100 frost / 150 slate; core: 1 000; unused shots when won: 2 000 each; integer `u32` | style bonuses |
| win | all cores destroyed; checked after each tick, and the level stops at the end of the shot in which it happens | – |
| shots per level | level parameter, 1-5 (default 3) | – |

Pull clamping without a square root: if `px² + py² ≤ R²` (an integer compare), use the pull as is.
Otherwise scale it by `R / sqrt(px² + py²)`: one `u128_sqrt` and one division **per shot**, not per tick,
which is negligible. No trigonometry is needed. An angle-and-power UI is converted by the client into the
same integer pull, so the quantisation is visible and exact.

### 1.2 Mapping onto rapier-cairo

| mechanic | API (verified on `main` unless noted) | state |
|---|---|---|
| world, gravity, dt, substeps | `WorldTrait::new(gravity, IntegrationParameters { dt, num_solver_iterations: 4, .. })` | done (P1) |
| ground, blocks, cores, pebble | `ColliderBuilderTrait::{halfspace, cuboid, ball, convex_polygon}`, `RigidBodyTrait::{dynamic, fixed}`, `World::insert` | done (CP1/CP2) |
| materials | `ColliderBuilder::{density, friction, restitution}` | done (DB) |
| body → game entity | `ColliderBuilder::user_data(u128)` (entity index, kind, material); or a handle-indexed array in game state | done |
| launch | `RigidBody::set_linvel(Vec2)` then `World::set_body`; `apply_impulse(Vec2, wake_up)` also exists | done (on `main`). RB (wave 10, running) adds builder options (`linvel`, `ccd_enabled`, `sleeping`, `can_sleep`); nice to have, not blocking |
| damage input | `ActiveEvents::CONTACT_FORCE_EVENTS`, `contact_force_event_threshold`, `World::step_with_force_events() -> (Array<CollisionEvent>, Array<ContactForceEvent>)` | done (EV #114; golden `force_event_drop`, event step exact) |
| destruction / despawn | `World::remove_body(handle)` (detaches colliders and joints) | done. Check in G3 that neighbours are woken as upstream does (`wake_contact_partners` exists) |
| pre-settled start | `RigidBodyTrait::sleep()`; the level stores settled poses | done (SL) |
| end of shot | `RigidBody::is_sleeping()`, `linvel()`, `vels.angvel` | done |
| out of bounds | pose compare against the level AABB each tick (no sensor) | done |
| hazard / goal zones | sensors + intersection events | **SE, wave 9, running**; not needed for the MVP |
| collider API polish (setters, getters used by the editor) | – | **CW, wave 10**; not blocking (the builder covers level loading) |
| fast pebble through thin planks | CCD | **CC, wave 12, missing**. MVP mitigation: `v_max · dt ≤ t_min / 2` (e.g. 15 m/s at 60 Hz means planks ≥ 0.5 m thick) and the speculative prediction distance; measure tunnelling in G3 |
| decoration shapes (polyline terrain, compounds) | – | SH2 (wave 12), later |
| typed re-exports (`Pose2`, `Rot2`, event flag constants) | the example imports `rapier_core` / `rapier_math` directly | small prelude follow-up; ask the rapier orchestrator |
| **consumable package** | `rapier2d` is consumed **by path** even in `examples/ball_drop/Scarb.toml` | **missing: no registry release**. Owner decision needed (open question 1) |

## 2. Deterministic replay model

### 2.1 Executable

```cairo
#[executable]
fn main(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252>   // proof build
#[executable]
fn main_trace(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252> // client build
```

Both call `play<O, +Observer<O>>(level: Level, inputs: Inputs, ref obs: O) -> Outputs`. The proof build
uses a no-op observer, which compiles to nothing. The trace build uses an observer that emits the per-tick
poses of awake bodies plus the game events (damage, destruction, score) through `println!`, which a
cairo-vm hint processor can capture (§4). The physics and rules code is identical in both builds. The
client checks after the fact that `main_trace` and `main` return the same `Outputs`.

### 2.2 Level encoding

Cairo structs derive `Serde`. The felt layout is the `Serde` layout (arrays are length-prefixed). All
scalars are raw Q32.32 `i64` values serialised as felts: a negative value `-x` becomes `P - x`, the same
convention as `examples/ball_drop`.

```cairo
struct Level {
    version: u16,           // format version, echoed in outputs
    level_id: u32,          // human id; identity on-chain is level_hash
    seed: felt252,          // reserved (no randomness in the MVP); echoed
    gravity_y: Fixed,       // −9.81
    shots: u8,              // 1..5
    tick_cap: u16,          // per shot, ≤ 360
    bounds: (Fixed, Fixed, Fixed, Fixed),     // min_x, min_y, max_x, max_y (despawn AABB)
    sling_anchor: Vec2, pull_radius: u16, launch_scale: Fixed,
    projectiles: Array<u8>, // kind per shot (MVP: all 0 = pebble)
    materials: Array<Material>,
    bodies: Array<BodyDef>, // blocks, cores, statics; settled poses; dynamic ones start asleep
}
struct Material { density: Fixed, friction: Fixed, restitution: Fixed, hp: u32,
                  force_threshold: Fixed, damage_per_impulse: Fixed /* 1/toughness */, score: u32 }
struct BodyDef { kind: u8 /* 0 static, 1 block, 2 core */, shape: ShapeDef, pose: Pose2, material: u8 }
enum ShapeDef { Ball: Fixed, Cuboid: (Fixed, Fixed), Polygon: Array<Vec2>, HalfSpace: Vec2 }
```

Size: about 12 felts per cuboid block, so a 12-block level is about 200 felts `(est.)`.
`level_hash = poseidon_hash_span(serialised level)` is computed inside the executable, so the proof binds
the exact level. The contract registers the hash (§5). A JSON form, with decimal values that the tool
converts to raw Q32.32 once, is the editor's source of truth, and the felt form is generated from it (lot G2).

### 2.3 Inputs encoding

```cairo
struct Inputs { player: felt252 /* ContractAddress */, shots: Array<Shot> }
struct Shot { pull_x: i16, pull_y: i16, delay: u16 /* ticks before release, ≤ 60 */,
              ability_tick: u16 /* 0 = none; MVP ignores */ }
```

That is 4 felts per shot. `inputs_hash = poseidon_hash_span(serialised inputs)`. `player` is part of the
proven input so that a proof cannot be front-run and resubmitted by someone else (§5). Fewer shots than
`level.shots` is allowed, and `shots_used` records it.

### 2.4 Outputs

`[version, level_hash, seed, player, inputs_hash, score, won (0/1), shots_used, ticks_run,
final_state_hash]`: 10 felts. `final_state_hash` is the Poseidon hash of the raw poses of the remaining
dynamic bodies. It costs one hash at the end, and it lets CI and the client compare runs (trace build vs
proof build, WASM vs native) with one felt.

### 2.5 Tick rate, substeps, trace bounds

| parameter | value | why |
|---|---|---|
| dt | 1/60 s (`raw 71582788`) | every golden scene is validated at 1/60; halves tunnelling vs 30 Hz |
| substeps | `num_solver_iterations = 4` | rapier default, golden-validated; this is the main gas lever (`PLAN.md` D8) |
| tick cap per shot | 360 (6 s) | a shot settles in 2-4 s; the cap bounds the worst case |
| calm rule | `|v|² < (0.05 m/s)²`, `ω² < (0.05 rad/s)²` for 20 ticks, using fused `dot` (no sqrt), then `sleep()` all | rapier's own timer waits ~2 s (120 awake ticks) before sleeping: the single largest avoidable cost |
| despawn | pose outside `bounds`, then `remove_body`; for a core, this counts as destroyed | keeps bodies falling off-screen out of the solver |
| pebble removal | at the end of its shot | the next shot's flight phase stays cheap |
| level stop | all cores destroyed, or shots exhausted | – |

Expected `World::step` calls: **per shot ≤ 360 + delay, typically 150-200** (60-90 ticks of flight, a
~40-80 tick impact phase, 20 ticks of calm) `(est.)`. **Per level ≤ 1 080 (3 shots), typically ~450**
`(est.)`.

Cairo steps, derived from `BUDGETS.md` (cuboid stack ≈ 34-35k steps per awake box per step; sleeping
stack of 10 ≈ 25k steps per step; free fall ≈ 5.6k per body):

| level size | flight (≈75 ticks, blocks asleep) | impact + calm (≈100 awake ticks) | per shot | per level (3 shots) |
|---|---:|---:|---:|---:|
| 8 blocks + 2 cores | ~2.5e6 | ~3.5e7 | **~4e7** | ~1.2e8 |
| 12 blocks + 3 cores | ~3e6 | ~5e7 | **~5e7** | ~1.6e8 |
| 20 blocks + 3 cores | ~4e6 | ~8e7 | **~1e8** | ~3e8 |

All of these are `(est.)`. They assume the whole island wakes. Localised impacts that wake only part of the
structure cost less. These numbers are the input R1 needs for proving time. G0 (the rapier-side
level-shaped scene) must replace them with measurements. Levers, in order: fewer awake bodies (level
design), a tighter calm rule, 3 substeps, 30 Hz ticks (halves everything, raises tunnelling risk).

## 3. Damage model in fixed point

What rapier-cairo gives (`rapier_dynamics2d/src/events.cairo`, EV #114): one `ContactForceEvent` per pair
per step, in ascending pair order, when the pair's total force exceeds the minimum enabled threshold of its
two colliders. The event carries `total_force_magnitude`, which is **the sum of the per-point normal-force
magnitudes (impulses / dt), not a vector length**, together with `max_force_magnitude`, `total_force` and
`started`. No square root is needed to use it.

Rule, applied after each `step_with_force_events`:

```
for e in force_events:                        // ascending pair order: deterministic
  for side in [collider1, collider2]:
    m = material(side); if side is static/pebble: continue
    excess = e.total_force_magnitude − m.force_threshold        // Fixed sub
    if excess > 0: hp[side] −= floor(excess · m.damage_per_impulse_dt)   // 1 Fixed mul + 1 div_rem
  destroyed ⇐ hp ≤ 0 → remove_body at the end of the tick (after the loop, ascending handle order)
```

- **Force vs impulse:** `F · dt` is the normal impulse. Folding `dt` into the per-material constant
  (`damage_per_impulse_dt = dt / toughness`, computed once at load) makes damage proportional to the
  **impulse above a force threshold**, which is framerate-honest and costs one multiply.
- **Thresholds:** each collider's `contact_force_event_threshold` is set to its material's
  `force_threshold`, so rapier emits no event for resting contacts. The game re-applies each side's own
  threshold, because rapier fires on the minimum of the two. The level validator (G8) checks that a
  pre-settled level takes **zero damage over 120 ticks at rest**. Tall stacks can put the bottom block
  above its threshold under static load.
- **Pebble multiplier (later):** scale `excess` for pairs involving the pebble. `user_data` identifies it.
- **Determinism:** only `Fixed` add, sub and mul (floor rounding, `fixed` DESIGN §2), integer HP, and a
  fixed iteration order (event order, then removals in ascending handle order). There are no floats and
  no hash-map iteration.
- **Cost:** events only fire for above-threshold pairs, so this is a few hundred steps per event
  `(est.)`, negligible next to the solver. EV measured ≤ +1.05 % step overhead with events on.
- **Rejected:** kinetic-energy deltas per body (these need `|v|²` for every body every tick, and mix
  gravity and solver effects) and damage from `max_force_direction` (it needs a length).

## 4. Client architecture

The requirement is that the client displays exactly what the proof proves. The proof is of the Cairo
program, so the displayed state must be produced by bit-identical arithmetic.

### (a) Run the Cairo executable in the browser (a Cairo VM compiled to WASM)

| VM | status (2026-09) | fit |
|---|---|---|
| lambdaclass `cairo-vm` (Rust) + `cairo1-run` | the reference Rust VM; builds for `wasm32` (changelog: "wasm with cairo1" in v3 releases; an `examples/wasm-demo` exists); runs Cairo 1 programs compiled without gas (same as our `enable-gas = false`); custom hint processors are supported | **best candidate** |
| `cairo-vm-ts` (kkrt-labs) | README: "genesis", "not suitable for production", no package release | no |
| `wasm-cairo` (community), `cairo-rs-wasm` (lambdaclass, old demo) | toolchain-in-browser experiments, old versions | no |
| `cairo_native` (lambdaclass, Sierra → MLIR → LLVM, JIT/AOT) | fast native execution; **no documented wasm target** | worth a question upstream; not an MVP path |

- **Exactness:** exact by construction. The same CASM runs on the same VM semantics as `scarb execute`,
  so `Outputs` can be compared felt for felt.
- **Intermediate state:** yes, through the trace build (§2.1). `println!` lowers to a debug-print hint,
  and a hint processor in the worker forwards each tick's poses to the renderer as they are produced. This
  streams output; the client does not have to wait for the end of the run.
- **Performance:** this is the crux. The only local evidence is `examples/ball_drop/README.md`:
  `scarb execute` of 60 steps (1.58 M Cairo steps) took 28.0 s against 21.1 s for 1 step. That is
  ~225k steps/s *including* trace and file output. Native `cairo-vm` without a trace is plausibly
  1-3 M steps/s `(est.)`, and WASM 1.5-3× slower `(est.)`. **A 4e7-step shot would therefore take about
  15-60 s in the browser `(est.)`.** The flight phase (~30k steps per tick) streams at or above real time.
  The impact phase (~350-500k steps per tick) runs 5-15× slower than real time.
- **Latency is partly hideable:** the flight plays live, and an "impact slow-motion" presentation (a
  genre convention) covers the heavy ticks. Beyond ~10 s per shot the game feels broken.

### (b) Rust port of the fixed-point engine to WASM, bit-exact against Cairo

- It must transliterate **rapier-cairo**, not use rapier-rs. rapier-rs is f64 and matches the port only
  within tolerance (D11), and chaotic stacks diverge visibly within seconds. The transliteration needs
  Q32.32 with the same floor/nearest rounding (`fixed` DESIGN §2), the same fused-kernel rescale points,
  the same contact order (D8), the same sleep and island rules, and the felt252 paths (SC's sleep timer).
- **Speed:** native, microseconds per step, so live physics and live aim previews are possible.
- **Divergence risk:** high at creation, then controlled through differential CI: random levels and
  inputs, comparing `final_state_hash` and per-tick hashes against `scarb execute` on every rapier-cairo
  or game release.
- **Maintenance cost:** high and permanent. rapier-cairo is still in waves 9-14 and changes numeric
  results with each MINOR. Each change must be mirrored, and a single missed rounding change is a silent
  desync. Rough size: the numerically essential core is about 2k lines upstream; the Cairo port is far
  larger `(est.)`.

### (c) Server replays, client renders

- A server runs the executable (native `cairo-vm` or `scarb execute`) and sends back the trace. It is
  exact and simple to build.
- It has the same compute cost as (a), only faster hardware, plus a network round trip. It centralises
  play and contradicts "played locally" (CONTEXT goal 1).
- It is useful as the **prover-service front end** (the service must execute anyway), and as an optional
  fast path for weak devices.

### Recommendation for the MVP

1. **(a) with a measurement gate.** Lot G1 builds `cairo-vm` + `cairo1-run` for `wasm32` in a Web Worker
   and runs rapier's `ball_drop` and then G0's level scene. It reports steps/s in Chrome and Firefox and
   the streaming latency. **Gate:** a budgeted shot (≤ 4e7 steps) simulated in ≤ 10 s on a mid-range
   laptop.
2. If the gate fails, **(b) becomes phase 2 of the client**, with (a) kept as the verifier that re-checks
   `final_state_hash` in the background. Levels are also shrunk, which helps proving too.
3. **Aim preview without the physics engine:** the pebble's flight until first contact is a
   semi-implicit Euler integration under constant gravity. The client reproduces it exactly in TypeScript
   `BigInt` with the same Q32.32 floor rounding, which is a few lines against rapier's `integrate`
   (verified by a golden test against the trace build). The trajectory dots are therefore exact, and no
   non-authoritative preview is ever shown for the collision phase.
4. **Rendering stack:** TypeScript + Vite, **PixiJS v8** (WebGL/WebGPU 2D sprites, mature and light) for
   the scene, and a thin UI layer (plain DOM or React) for menus and the wallet. Bevy-WASM was rejected:
   it has a large bundle, the physics is not in Rust anyway, and it gives no benefit for 2D sprites.
   Poses arrive as raw Q32.32 and are converted to `f64` only for drawing. Rendering interpolates between
   ticks for 120 Hz displays, which is cosmetic only.
5. **Interaction loop:** load the level (fetch JSON + felts, check `level_hash` against the contract) →
   drag to aim (quantised pull, exact arc) → release → the worker runs `main_trace(level, shots_so_far)`
   and streams ticks → animate (live flight, slow-motion impact) → score UI → next shot … → end of level:
   the client holds `inputs`, and its `Outputs` must equal the proof build's outputs.
   Re-running from tick 0 for each shot costs 1+2+3 = 6 shot-equivalents for a 3-shot level. G1 measures
   whether this matters. The alternative is a resumable run (a hint that blocks on the next shot through
   `Atomics.wait`), which is a spike item, not MVP.

## 5. Proof user flow (the interface the client needs)

This assumes R1 settles the verifier and the prover location; the client talks to either through one
interface.

1. **Prove.** The client produces `args = [level felts, inputs felts]` and calls one of:
   - **local:** a native CLI or desktop helper, `game-prove --level L.json --inputs I.json`
     (`scarb execute` + `scarb prove` on the proof build). A browser cannot run Stwo on a 1e8-step trace:
     proving one step already needed more than 22 GB (CONTEXT).
   - **service:** `POST /prove {program: "game_replay@<version>", args}` → `job_id` → poll → `{proof,
     outputs}`.

   In both cases the client first checks that the returned `outputs` equal its own trace-build outputs.
2. **Submit.** The wallet signs `GameRegistry.submit(proof_or_fact_ref, outputs)`. The wallet is
   starknet.js + get-starknet (Argent X / Braavos) by default; Cartridge Controller (session keys) is an
   owner choice (open question 5).
3. **The contract checks, and never re-simulates:**
   1. the proof verifies (or its fact is registered) for `program_hash == GAME_PROGRAM_HASH[version]`,
      the registered executable;
   2. `outputs.level_hash` is a registered level;
   3. `outputs.player == get_caller_address()`, which is anti-front-running;
   4. the nullifier `poseidon(level_hash, player, inputs_hash)` has not been used before;
   5. `won` / `score` are recorded; the player's best score updates only if it is higher; an event is
      emitted with `inputs_hash`. The inputs are optionally included in calldata so that others can
      replay the run.
4. **Reads the client needs:** `level(level_hash) -> (uri, version, active)`,
   `best(player, level_hash) -> (score, won)`, `leaderboard(level_hash, n)`.

## 6. Lot plan for the game repository

Working name `game`. One sub-agent and one PR per lot. It depends on `fixed`/`glam` 0.3.0 and on
`rapier2d` (see open question 1).

| lot | content | depends on | can start before RB/SE/CW merge? |
|---|---|---|---|
| **G1** VM-in-WASM spike | build `cairo-vm` + `cairo1-run` for `wasm32`; Web Worker harness; run `rapier-cairo/examples/ball_drop` (then G4's executable); hint processor capturing `println!`; measure steps/s (Chrome, Firefox, native), memory, streaming latency; **go/no-go report for option (a)** | none | **yes, today** |
| **G2** level and input format | Cairo structs + `Serde` layout (§2.2-2.3), `level_hash` / `inputs_hash`, JSON schema, a converter (Python or TS) JSON ↔ felts with decimal → raw Q32.32, round-trip tests, 3 fixture levels | none | **yes** |
| **G3** game rules library | world builder from `Level` (shapes, materials, `user_data`, pre-slept bodies), slingshot (clamp, launch), damage (§3), despawn, calm rule, pebble removal, scoring, win; snforge tests + gas per tick; tunnelling check at `v_max` | G2; `rapier2d` consumable | yes: needs only `main` APIs (`set_linvel`, `step_with_force_events`, `sleep`, `remove_body`) |
| **G4** replay executables | `main` / `main_trace` (§2.1), `Observer` trait, outputs (§2.4), `scarb execute` on the fixtures, **Cairo steps per shot and per level measured**, replacing §2.5's estimates | G3 | yes |
| **G5** determinism and budget CI | golden `(level, inputs) → outputs` snapshots, trace build ≡ proof build, input fuzzing (random pulls), per-level step ceilings (+10 %) in the style of `gas.py` | G4 | yes |
| **G6** client renderer | Vite + TS + PixiJS; renders a recorded trace (JSON from `main_trace` via `scarb execute`) with placeholder assets; aim UI with quantised pull and the exact BigInt arc; later swaps the trace source to the G1 worker | G2 (format); G1 for live mode | **yes** (on recorded traces) |
| **G7** Starknet contract | level registry, `submit` with checks (§5) behind a `Verifier` interface (stub until R1 lands), nullifiers, best score, events; client read API; snforge tests | G4 (output layout); R1 for the real verifier | yes (stub verifier) |
| **G8** content and editor tooling | pre-settle tool (runs `main_trace` with no shots until asleep, writes settled poses), level validator (zero damage at rest, step budget), 5 MVP levels of 8-12 blocks, material tuning | G4, G6 | yes |

Critical path: G2 → G3 → G4 → G5/G7 → the end-to-end demo. G1 and G6 run in parallel from day one.
Nothing in the game needs RB, SE or CW merged. It needs **a published `rapier2d`** (or an owner
exception) before G3 is merged, and G0's measurements before G8 fixes the level sizes.

## Recommendation

1. Adopt the game model in §1 and the replay model in §2: 60 Hz, 4 substeps, cap 360 ticks per shot, the
   calm rule with forced sleep, pre-settled sleeping levels, pebble removal, player-bound inputs, and a
   10-felt output. **Target 8-12 blocks per MVP level** until G0/G4 measure the real cost.
2. Damage from `ContactForceEvent.total_force_magnitude` with per-material threshold and
   `dt / toughness` folded into one constant: no square root, one multiply per event side.
3. Client: **option (a), cairo-vm in WASM, streaming the trace build, rendered with PixiJS**, with an exact
   BigInt flight preview. Gated by G1 (≤ 10 s per budgeted shot). Fallback (b), a bit-exact Rust
   transliteration with differential CI, is planned only if the gate fails. (c) only as the prover-service
   front end.
4. Start **G1, G2 and G6 now**. They do not wait for rapier waves 9-10, nor for R1.
5. Ask the rapier orchestrator for a `rapier2d` registry release, or get an owner exception, before G3
   merges. Also ask for prelude re-exports (`Pose2`, `Rot2`, event flag constants).

## Open questions for the owner

1. **Consuming `rapier2d`:** it is unpublished and path-only today. Options: publish `rapier2d`
   0.1.0-alpha (and its crates) now, or allow the game a git-rev pin until phase 2 closes. The first
   respects the "registry versions only" rule.
2. **Level size vs proving cost:** accept 8-12 blocks per MVP level (~4-5e7 Cairo steps per shot
   `(est.)`) pending R1's prover throughput?
3. **Client latency:** is a "simulating…" slow-motion impact of up to ~10 s per shot acceptable for the
   MVP, or is live physics required? Requiring it forces option (b) and its permanent maintenance cost.
4. **Tick rate:** keep 60 Hz (golden-validated, safer against tunnelling), or trade it for 30 Hz to halve
   proving cost before CCD (CC, wave 12) exists?
5. **Wallet:** starknet.js + get-starknet (Argent X / Braavos), or Cartridge Controller (session keys,
   game-oriented)?
6. **Game name and asset direction**, which is needed before G6 leaves placeholder assets.
7. **Inputs on-chain:** publish the full inputs in calldata (anyone can replay a record) or only
   `inputs_hash`?

## Uncertainties

- The VM throughputs (native and WASM) are estimates. The only local measurement includes `scarb` overhead
  and trace writing. G1 exists to replace them.
- The per-level Cairo-step figures extrapolate `BUDGETS.md` marginals to mixed-material, partly awake
  piles. They assume the whole island wakes. Polygons cost more per pair than cuboids.
- I did not check whether `remove_body` wakes contact partners as upstream does. G3 must test it.
- Stwo's handling of the debug-print hint is irrelevant by design, because the proof build has no prints.
  Whether `cairo1-run`'s WASM build accepts a custom hint processor for print hints is to be confirmed in G1.
- R1's report was not available when this was written. §5 assumes a verifier that can bind a program hash
  and expose the public output.

## Sources

Local (read-only, 2026-09-25):
- `pm/CONTEXT.md`, `pm/PLAN.md` (§1, §2 phases B and D)
- `rapier-cairo/README.md`; `docs/PLAN.md` (§2 D1-D12, phase 2 status and wave table incl. EV/SL/KD/CP);
  orchestrator worktree `docs/PLAN.md` (waves 9-14: SE, RB, CW, SH1, QY, CC, SH2, …) and
  `docs/API_PARITY.md` (coverage 24.3 %, 486/2 738 items)
- `rapier-cairo/crates/rapier2d/src/lib.cairo` (prelude), `crates/rapier2d/src/world.cairo`
  (`step`, `step_with_force_events`, `remove_body`, `body`/`set_body`, queries)
- `rapier-cairo/crates/rapier_dynamics2d/src/events.cairo` (`ContactForceEvent` fields and semantics),
  `rigid_body_set.cairo` (`set_linvel`, `apply_impulse`, `is_sleeping`, `RigidBodyBuilder`),
  `collider/builder.cairo` (`density`, `friction`, `restitution`, `sensor`, `user_data`,
  `contact_force_event_threshold`), `rapier_core/src/integration_parameters.cairo` (dt 1/60, 4 iterations)
- `rapier-cairo/crates/rapier2d/tests/golden_scenes/events.cairo` (golden `force_event_drop`, `one_way_jump`)
- `rapier-cairo/docs/BUDGETS.md` (gas and Cairo steps per scene, 2026-09-24 evening)
- `rapier-cairo/docs/briefs/ev-events-one-way.md`; worktree briefs `se-sensors.md`, `rb-rigid-body-api.md`
- `rapier-cairo/examples/ball_drop/{src/lib.cairo, README.md, Scarb.toml}` (executable layout, execute
  timings, path dependency on `rapier2d`)
- `fixed-cairo/docs/DESIGN.md` (Q32.32 range, rounding, determinism, versioning); `glam-cairo/README.md`

Web:
- [lambdaclass/cairo-vm](https://github.com/lambdaclass/cairo-vm), [CHANGELOG](https://github.com/lambdaclass/cairo-vm/blob/main/CHANGELOG.md),
  [cairo1-run README](https://github.com/lambdaclass/cairo-vm/blob/main/cairo1-run/README.md), [releases](https://github.com/lambdaclass/cairo-vm/releases)
- [kkrt-labs/cairo-vm-ts](https://github.com/kkrt-labs/cairo-vm-ts)
- [lambdaclass/cairo_native](https://github.com/lambdaclass/cairo_native)
- [lambdaclass/cairo-rs-wasm](https://github.com/lambdaclass/cairo-rs-wasm), [cryptonerdcn/wasm-cairo](https://github.com/cryptonerdcn/wasm-cairo)
