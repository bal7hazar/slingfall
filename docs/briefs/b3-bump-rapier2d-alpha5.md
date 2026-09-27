# B3 — bump to `rapier2d = "=0.1.0-alpha.5"` (CC + LO2 + SH2a; WorldState v3), re-pin the proven program on Sepolia

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D5 (CCD stays off), D9 (`SatelliteConfig.child_program_hash` pinned per release), D11;
rapier-cairo CHANGELOG 0.1.0-alpha.5 (registry source after `scarb fetch`): `World::step` results unchanged (+2 steps per
contact pair per step), **WorldState version 3** (v2 states panic), shape casts, CCD (`step_with_ccd`, automatic off),
Polyline / HeightField; on `main`: B1 / B2 reports' pattern (`docs/PLAN.md` rows), `tools/golden/golden.py`,
`client/vm/scripts/fetch-executables.sh`, `tools/atlantic/atlantic.py program-hash` (the `c1main` Pedersen hash),
`tools/atlantic/c1main/`, `deploy/sepolia.sh` (`set-config` or the config step of `deploy`), `deploy/sepolia.json`.

## 2. Credentials
`STARKNET_*` in your environment: this lot MAY send exactly one admin transaction on Sepolia
(`set_satellite_config` with the new `child_program_hash`); never print values.

## 3. Scope (allowlist)
Version pins (root `Scarb.toml`, `crates/slingfall_replay/Scarb.toml`, `client/vm/fixtures/ball_drop/Scarb.toml`,
`tools/atlantic/c1main/Scarb.toml`, `deploy/contract/`) + lockfiles; `steps/**`; `fixtures/golden/**`;
`crates/slingfall_replay/tests/golden.cairo` and reference fixtures only if outputs change (none expected);
`client/vm/fixtures/**` (rebuilt executables, stand-in state v3); `fixtures/proofs/**` (new program hash record);
`deploy/sepolia.json` (new `child_program_hash`, the tx hash), `docs/proving.md` (program-hash history table),
`crates/slingfall_rules/src/**` only if the facade changed (no CCD adoption).

## 4. Work
1. Pin alpha.5 everywhere; build; fix facade breaks if any (report them).
2. Regenerate steps snapshots, goldens (`--update`, outputs must be bit-identical: report any change and its reason),
   executables (`fetch-executables.sh --build`), the stand-in state (v3), `c1main` build and its program hash
   (`atlantic.py program-hash`); before / after steps table per golden case.
3. Sepolia: `set_satellite_config` with the new `child_program_hash` (other constants unchanged); record the tx hash
   and fee in `deploy/sepolia.json` and a "program hash history" table in `docs/proving.md` (alpha.3 hash, alpha.5
   hash, dates). Note: proofs made with the alpha.3 program can no longer settle after this (by design).
4. Verify: `atlantic.py fact-hash` on the E3b run still reproduces the old fact with the old hash (regression of the
   tooling), and `deploy/sepolia.sh` reads the new config back.

## 5. Budget
Expected: steps +≈ 0.005 % (2 per pair per step); report.

## 6. Tests
CI green (golden matrix, vm, prove, e2e); contract tests unchanged.

## 7. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/b3-bump-rapier2d-alpha5`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`.
Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs.
