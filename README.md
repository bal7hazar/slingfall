# Slingfall

A 2D slingshot game whose physics is provable. Levels are played locally, replayed through a
deterministic Cairo program, proven, and validated on Starknet.

Working name. Original mechanics and assets: a *pebble* is launched at structures of *timber*,
*slate* and *frost* blocks to destroy the *cores*.

| layer | what | where |
|---|---|---|
| physics | [rapier-cairo](https://github.com/bal7hazar/rapier-cairo) (`rapier2d`, registry version) on the Q32.32 scalar `fixed` and `glam` | dependency |
| level and inputs | Cairo structs with a `Serde` felt layout, JSON form for the editor, Poseidon hashes | `crates/slingfall_level` |
| rules | slingshot, damage from contact-force events, calm rule, scoring, win | `crates/slingfall_rules` |
| game | the level logic as a library: `play` with an `Observer`, `step_shot`, the chunked `ChunkState`; shared by the replay and the contract | `crates/slingfall_game` |
| replay | `main(level, inputs) -> outputs` (proof build) and `main_trace` (client build), chunked `step_chunk(state, k)`: executables over the game library | `crates/slingfall_replay` |
| contract | level registry, `simulate` (SNIP-36 virtual OS), `submit` (proof facts, nullifier, best score) | `crates/slingfall_contract` |
| client | cairo-vm in WASM running the replay in chunks in a Web Worker, PixiJS renderer | `client/` |

Status: bootstrapping (2026-09-25). Plan: `docs/PLAN.md`. Decisions: `docs/DESIGN.md`. The
research behind them: `docs/research/`. Rules for every agent: `AGENTS.md`.

## Commands

Toolchain: scarb 2.19.4 and snforge 0.61.0 (`.tool-versions`, asdf), Python 3, Node 24. On the
shared machine, run one `scarb` / `snforge` command at a time and never `snforge test --workspace`
(`AGENTS.md` §6).

| what | command |
|---|---|
| format | `scarb fmt --workspace` |
| lint one crate | `scarb lint -p <crate> --deny-warnings` |
| build | `scarb build --workspace` |
| build the replay executable | `scarb --manifest-path crates/slingfall_replay/Scarb.toml build` |
| test one crate | `snforge test -p <crate>` (replay: `cd crates/slingfall_replay && snforge test --profile snforge`) |
| steps snapshot | `python3 scripts/steps.py snapshot --filter <crate>` · check: `python3 scripts/steps.py check` · delta: `python3 scripts/steps.py diff` |
| run the client | `cd client && nice -n 10 npm ci && npm run dev` (lint: `npm run lint`, tests: `npm test`) |
| launch an executor | `scripts/executor-unit.sh <id> claude:<sonnet\|opus\|fable> docs/briefs/<id>.md` (resume: `scripts/executor-unit.sh resume <id> claude:<model> "<follow-up>"`) |
