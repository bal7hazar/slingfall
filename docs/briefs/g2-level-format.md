# G2 — `slingfall_level`: level, inputs, outputs, hashes, JSON converter, fixtures

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D2, D3, D4, D12; `docs/research/02-game-design-and-client.md` §2.2-2.4;
on `main`: `crates/slingfall_level/src/lib.cairo` (stubs `level`, `inputs`, `outputs`, `hash`, `errors`),
`crates/slingfall_testing`, `scripts/steps.py`, `.github/PULL_REQUEST_TEMPLATE.md`. Registry sources for
the types you embed: `fixed::Fixed` (raw `i64`), `glam::Vec2`, `glamx::Rot2` / `glamx::Pose2` (as re-exported
by `rapier2d::prelude`; `scarb metadata` shows the registry paths under `~/.cache/scarb`).

## 2. Scope (allowlist)
`crates/slingfall_level/src/**`, `crates/slingfall_level/README.md`, `tools/levelc/**` (new, Python 3
stdlib only), `fixtures/levels/**` (new), `steps/slingfall_level/*.snap`. Nothing else; needs on shared
files go under "Escalations" in `REPORT.md`.

## 3. Expected API (exact names of D2-D4)
`Level`, `Material`, `BodyDef`, `ShapeDef`, `Inputs`, `Shot`, `Outputs` as Cairo structs / enum deriving
`Drop, Copy where possible, Serde, PartialEq, Debug`; `LevelTrait::{hash(self: @Level) -> felt252, validate(self: @Level)}`
(panics with `errors::*` felt constants: `'level: version'`, `'level: shots'`, `'level: tick cap'`,
`'level: material'`, `'level: bounds'`); `InputsTrait::{hash, validate}` (pull inside `[-1024, 1024]²`,
`delay ≤ 60`, shots ≤ level.shots); `OutputsTrait::{to_felts(self) -> Array<felt252>, from_felts(Span<felt252>) -> Outputs}`
(10 felts, D4 order). Hashes = `poseidon_hash_span` over the `Serde` felts. Scalars serialise as raw
`i64` felts (negative = `P - x`). Constants: `LEVEL_VERSION: u16 = 1`, `PULL_MAX: i16 = 1024`.

`tools/levelc/levelc.py`: `to-felts <level.json> [--out felts.json]`, `from-felts`, `check` (round trip
JSON -> felts -> JSON is identity; validate), `hash`. JSON schema documented in `tools/levelc/README.md`:
decimal numbers converted once to raw Q32.32 (round half to even, document it), body poses as
`{x, y, angle_deg}` converted to `Rot2 {re, im}` with the same rounding as `glamx::Rot2::from_angle`
would give (state the deviation if you cannot match it bit for bit; the level stores re/im raw, so
exactness is only a tooling concern).

Fixtures: `fixtures/levels/{one_block, pile10, cores3}.json` + their `.felts.json`, pre-settled poses
approximated by hand (G8 replaces them with the pre-settle tool), materials from D12.

DEFER: nothing else (no rules, no world building).

## 4. Steps budget
`hash` of `pile10` ≤ 120k Cairo steps (`steps_level_hash__pile10` probe through `slingfall_testing::opaque`);
`Outputs::to_felts` ≤ 1k. Record the probes in `steps/slingfall_level/`.

## 5. Tests
Table-driven `snforge` tests in `crates/slingfall_level/tests/` or in-crate `#[cfg(test)]` (≤ 800 lines per
file): Serde round trip for every type, `from_felts(to_felts(o)) == o`, hash stability (golden felt for
each fixture, committed and checked by the Python tool too: `levelc.py hash` must print the same felt as
Cairo; implement Poseidon in Python only if a stdlib-only implementation is short, otherwise generate the
expected felt from the Cairo test output and store it), validation panics with exact messages, negative
raw values, `PULL_MAX` boundaries.

## 6. Definition of done
`AGENTS.md` §6 (crate-scoped, foreground): `scarb fmt --workspace`, `scarb lint -p slingfall_level --deny-warnings`,
`scarb build -p slingfall_level`, `snforge test -p slingfall_level`, `python3 scripts/steps.py snapshot --filter slingfall_level`,
`python3 tools/levelc/levelc.py check fixtures/levels/*.json`; conventional commits with the trailer
`Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push `feat/g2-level-format`; `gh pr create`
(template); `gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · API · Step table ·
Deviations · Deferred · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
