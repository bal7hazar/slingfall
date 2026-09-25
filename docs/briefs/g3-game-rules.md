# G3 — `slingfall_rules`: world builder, slingshot, damage, calm rule, scoring, win

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D3, D5, D6, D7, D10, D12; `docs/research/02-game-design-and-client.md`
§1.2 (API mapping), §2.5, §3; on `main`: `crates/slingfall_rules/src/lib.cairo` (stubs `world`, `sling`,
`damage`, `calm`, `score`; the smoke test shows the prelude), `crates/slingfall_level` (G2: `Level`,
`Material`, `BodyDef`, `ShapeDef`, `Inputs`, `Shot`, constants, `Pose2` / `Rot2` = rapier's),
`client/src/aim/pull.ts` and `arc.ts` (the clamp and flight formulas the client already implements: the rules
must match them bit for bit), `docs/research/04` §"State layout". Registry sources of `rapier2d 0.1.0-alpha.1`
(`~/.cache/scarb/registry/src/*/rapier2d-0.1.0-alpha.1/src/{lib,world}.cairo`, `rapier_dynamics2d-*/src/{events,rigid_body_set,collider/builder}.cairo`):
`WorldTrait::{new, insert, insert_body, insert_collider, remove_body, wake_contact_partners, body, set_body,
step_with_force_events, to_state, from_state}`, `RigidBodyBuilder`, `ColliderBuilder::{ball, cuboid, convex_polygon,
halfspace, density, friction, restitution, contact_force_event_threshold, user_data, active_events}`,
`ContactForceEvent { collider1, collider2, total_force_magnitude, ... }`, `RigidBody::{is_sleeping, sleep, linvel, angvel, set_linvel}`.

## 2. Scope (allowlist)
`crates/slingfall_rules/src/**`, `crates/slingfall_rules/README.md`, `steps/slingfall_rules/*.snap`. The crate
manifest already depends on `rapier2d`, `fixed`, `glam`, `slingfall_level` (check; if a dependency is missing,
escalate). Nothing else.

## 3. Expected API
- `world`: `Game { world: World, level_hash: felt252, entities: Array<Entity>, cores_left: u8, score: u32,
  shots_used: u8, tick: u32, pebble: Option<Handle>, ... }` (`Serde`, so that G4 can serialise it next to
  `WorldState` for chunking: keep every field `Serde`-able; the `World` itself is serialised through
  `to_state` / `from_state` by G4: expose `GameTrait::{to_state(ref self) -> GameState, from_state(GameState) -> Game}`
  with `GameState { world: WorldState, ... }`), `Entity { body: Handle, collider: Handle, kind: u8, material: u8,
  hp: u32, alive: bool }`. `GameTrait::new(level: @Level) -> Game`: gravity `(0, gravity_y)`, dt 1/60,
  4 substeps (`IntegrationParameters` default of rapier), one body + collider per `BodyDef` (statics fixed;
  blocks / cores dynamic, inserted asleep at their stored pose via the builder's sleeping option or
  `sleep()` after insert), materials mapped to `density / friction / restitution`, `contact_force_event_threshold`
  = `force_threshold`, `user_data` = entity index, `ActiveEvents::CONTACT_FORCE_EVENTS` on blocks and cores.
- `sling`: `clamp_pull(px: i16, py: i16, radius: u16) -> (i16, i16)` exactly as `client/src/aim/pull.ts`
  (ceiling integer sqrt, truncation toward zero; table test against the client's test vectors, copy them);
  `launch(ref game: Game, level: @Level, shot: @Shot)`: spawn the pebble (ball r 0.25, density 4, friction 0.5,
  restitution 0.2, `user_data` = pebble marker) at `sling_anchor` with `linvel = -pull · launch_scale` (state
  the exact `Fixed` arithmetic: `Fixed::from_int(px) * launch_scale`, one floor), after `delay` ticks of a
  world with no pebble (the delay ticks are stepped like any tick).
- `damage`: `apply(ref game: Game, level: @Level, events: Span<ContactForceEvent>) -> Array<usize>` (destroyed
  entity indices, ascending), exactly D6: for each event and each side that is a block or core:
  `excess = total_force_magnitude - material.force_threshold`; if positive, `hp -= floor(excess ·
  damage_per_impulse_dt)` saturating at 0. No sqrt. Removals (`World::remove_body`) at the end of the tick,
  ascending handle order; `wake_contact_partners` on the removed collider first if `remove_body` does not
  wake them (test it).
- `calm`: `CalmTrait::{new(), update(ref self, ref game) -> bool}`: after each tick, all dynamic bodies asleep,
  or every awake dynamic body with `|v|² < ε_v²` and `ω² < ε_ω²` (0.05 m/s, 0.05 rad/s, squared compare
  through a fused `dot`, no sqrt) for 20 consecutive ticks, then `sleep()` all; returns "shot over".
  Also the tick cap (`level.tick_cap`) and out-of-bounds removal (pose outside `bounds`: remove; a core
  counts as destroyed; the pebble is removed at the end of its shot).
- `score`: D7 constants and `on_destroyed(ref game, material)`, `on_win(ref game, shots_left)`, `won(game) -> bool`
  (`cores_left == 0`).
- `GameTrait::tick(ref game, level) -> TickReport { destroyed: Array<usize>, shot_over: bool, won: bool }`:
  `step_with_force_events`, damage, removals, calm / cap / bounds, win check; `GameTrait::play_shot(ref game,
  level, shot) -> ShotReport` (launch, loop `tick` until shot over, remove pebble, `shots_used += 1`);
  `GameTrait::final_state_hash(@game) -> felt252` (D4: Poseidon over the raw poses of the remaining dynamic bodies,
  ascending handle order).

DEFER: `main` / `main_trace` executables and the observer (G4), abilities, projectile kinds ≠ 0, pre-settle tooling.

## 4. Steps budget
Probes (`steps_*`, through `slingfall_testing::opaque`): `steps_game_new__pile10`, `steps_tick__pile10_flight`
(pebble in the air, blocks asleep), `steps_tick__pile10_impact` (first contact tick), `steps_damage__3_events`,
`steps_calm__update`, `steps_final_state_hash__pile10`. Targets: the rules' own overhead per tick (everything
except `step_with_force_events`) ≤ 5 % of the step; report the split. Interim shot budget: ≤ 1e8 steps.

## 5. Tests
Table-driven, ≤ 800 lines per file, ≤ 4 fuzz: builder maps every fixture body (kinds, materials, thresholds,
asleep at t0); a resting `pile10` takes **zero damage over 120 ticks** (D6 invariant) — if it does not, report
which material / stack, do not tune; a pebble fired at `pile10` destroys at least one block within the cap
and the calm rule ends the shot before the cap (report the tick); `clamp_pull` vectors = the client's;
damage arithmetic goldens computed by hand; removal order; `to_state` / `from_state` round trip of a `Game`
mid-shot is bit-exact for 10 more ticks (compare `final_state_hash`); tunnelling check: a pebble at 25 m/s
against a 0.5 m plank over 60 ticks (report whether it tunnels; do not fix in this lot).

## 6. Definition of done
`AGENTS.md` §6 (crate-scoped, foreground): `scarb fmt --workspace`, `scarb lint -p slingfall_rules --deny-warnings`,
`scarb build -p slingfall_rules`, `snforge test -p slingfall_rules`, `python3 scripts/steps.py snapshot --filter slingfall_rules`;
conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push
`feat/g3-game-rules`; `gh pr create` (template); `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · API · Step table incl. the rules-vs-engine split per tick · Deviations · Deferred · Escalations
(missing rapier2d accessors go here, precisely named) · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
