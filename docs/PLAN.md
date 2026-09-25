# Execution plan

Status: **v1, 2026-09-25, bootstrapping** (owner of this file: the `slingfall` orchestrator session).
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
| 0 | B0 | bootstrap: workspace, crates and stubs, `client/` skeleton, CI, `scripts/` (executor, steps snapshots), PR template, `.tool-versions`, dependency pin | Opus | – |
| 1 | G2 | `slingfall_level`: `Level` / `Material` / `BodyDef` / `ShapeDef` / `Inputs` / `Shot` / `Outputs` (D2-D4), Serde layouts, `level_hash` / `inputs_hash`, JSON schema + `tools/levelc` converter (Python, decimal → raw Q32.32, round trip), 3 fixture levels (`fixtures/levels/*.json` + felts) | Sonnet | B0 |
| 1 | G6 | `client/`: Vite + TS + PixiJS renderer of a recorded trace (JSON emitted by `main_trace` via `scarb execute`), placeholder assets, aim UI with the quantised pull and the exact BigInt arc; trace source behind an interface (recorded now, worker later) | Sonnet | B0 (fixture trace from `docs/research/03`'s scene until G4) |
| 1 | G1c | `client/vm/`: the chunked cairo-vm worker as a reusable TS package, from the spike `pm/spikes/wasm-vm/` (runner crate vendored under `client/vm/runner/`, wasm build script, step-budgeted chunking, memory reservation, `println!` streaming), tested on the spike's executable | Opus | B0 |
| 2 | G3 | `slingfall_rules`: world builder from `Level` (shapes, materials, `user_data`, pre-slept bodies), slingshot (clamp, launch), damage (D6), despawn, calm rule (D5), pebble removal, scoring and win (D7); snforge tests; steps per tick; tunnelling check at `v_max` | Opus | G2, `rapier2d` alpha |
| 2 | G7 | `slingfall_contract`: level registry, `simulate` (D9) behind a `Verifier` interface stubbed until E2, `submit` checks, nullifiers, best score, events; snforge tests | Opus | G2 (layouts); G3 for `simulate`'s body (stub first) |
| 3 | G4 | `slingfall_replay`: `main`, `main_trace` (observer), `init` / `step_chunk` on `WorldState` (D1); `scarb execute` on the fixtures; **Cairo steps per shot and per level measured** and written here | Opus | G3 |
| 3 | G5 | determinism and budget CI: golden `(level, inputs) -> outputs` snapshots, trace ≡ proof ≡ chunked outputs, input fuzzing, per-level step ceilings (+10 %) | Sonnet | G4 |
| 4 | G8 | content and editor tooling: pre-settle tool, level validator (zero damage at rest over 120 ticks, step budget), 5 levels of 8-10 blocks, material tuning | Sonnet | G4, G6 |
| 4 | G6b | client live mode: G1c worker runs `step_chunk` per shot, slow-motion impact presentation, score UI | Opus | G1c, G4, G6 |
| 5 | E2 | SNIP-36 round trip on Sepolia: `simulate` proven with `snip36 prove virtual-os`, `submit` consuming `proof_facts`; needs a funded Sepolia account and a ≥ 32 GB prover box (owner) | Opus | G7, G4 |
| 5 | G9 | client submission flow: Cartridge Controller / get-starknet, prove request (local helper or service), `submit` transaction, validation status reads | Opus | E2, G6b |

Critical path: B0 → G2 → G3 → G4 → G5 → E2 → G9. G6, G1c, G7 run in parallel from wave 1-2.

## Budgets

| quantity | target | measured |
|---|---|---|
| Cairo steps per shot | ≤ 3e7 | pile12 (rapier scene, 12 boxes + ball, 120 ticks): 40.0M (`docs/research/04`) |
| Cairo steps per tick, 13 bodies | – | 333k average, 540k during impact |
| `WorldState` round trip (pile10) | – | 1 864 felts, 52k steps (rapier #131) |
| browser, 4e7-step shot, chunked | ≤ 10 s | 12-14 s (Firefox, loaded VPS) |
| proven transaction | ≤ 1.1B L2 gas ≈ 9M steps | – |

## Escalations sent

(none yet)

## Open points

- `rapier2d` `0.1.0-alpha.1` publication (rapier-cairo, decided 2026-09-25); B0 pins it, or
  pins a path dependency temporarily with a TODO if the alpha is not on the registry yet.
- E1 / E2 / E3 resources (owner): `pm/decisions/PENDING-proof-experiments.md`.
