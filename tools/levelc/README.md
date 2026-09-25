# levelc

Converter between the Slingfall level JSON (decimal values, the editor's source of truth) and the
felts of `slingfall_level::level::Level` (`docs/DESIGN.md` D2). Python 3 standard library only.

```
python3 tools/levelc/levelc.py to-felts   fixtures/levels/pile10.json [--out pile10.felts.json]
python3 tools/levelc/levelc.py from-felts fixtures/levels/pile10.felts.json [--out level.json]
python3 tools/levelc/levelc.py check      fixtures/levels/*.json [--strict] [--cairo FIXTURES.cairo]
python3 tools/levelc/levelc.py hash       fixtures/levels/pile10.json
python3 tools/levelc/levelc.py to-cairo   fixtures/levels/*.json --out crates/slingfall_level/src/level/fixtures.cairo
python3 tools/levelc/test_levelc.py       # unit tests
```

- `to-felts` writes `{"level_hash": "0x…", "felts": ["…", …]}`; felts are decimal strings (a negative
  raw value is `P - x`, `P = 2^251 + 17·2^192 + 1`), `level_hash` is hex.
- `from-felts` reads that document (or a bare array of felts) and prints the canonical JSON.
- `check` (the definition of done) validates every level with the rules of `LevelTrait::validate`
  (same messages as the Cairo panics), checks that JSON → felts → JSON → felts is the identity and
  that the canonical JSON is a fixed point, and, when `<name>.felts.json` exists next to a level,
  that it is up to date (felts and hash). `*.felts.json` arguments (a shell glob of `*.json`) are
  skipped. `--strict` also requires the source JSON to be canonical (no `angle_deg`, shortest
  decimals). `--cairo` checks that the generated Cairo fixtures are current.
- `hash` prints `level_hash`. `poseidon.py` is a standard-library Starknet Poseidon
  (`poseidon_hash_span`, about 50 lines); the Cairo tests check every fixture golden against
  `core::poseidon::poseidon_hash_span`, so both agree.
- `to-cairo` generates `crates/slingfall_level/src/level/fixtures.cairo` (felts and golden hash of
  each fixture; run `scarb fmt --workspace` afterwards, `check --cairo` ignores whitespace).

## Conversion rules

- A decimal is converted once to raw Q32.32 (`i64`, value × 2^32) **exactly** (no float), rounded
  **half to even**, and rejected when it does not fit an `i64`. Numbers are parsed as `Decimal`.
- `from-felts` prints, for each raw value, the shortest decimal that converts back to the same raw
  (`0.1`, not `0.10000000005820766…`).
- A pose is `{x, y, angle_deg}` or `{x, y, re, im}`, never both. `angle_deg` becomes the unit
  complex number `(re, im) = (cos, sin)` rounded half to even to Q32.32; multiples of 90° are
  exact. **Deviation:** `glamx::Rot2::from_angle` cannot be reproduced bit for bit — the Cairo
  port (`rapier_math::rot2::Rot2`) has no trigonometry yet — so the angle goes through
  `math.cos`/`math.sin` on the float angle (error ~1e-16, far below half a raw unit, 1.2e-10),
  i.e. the correctly rounded value except on a tie. The level stores `re`/`im` raw, so this is
  a tooling concern only. `from-felts` always prints `re`/`im`.

## JSON schema

Top level (all keys required):

| key | type | Cairo field |
|---|---|---|
| `version` | int (u16), `1` | `version` |
| `level_id` | int (u32) | `level_id` |
| `seed` | felt: int, decimal or `0x` string | `seed` |
| `gravity_y` | decimal | `gravity_y` |
| `shots` | int (u8), `1..=5` | `shots` |
| `tick_cap` | int (u16), `1..=360` | `tick_cap` |
| `bounds` | `{min_x, min_y, max_x, max_y}` decimals | `bounds` tuple, that order |
| `sling_anchor` | `{x, y}` | `sling_anchor` |
| `pull_radius` | int (u16), `1..=1024` | `pull_radius` |
| `launch_scale` | decimal | `launch_scale` |
| `projectiles` | array of int (u8), one per shot | `projectiles` |
| `materials` | array of material | `materials` |
| `bodies` | array of body | `bodies` |

Material: `{density, friction, restitution, hp, force_threshold, damage_per_impulse_dt, score}`
(`hp`, `score` ints; the others decimals). Body: `{kind, shape, pose, material}` with
`kind` one of `"static"`, `"block"`, `"core"` (0, 1, 2) and `material` an index into `materials`.
Shape, discriminated by `type` (the variant order of `ShapeDef`):

| `type` | keys |
|---|---|
| `ball` | `radius` |
| `cuboid` | `hx`, `hy` (half extents) |
| `polygon` | `points`: array of `{x, y}`, counter-clockwise, at least 3 |
| `half_space` | `normal`: `{x, y}` outward unit normal |

Felt layout (`Serde`): scalars one felt each, arrays length-prefixed, a shape is its variant index
then its payload, a pose is `[x, y, re, im]`. Level: `version, level_id, seed, gravity_y, shots,
tick_cap, min_x, min_y, max_x, max_y, anchor_x, anchor_y, pull_radius, launch_scale,
len(projectiles), projectiles…, len(materials), (7 felts each)…, len(bodies), (kind, shape, pose,
material)…`.
