# slingfall_rules

The game rules on top of `rapier2d`: the world built from a `Level`, the slingshot (pull clamp and
launch), damage from contact-force events, the end-of-shot calm rule, out-of-bounds removal,
scoring and the win condition (`docs/DESIGN.md` D3, D5-D7). Everything goes through `rapier2d`'s
public API; a missing accessor is an escalation.

| module | API |
|---|---|
| `world` | `Game`, `Entity`, `GameState`, `TickReport`, `ShotReport`; `GameTrait::{new, tick, play_shot, end_shot, final_state_hash, to_state, from_state}`; `errors` |
| `sling` | `clamp_pull` (bit-exact with `client/src/aim/pull.ts`), `launch_velocity`, `launch`; pebble constants |
| `damage` | `apply` (D6), `damage_of`, `entity_of`, `remove` (ascending handles, scoring, cores) |
| `calm` | `Calm`, `CalmTrait::{new, update}` (D5 (1) and (2) plus out-of-bounds, one body read per tick), `is_calm`, `sleep_all`, `CALM_TICKS`, `EPS_*` |
| `score` | D7 constants, `on_destroyed`, `on_win`, `won` |

A tick (`GameTrait::tick`): `step_with_force_events`; damage; removal of the destroyed bodies in
ascending handle order; one pass over the live dynamic bodies (out-of-bounds removal, then all
asleep / calm); the tick cap (`shot_tick >= level.tick_cap`); the win check. A shot
(`GameTrait::play_shot`): `delay` ticks without a pebble, `sling::launch`, ticks until the shot is
over, `end_shot` (pebble removed, shot counted, unused-shot bonus on a win). A replay that drives
ticks itself (the chunked build) calls `sling::launch`, `tick` and `end_shot` in that order.

Entity `i` owns the body and collider handles of slot `i` (`GameTrait::new` inserts in level order
into an empty world and checks it); collider `user_data` is the entity index, the pebble's is
`sling::PEBBLE_USER_DATA`.

Pre-slept start: rapier wakes the parent of every freshly inserted collider at the next step, so
`GameTrait::new` runs one `dt = 0` step (nothing moves) and puts every dynamic body back to sleep at
its stored pose (`world::settle`).

Tests: `snforge test -p slingfall_rules`. Three tests exceed snforge's default step cap and are
`#[ignore]`d: `snforge test -p slingfall_rules --ignored --max-n-steps 400000000`.
