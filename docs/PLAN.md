# Execution plan

Status: **v1.9, 2026-09-26** (v1: bootstrap; v1.1: B0 #1 and G6 #2 merged; v1.2: G2 #3 merged, Pose2 swap, wave 2 G3 + G7 launched; v1.3: G1c #4 merged, wave 1 complete; v1.4: G7 #5 merged; v1.5: G3 #6 merged, wave 3 G3b + G4 launched; v1.6: G3b #7 merged (spent-pebble rule); v1.7: G4 #8 merged, milestone M4, wave 4 launched; v1.8: G6b #9 merged (live client); v1.9: G4b #10 merged, class-size blocker found, G7b launched, G5 running) (owner of this file: the `slingfall` orchestrator session).
Programme context: `/home/claude/projects/pm/PLAN.md` phase D. Design: `docs/DESIGN.md`.

## Target

Play a level in the browser, produce the proof, submit it, see the level validated on Starknet
Sepolia (programme milestone M6). Intermediate: M4 = a level replays deterministically (G4 + G5);
M5 = a level proof verified on Sepolia (G7 + E2).

## Lots

One executor, one PR per lot. Crate names are final; module stubs are pre-declared by the
orchestrator before each wave.

| wave | id | lot | model | depends on |
|---|---|---|---|---|
| 0 | B0 ✅ #1 | bootstrap: workspace, crates and stubs, `client/` skeleton, CI, `scripts/` (executor, steps snapshots), PR template, `.tool-versions`, dependency pin | Opus | – |
| 1 | G2 ✅ #3 | `slingfall_level`: `Level` / `Material` / `BodyDef` / `ShapeDef` / `Inputs` / `Shot` / `Outputs` (D2-D4), Serde layouts, `level_hash` / `inputs_hash`, JSON schema + `tools/levelc` converter (Python, decimal → raw Q32.32, round trip), 3 fixture levels (`fixtures/levels/*.json` + felts) | Sonnet | B0 |
| 1 | G6 ✅ #2 | `client/`: Vite + TS + PixiJS renderer of a recorded trace (JSON emitted by `main_trace` via `scarb execute`), placeholder assets, aim UI with the quantised pull and the exact BigInt arc; trace source behind an interface (recorded now, worker later) | Sonnet | B0 (fixture trace from `docs/research/03`'s scene until G4) |
| 1 | G1c ✅ #4 | `client/vm/`: the chunked cairo-vm worker as a reusable TS package, from the spike `pm/spikes/wasm-vm/` (runner crate vendored under `client/vm/runner/`, wasm build script, step-budgeted chunking, memory reservation, `println!` streaming), tested on the spike's executable | Opus | B0 |
| 2 | G3 ✅ #6 | `slingfall_rules`: world builder from `Level` (shapes, materials, `user_data`, pre-slept bodies), slingshot (clamp, launch), damage (D6), despawn, calm rule (D5), pebble removal, scoring and win (D7); snforge tests; steps per tick; tunnelling check at `v_max` | Opus | G2, `rapier2d` alpha |
| 2 | G7 ✅ #5 | `slingfall_contract`: level registry, `simulate` (D9) behind a `Verifier` interface stubbed until E2, `submit` checks, nullifiers, best score, events; snforge tests | Opus | G2 (layouts); G3 for `simulate`'s body (stub first) |
| 3 | G3b ✅ #7 | rules follow-up: spent-pebble rule (D5, replaces the damping first measured: 1.0 / 4.0 ended every shot but killed the range), un-ignore the whole-shot tests under the raised step cap, `level.projectiles` read (kind 0 only), static-load note for G8 | Sonnet | G3 |
| 3 | G4 ✅ #8 | `slingfall_replay`: `main`, `main_trace` (observer emitting **trace format v1** of `client/README.md`: level header with `gravity_y`, `launch_scale`, `pull_radius`, `shots`, per-body `pose`; frames with `asleep`; events `damage` / `destroyed` / `score` / `shot_end`; semantics fixed by G6: a handle absent from `level.bodies` is the pebble, a dynamic body absent from a frame no longer exists, shots left = `level.shots` minus `shot_end` events, ticks strictly increase), `init` / `step_chunk` on `WorldState` (D1); assert `client/src/aim/arc.ts`'s flight formula against rapier's `integrate` on a free-flying pebble; `scarb execute` on the fixtures; **Cairo steps per shot and per level measured** and written here | Opus | G3 |
| 4 | G4b ✅ #10 | replay logic as a library crate `slingfall_game` shared with the contract, non-test fixtures export, hook through `play` (G4 / G7 escalations) | Sonnet | G4 |
| 3 | G5 | determinism and budget CI: golden `(level, inputs) -> outputs` snapshots, trace ≡ proof ≡ chunked outputs, input fuzzing, per-level step ceilings (+10 %) | Sonnet | G4 |
| 4 | G8 | content and editor tooling: pre-settle tool, level validator (zero damage at rest over 120 ticks, step budget), 5 levels of 8-10 blocks, material tuning | Sonnet | G4, G6 |
| 4 | G6b ✅ #9 | client live mode: G1c worker runs `step_chunk` per shot, slow-motion impact presentation, score UI | Opus | G1c, G4, G6 |
| 4 | G7b | **class size**: the `Slingfall` class is 201 974 Sierra felts / 11.7 MB vs Starknet's 81 920 / 4.09 MB: decompose (registry, level, rules, one step, simulate), measure the levers (reachable shape pairs, inline policy, two-class layout, scarb inlining strategy), numbers for rapier | Opus | G4b |
| 5 | E2 | SNIP-36 round trip on Sepolia: `simulate` proven with `snip36 prove virtual-os`, `submit` consuming `proof_facts`; needs a funded Sepolia account and a ≥ 32 GB prover box (owner) | Opus | G7, G4 |
| 5 | G9 | client submission flow: Cartridge Controller / get-starknet, prove request (local helper or service), `submit` transaction, validation status reads | Opus | E2, G6b |

Critical path: B0 → G2 → G3 → G4 → G5 → E2 → G9. G6, G1c, G7 run in parallel from wave 1-2.

## Budgets

| quantity | target | measured |
|---|---|---|
| Cairo steps per shot | ≤ 3e7 (interim ≤ 1e8 until rapier's BT lands) | **G4 `scarb execute`: pile10 reference shot 31.5M (191 ticks), 3-shot level 47.4M (431 ticks), cores3 3 shots 19.6M, one_block miss 2.5M**; a pile10 miss 7.1M; flight tick 56k, impact tick 1.02M (before rapier BT1); pile12 (12 boxes + ball, 120 ticks): 40.0M (`docs/research/04`); rapier G0 (#133): 10-block level, 300 ticks, 60 Hz x4 = 204M, x1 substep 103M, 30 Hz x4 = 79M / 150 ticks; a settled structure never re-sleeps in 300 ticks, so the calm rule (D5) is essential |
| Cairo steps per tick, 13 bodies | – | 333k average, 540k during impact |
| `WorldState` round trip (pile10) | – | 1 864 felts, 52k steps (rapier #131) |
| browser, 4e7-step shot, chunked | ≤ 10 s | 12-14 s (Firefox, loaded VPS) |
| proven transaction | ≤ 1.1B L2 gas ≈ 9M steps | – |
| `Slingfall` class size | ≤ 81 920 Sierra felts, ≤ 4 089 446 bytes | **201 974 felts, 11 725 481 bytes** (2026-09-26): blocks declaration, hence E2 / M5; G7b |

## Escalations sent

- 2026-09-25 to rapier (via pm): pre-slept bodies wake on insertion (settle-step workaround); cheap `is_sleeping` / `vels` reads (G3).

## Merged lots

| lot | PR | notes |
|---|---|---|
| B0 | #1 | workspace, client skeleton, CI, executor tooling; `rapier2d = "=0.1.0-alpha.1"` |
| G2 | #3 | level / inputs / outputs, `levelc` with a stdlib Poseidon matching Cairo, 3 fixtures, 55 + 15 tests; hash of pile10 = 5.8k steps; orchestrator follow-up: `Pose2` / `Rot2` now `pub use rapier2d::prelude` (felt layout unchanged) |
| G4b | #10 | `slingfall_game` library crate (play, chunk, fixtures), replay = 4 thin executables, contract hook through `play`, `levelc to-cairo --check`, level fixtures public; steps identical (31 487 873); finding: **the contract class exceeds Starknet's limits** (201 974 felts vs 81 920; 11.7 MB vs 4.09 MB) |
| G6b | #9 | live client: `init` once, `step_chunk` per shot, streamed frames / events, slow-motion impact, end panel with the 10 output felts + copy inputs; worker run of the reference shot ≡ native `main_trace` bit for bit; release → first frame 77 ms, shot 10.3 s in Node, peak wasm 300-350 MB; 142 client tests; D8 sizing amended (K ≤ 20, 5M-cell floor). Follow-ups: move the `outputs` executable into `crates/slingfall_replay` (G4b or G4c), CI rebuild check of the 28 MB committed executables, run `browser-check.py` where Firefox can launch |
| G4 | #8 | four executables (`main`, `main_trace`, `init`, `step_chunk`) on one `play<O: Observer>`; chunk chains bit-exact (K = 1, 7, 60; delay cut across chunks); contract `ActiveHook` = real replay with a golden; reference trace generated by `tools/tracec`; **pile10 reference shot 31.5M steps (191 ticks), 3-shot level 47.4M (431 ticks), cores3 3 shots 19.6M, miss 2.5M**; `play` overhead 0.012 %, trace +6 to +17 %, chunk round trip 136k; CI smoke step fixed by the orchestrator. Follow-ups: G4b (library split, fixtures export) |
| G3b | #7 | spent-pebble rule (no damping; first contact with a block / core or 120 flight ticks), projectile kind read, whole-shot tests un-ignored (53 tests, 1 min 16 s); reference shot **32.1M steps, calm end at 191** (was 43.2M / 334), no shot ends on the cap any more, a miss costs 7.1M; `GameState` gained 2 felts (`pebble_contact`, `pebble_contact_tick`): **G4 must regenerate its state fixtures**; level authors: `tick_cap` ≥ ~140 |
| G3 | #6 | rules: builder with settle step, sling (bit-exact with the client), D6 damage, calm / cap / bounds, score, `GameState` round trip bit-exact; rules overhead 2 % at impact, 7.6 % in flight; reference shot 43.2M steps (calm end at 334); 3 whole-shot tests `#[ignore]`d by the 10M-step cap (raised to 400M in `Scarb.toml`, G3b un-ignores); findings escalated to rapier (pre-slept wake, cheap `is_sleeping`) and to design (rolling pebble -> damping) |
| G7 | #5 | `Slingfall` contract: registry (flat map, 91k steps for pile10), `simulate` behind `ActiveHook` (G4 swaps one line), `submit` 9k steps net, `Snip36Verifier` tested with `start_cheat_proof_facts`, `StubVerifier` ECDSA attestation, 40 tests. Deferred: upgradeability, attestation domain separation (stub path only), facts layout confirmation (E2). Follow-ups (orchestrator): hoist `submit::errors` / contract module in `lib.cairo`; shared non-test level fixtures export |
| G1c | #4 | `client/vm/` runner crate (cairo-vm git dep `f7ac327f` + reservation patch via `vendor.sh`), worker + `WorkerTraceSource`, sizing rule; 3.68M steps/s first chunk, 410 MB peak, first tick 0.22-0.3 s, whole pile12 shot 12.4 s bit-exact; CI job `vm` (3m30s cold, cached) kept **outside** `all-checks` until G6b; 91 client tests. Follow-ups: cairo-vm patch home (upstream or `bal7hazar/cairo-vm` branch); worker untested in a browser (G6b) |
| G6 | #2 | renderer + aim UI, 65 tests, ~150 kB gz; not verified in a browser (no Firefox in the executor sandbox); trace format v1 in `client/README.md`; D3 clamp rounding amended |

## Open points

- `outputs` executable lives in `client/vm/fixtures/outputs/` (path deps): move it to `crates/slingfall_replay` as a 5th target; committed replay executables (28 MB JSON) need a CI rebuild-and-diff step or an in-job build.

- Executors cannot read files outside the repository checkout (`/home/claude/projects/pm/...` copies were
  refused by the sandbox; reads were allowed): briefs must stage needed files in the repository first.
- cairo-vm reservation patch: upstream `Memory::reserve_segment` or a `bal7hazar/cairo-vm` branch (G1c escalation 1).

- `rapier2d = "0.1.0-alpha.1"` is on scarbs.xyz since 2026-09-25 18:30 UTC (SE, RB, WS, prelude re-exports):
  if B0 landed with a path dependency, the first orchestrator PR switches to the registry pin.
- E1 / E2 / E3 resources (owner): `pm/decisions/PENDING-proof-experiments.md`.
