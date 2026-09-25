# slingfall_rules

The game rules on top of `rapier2d`: the world built from a `Level`, the slingshot (pull clamp and
launch), damage from contact-force events, the end-of-shot calm rule, out-of-bounds removal,
scoring and the win condition (`docs/DESIGN.md` D3, D5-D7). Everything goes through `rapier2d`'s
public API; a missing accessor is an escalation.

| module | API |
|---|---|
| `world` | `Game`, `Entity`, `GameState`, `TickReport`, `ShotReport`; `GameTrait::{new, tick, play_shot, end_shot, final_state_hash, to_state, from_state}`; `errors` |
| `sling` | `clamp_pull` (bit-exact with `client/src/aim/pull.ts`), `launch_velocity`, `launch`, `pebble_touched`; pebble constants |
| `damage` | `apply` (D6), `damage_of`, `entity_of`, `remove` (ascending handles, scoring, cores) |
| `calm` | `Calm`, `CalmTrait::{new, update}` (D5 (1) and (2) plus out-of-bounds, one body read per tick), `is_calm`, `pebble_spent`, `sleep_all`, `CALM_TICKS`, `PEBBLE_FLIGHT_CAP`, `EPS_*` |
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

The pebble: `sling::launch` reads `level.projectiles[game.shots_used]` (kind 0 = pebble; any other
kind panics `errors::PROJECTILE_KIND`, `'rules: projectile kind'`: abilities are deferred, the
field is never silently ignored). The pebble is undamped: its flight is the client's exact arc.

Spent pebble (D5): a rolling ball never calms (no rolling resistance), so the pebble leaves the
calm test once it is *spent*, `calm::pebble_spent`: it has had its first contact with a block or a
core (a contact-force event; its collider reports them at threshold 0; `Game.pebble_contact`,
`Game.pebble_contact_tick`, set in `GameTrait::tick`), or `calm::PEBBLE_FLIGHT_CAP = 120` ticks went
by since the launch. Contacts with static colliders (the ground, fixed bodies) do not spend it: a
pebble that lands short can still roll into the pile. When every other dynamic body is asleep or
calm for `CALM_TICKS`, the shot ends and `end_shot` removes the pebble. A pebble that never touches
a block therefore keeps the shot going for 120 ticks after the launch, then ends it as soon as the
pile is asleep. `GameState` gained the two fields (`pebble_contact: bool`, `pebble_contact_tick:
u32`, two felts before `calm`): its felt layout changed.

## Note for level authors (G8): static load of a pile

A pile woken up at rest is not stable under D6: the static load alone exceeds timber's 40 N
contact-force threshold under the two inner bottom blocks of `pile10` (entities 2 and 3, about
41-43 N each), so they lose hp (100 -> 81 and 82) until the calm rule puts the pile back to sleep
(tick 20). It does not happen in a shot only because the structure starts, and stays, asleep (the
`world::settle` step) until the pebble's contact wakes the touched island. Consequences: keep the
static contact force of every supporting block below its material threshold (a wide base, slate
or a lower stack under the same block), never rely on a block being "woken but harmless", and
check a new level with the awake-at-rest probe of `world/tests.cairo`
(`test_awake_pile10_load_damage_is_the_inner_bottom_timber`).

## Tests

`snforge test -p slingfall_rules` (the whole-shot tests run 20-40M Cairo steps each; the workspace
`Scarb.toml` raises snforge's step cap to 400M).
