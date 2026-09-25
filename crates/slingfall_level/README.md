# slingfall_level

The level format of Slingfall: the `Level` a replay runs (materials, bodies, sling, bounds), the
player's `Inputs` (one quantised pull per shot), the 10-felt `Outputs` a proof commits to, and the
Poseidon hashes `level_hash` / `inputs_hash` over their `Serde` felt layouts (`docs/DESIGN.md`
D2-D4). Pure Cairo, no `starknet` dependency.

| module | content |
|---|---|
| `level` | `Level`, `Material`, `BodyDef`, `ShapeDef`, `Pose2`, `Rot2`; `LevelTrait::{hash, validate}`; `LEVEL_VERSION` |
| `inputs` | `Inputs`, `Shot`; `InputsTrait::{hash, validate}`; `PULL_MAX`, `DELAY_MAX` |
| `outputs` | `Outputs`; `OutputsTrait::{to_felts, from_felts}` (D4 order, 10 felts) |
| `hash` | `serde_hash`, the `Serde` felts and their `poseidon_hash_span` |
| `errors` | the `felt252` panic messages (stable API) |

The felt layout of every type is its `Serde` layout: one felt per scalar (a raw Q32.32 `i64`, a
negative value `-x` is `P - x`), length-prefixed arrays, an enum is its variant index then its
payload, a `Pose2` is `[x, y, re, im]`. `Pose2` and `Rot2` are declared here with the field order
and layout of `rapier_math::pose2::Pose2` / `rot2::Rot2` (what `rapier2d::prelude` re-exports)
because this crate does not depend on `rapier2d`.

Levels are authored as JSON and converted by `tools/levelc` (`fixtures/levels/*.json`, their
`.felts.json`, and the generated `src/level/fixtures.cairo`); the golden hashes are checked by both
the Cairo tests and the Python tool. Tests: `snforge test -p slingfall_level`; step probes:
`python3 scripts/steps.py snapshot --filter slingfall_level`.
