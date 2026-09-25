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
| replay | `main(level, inputs) -> outputs` (proof build) and `main_trace` (client build), chunked `step_chunk(state, k)` | `crates/slingfall_replay` |
| contract | level registry, `simulate` (SNIP-36 virtual OS), `submit` (proof facts, nullifier, best score) | `crates/slingfall_contract` |
| client | cairo-vm in WASM running the replay in chunks in a Web Worker, PixiJS renderer | `client/` |

Status: bootstrapping (2026-09-25). Plan: `docs/PLAN.md`. Decisions: `docs/DESIGN.md`. The
research behind them: `docs/research/`. Rules for every agent: `AGENTS.md`.
