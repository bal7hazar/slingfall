//! The game's rules without the world (`docs/DESIGN.md` D5-D7): what `slingfall_rules::world::
//! GameTrait::tick` and `slingfall_game::play::step_shot` do around the step, on compact data, so
//! that they can run in a declared class that never holds the world.
//!
//! The world side (`crate::world`) steps, then hands over the tick's contact-force events as
//! [`Hit`]s and, for the bodies the rules watch, a [`View`] (sleeping, or translation and
//! velocities). The rules answer with world edits in main's order ([`Op`]: removals and sleeps),
//! the pebble to insert before the next step ([`Launch`]) and the bodies to watch next.
//!
//! Main's tick reads the world twice: the force events right after the step, and the bodies after
//! the damage removals (`World::remove_body` wakes contact partners, which the calm test then
//! sees). [`tick`] therefore stops after the damage when it destroyed something
//! ([`TickOut::calm_pending`]): the world side applies the removals, takes fresh views and calls
//! [`calm`]. On every other tick one call does both.
//!
//! The pure helpers are main's (`damage_of`, `entity_of`, `pebble_touched`, `clamp_pull`,
//! `launch_velocity`, the D5 constants); the orchestration below mirrors `GameTrait::tick`,
//! `CalmTrait::update`, `damage::apply` / `remove`, `sling::launch`, `GameTrait::end_shot` and
//! `step_shot` line for line, on the entities instead of the world.

use fixed::wide::dot2;
use rapier2d::prelude::{Fixed, Handle, Vec2};
use slingfall_game::play::{ShotProgress, decode};
use slingfall_level::inputs::{DELAY_MAX, Inputs, PULL_MAX, Shot};
use slingfall_level::level::{KIND_CORE, KIND_STATIC, Level, LevelTrait, Material};
use slingfall_rules::calm::{
    CALM_TICKS, Calm, CalmTrait, EPS_V, EPS_V_SQ, EPS_W, EPS_W_SQ, PEBBLE_FLIGHT_CAP,
};
use slingfall_rules::damage::{damage_of, entity_of};
use slingfall_rules::score::UNUSED_SHOT;
use slingfall_rules::sling::{KIND_PEBBLE, clamp_pull, launch_velocity};
use slingfall_rules::world::{Entity, GameState, errors};

/// What the rules read of the level (the rest of it is only hashed).
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct Params {
    pub shots: u8,
    pub tick_cap: u16,
    pub bounds: (Fixed, Fixed, Fixed, Fixed),
    pub sling_anchor: Vec2,
    pub pull_radius: u16,
    pub launch_scale: Fixed,
    pub projectiles: Array<u8>,
    pub materials: Array<Material>,
}

/// The game state outside the world: main's `GameState` without `world`, and the shot progress
/// of the chunked state (`slingfall_game::chunk::ChunkState.progress`).
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct Rules {
    pub params: Params,
    pub level_hash: felt252,
    pub entities: Array<Entity>,
    pub cores_left: u8,
    pub score: u32,
    pub shots_used: u8,
    pub tick: u32,
    pub shot_tick: u32,
    pub pebble: Option<Handle>,
    pub pebble_contact: bool,
    pub pebble_contact_tick: u32,
    pub calm: Calm,
    pub progress: ShotProgress,
}

/// A contact-force event as the rules read it (`ContactForceEvent`: both colliders and
/// `total_force_magnitude`).
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Hit {
    pub collider1: Handle,
    pub collider2: Handle,
    pub magnitude: Fixed,
}

/// An awake body as the calm rule reads it.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Motion {
    pub translation: Vec2,
    pub linvel: Vec2,
    pub angvel: Fixed,
}

/// A watched body after the step: `None` while it sleeps.
pub type View = Option<Motion>;

/// A world edit, applied in order.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub enum Op {
    /// `World::remove_body`.
    Remove: Handle,
    /// `slingfall_rules::calm::sleep_all`'s edit of one body: `sleep()` unless it already sleeps.
    Sleep: Handle,
}

/// The pebble of `sling::launch`: a dynamic body at `translation` (identity rotation) with
/// `linvel`, and the pebble's collider.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Launch {
    pub translation: Vec2,
    pub linvel: Vec2,
}

/// What a rules call asks of the world.
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct TickOut {
    /// Edits to apply now, in order.
    pub ops: Array<Op>,
    /// The damage destroyed something: apply `ops`, then call [`calm`] with fresh views of
    /// `watch`.
    pub calm_pending: bool,
    /// The bodies to view after the next step (or for the pending calm), in order; the world side
    /// appends the pebble it inserts.
    pub watch: Array<Handle>,
    /// The pebble to insert before the next step (when there is one in this chunk).
    pub launch: Option<Launch>,
    /// The shot is over (`step_shot` stops).
    pub over: bool,
}

/// Rules state of a game built by main (`GameTrait::new`, then `to_state`), at `progress`.
pub fn from_game(level: @Level, state: GameState, progress: ShotProgress) -> Rules {
    let GameState {
        world: _,
        level_hash,
        entities,
        cores_left,
        score,
        shots_used,
        tick,
        shot_tick,
        pebble,
        pebble_contact,
        pebble_contact_tick,
        calm,
    } = state;
    Rules {
        params: params(level),
        level_hash,
        entities,
        cores_left,
        score,
        shots_used,
        tick,
        shot_tick,
        pebble,
        pebble_contact,
        pebble_contact_tick,
        calm,
        progress,
    }
}

/// The [`Params`] of `level`.
pub fn params(level: @Level) -> Params {
    let mut projectiles = array![];
    projectiles.append_span(level.projectiles.span());
    let mut materials = array![];
    materials.append_span(level.materials.span());
    Params {
        shots: *level.shots,
        tick_cap: *level.tick_cap,
        bounds: *level.bounds,
        sling_anchor: *level.sling_anchor,
        pull_radius: *level.pull_radius,
        launch_scale: *level.launch_scale,
        projectiles,
        materials,
    }
}

/// `level.validate()` then `level.hash()`: what `init` binds.
pub fn level_hash(level: @Level) -> felt252 {
    level.validate();
    level.hash()
}

/// `slingfall_game::chunk::step_state`'s checks of a chunk of shot `shot`: the inputs are valid
/// for the level (`InputsTrait::validate`), `shot` is the shot in progress, is in the inputs and
/// the level is not over. Returns the shot.
///
/// # Panics
/// The level crate's `inputs: *` messages; `slingfall_game::errors::SHOT`; `errors::INPUTS` when
/// `inputs` is not exactly one `Inputs`.
pub fn check_turn(self: @Rules, inputs: Span<felt252>, shot: u8) -> Shot {
    let inputs: Inputs = decode(inputs, slingfall_game::errors::INPUTS);
    let shots = inputs.shots.span();
    if shots.len() > (*self.params.shots).into() {
        core::panic_with_felt252(slingfall_level::errors::INPUTS_SHOTS);
    }
    for shot in shots {
        let Shot { pull_x, pull_y, delay, .. } = *shot;
        if pull_x < -PULL_MAX || pull_x > PULL_MAX || pull_y < -PULL_MAX || pull_y > PULL_MAX {
            core::panic_with_felt252(slingfall_level::errors::INPUTS_PULL);
        }
        if delay > DELAY_MAX {
            core::panic_with_felt252(slingfall_level::errors::INPUTS_DELAY);
        }
    }
    if shot != *self.shots_used
        || shot.into() >= shots.len()
        || (*self.progress.ticks == 0 && level_over(self)) {
        core::panic_with_felt252(slingfall_game::errors::SHOT);
    }
    let turn = *shots[shot.into()];
    turn
}

/// The start of a chunk of `shot`: the pebble to insert before its first step, if the delay is
/// done and it was not launched yet (`step_shot`'s first iteration), and the bodies to watch.
///
/// # Panics
/// As `sling::launch`: `errors::PEBBLE`, `errors::PROJECTILE_KIND`.
pub fn begin(self: @Rules, shot: @Shot) -> (Option<Launch>, Array<Handle>) {
    (next_launch(self, shot), watch(self))
}

/// One tick after the step (`GameTrait::tick`, then `step_shot`'s end of iteration). `inserted`
/// is the pebble the world side inserted before the step (the handle `sling::launch` stores),
/// `hits` the step's force events, `views` the views of the watched bodies (then the inserted
/// pebble's).
pub fn tick(
    ref self: Rules, shot: @Shot, inserted: Option<Handle>, hits: Span<Hit>, views: Span<View>,
) -> TickOut {
    if let Some(handle) = inserted {
        // `sling::launch`'s state change, before the step as in main (the step does not read it).
        self.pebble = Some(handle);
        self.shot_tick = 0;
        self.pebble_contact = false;
        self.pebble_contact_tick = 0;
        self.calm = CalmTrait::new();
        self.progress.launched = true;
    }
    self.tick += 1;
    self.shot_tick += 1;
    if self.pebble.is_some() && !self.pebble_contact && touched(self.entities.span(), hits) {
        self.pebble_contact = true;
        self.pebble_contact_tick = self.shot_tick;
    }
    let destroyed = apply_damage(ref self, hits);
    if !destroyed.is_empty() {
        let mut ops = array![];
        remove(ref self, destroyed.span(), ref ops);
        return TickOut { ops, calm_pending: true, watch: watch(@self), launch: None, over: false };
    }
    calm(ref self, shot, views)
}

/// The rest of the tick after the damage removals: `CalmTrait::update`, the tick cap,
/// `step_shot`'s end of shot (`GameTrait::end_shot`) and the next launch. `views` are those of
/// `watch` (the last [`TickOut`]'s, then the inserted pebble's).
pub fn calm(ref self: Rules, shot: @Shot, views: Span<View>) -> TickOut {
    let mut ops: Array<Op> = array![];
    let bounds = self.params.bounds;
    let mut views = views;
    let mut out_of_bounds: Array<usize> = array![];
    let mut all_asleep = true;
    let mut all_calm = true;
    let mut index = 0;
    for entity in self.entities.span() {
        if *entity.alive && *entity.kind != KIND_STATIC {
            if let Some(motion) = *views.pop_front().unwrap() {
                if outside(motion.translation, bounds) {
                    out_of_bounds.append(index);
                } else {
                    all_asleep = false;
                    all_calm = all_calm && is_calm(@motion);
                }
            }
        }
        index += 1;
    }
    if let Some(pebble) = self.pebble {
        if let Some(motion) = *views.pop_front().unwrap() {
            if outside(motion.translation, bounds) {
                ops.append(Op::Remove(pebble));
                self.pebble = None;
            } else if !(self.pebble_contact || self.shot_tick >= PEBBLE_FLIGHT_CAP) {
                all_asleep = false;
                all_calm = all_calm && is_calm(@motion);
            }
        }
    }
    remove(ref self, out_of_bounds.span(), ref ops);
    let shot_over = if all_asleep {
        self.calm.ticks = 0;
        true
    } else if all_calm {
        self.calm.ticks += 1;
        if self.calm.ticks >= CALM_TICKS {
            sleep_all(@self, ref ops);
            self.calm.ticks = 0;
            true
        } else {
            false
        }
    } else {
        self.calm.ticks = 0;
        false
    };
    let capped = !shot_over && self.shot_tick >= self.params.tick_cap.into();
    // `step_shot`: delay ticks never end a shot.
    self.progress.ticks += 1;
    let over = self.progress.launched && (shot_over || capped);
    if over {
        // `GameTrait::end_shot(level, !capped)`.
        if let Some(pebble) = self.pebble {
            ops.append(Op::Remove(pebble));
            self.pebble = None;
            if !capped {
                sleep_all(@self, ref ops);
            }
        }
        self.shots_used += 1;
        if self.cores_left == 0 {
            let left: u32 = (self.params.shots - self.shots_used).into();
            self.score += left * UNUSED_SHOT;
        }
        self.progress = Default::default();
        return TickOut { ops, calm_pending: false, watch: watch(@self), launch: None, over };
    }
    TickOut {
        ops, calm_pending: false, watch: watch(@self), launch: next_launch(@self, shot), over,
    }
}

/// The damage rule alone (a size fixture): `tick`'s damage and removal bookkeeping.
pub fn damage_only(ref self: Rules, hits: Span<Hit>) -> bool {
    let destroyed = apply_damage(ref self, hits);
    let mut ops = array![];
    remove(ref self, destroyed.span(), ref ops);
    !destroyed.is_empty()
}

/// The level is over: won, or every shot used (`slingfall_game::play::level_over`).
pub fn level_over(self: @Rules) -> bool {
    *self.cores_left == 0 || *self.shots_used >= *self.params.shots
}

/// `step_shot`'s launch condition and `sling::launch`'s checks and velocity.
fn next_launch(self: @Rules, shot: @Shot) -> Option<Launch> {
    let progress = *self.progress;
    if progress.launched || progress.ticks != (*shot.delay).into() {
        return None;
    }
    if self.pebble.is_some() {
        core::panic_with_felt252(errors::PEBBLE);
    }
    let params = self.params;
    if *params.projectiles[(*self.shots_used).into()] != KIND_PEBBLE {
        core::panic_with_felt252(errors::PROJECTILE_KIND);
    }
    let (px, py) = clamp_pull(*shot.pull_x, *shot.pull_y, *params.pull_radius);
    Some(
        Launch {
            translation: *params.sling_anchor,
            linvel: launch_velocity(px, py, *params.launch_scale),
        },
    )
}

/// The bodies the calm rule reads: the live dynamic entities' (entity order), then the pebble's.
fn watch(self: @Rules) -> Array<Handle> {
    let mut out = array![];
    for entity in self.entities.span() {
        if *entity.alive && *entity.kind != KIND_STATIC {
            out.append(*entity.body);
        }
    }
    if let Some(pebble) = *self.pebble {
        out.append(pebble);
    }
    out
}

/// `sleep_all`: every live dynamic entity, then the pebble.
fn sleep_all(self: @Rules, ref ops: Array<Op>) {
    for entity in self.entities.span() {
        if *entity.alive && *entity.kind != KIND_STATIC {
            ops.append(Op::Sleep(*entity.body));
        }
    }
    if let Some(pebble) = *self.pebble {
        ops.append(Op::Sleep(pebble));
    }
}

/// `sling::pebble_touched` on hits.
fn touched(entities: Span<Entity>, hits: Span<Hit>) -> bool {
    for hit in hits {
        let first = entity_of(entities, *hit.collider1);
        let second = entity_of(entities, *hit.collider2);
        let other = if first.is_none() {
            second
        } else if second.is_none() {
            first
        } else {
            None
        };
        if let Some(index) = other {
            if *entities[index].kind != KIND_STATIC {
                return true;
            }
        }
    }
    false
}

/// `damage::apply` on hits: the entities destroyed by the damage (ascending), `hp` updated.
fn apply_damage(ref self: Rules, hits: Span<Hit>) -> Array<usize> {
    if hits.is_empty() {
        return array![];
    }
    let entities = self.entities.span();
    let materials = self.params.materials.span();
    let mut damage: Array<(usize, u32)> = array![];
    for hit in hits {
        side(ref damage, entities, materials, *hit.collider1, *hit.magnitude);
        side(ref damage, entities, materials, *hit.collider2, *hit.magnitude);
    }
    if damage.is_empty() {
        return array![];
    }
    let damage = damage.span();
    let mut updated: Array<Entity> = array![];
    let mut destroyed: Array<usize> = array![];
    let mut index = 0;
    for entity in entities {
        let mut entity = *entity;
        let mut total: u64 = 0;
        for (target, amount) in damage {
            if *target == index {
                total += (*amount).into();
            }
        }
        if total != 0 {
            let hp: u64 = entity.hp.into();
            entity.hp = if total >= hp {
                0
            } else {
                (hp - total).try_into().unwrap()
            };
            if entity.hp == 0 {
                destroyed.append(index);
            }
        }
        updated.append(entity);
        index += 1;
    }
    self.entities = updated;
    destroyed
}

/// `damage::hit`.
fn side(
    ref damage: Array<(usize, u32)>,
    entities: Span<Entity>,
    materials: Span<Material>,
    collider: Handle,
    force: Fixed,
) {
    if let Some(index) = entity_of(entities, collider) {
        let entity = entities[index];
        if *entity.kind != KIND_STATIC && *entity.alive {
            let material: usize = (*entity.material).into();
            let amount = damage_of(force, materials[material]);
            if amount != 0 {
                damage.append((index, amount));
            }
        }
    }
}

/// `damage::remove`: the removal edits (ascending), the scores, the cores left, `alive = false`.
fn remove(ref self: Rules, indices: Span<usize>, ref ops: Array<Op>) {
    if indices.is_empty() {
        return;
    }
    let materials = self.params.materials.span();
    let entities = self.entities.span();
    for index in indices {
        let entity = *entities[*index];
        ops.append(Op::Remove(entity.body));
        let material: usize = entity.material.into();
        self.score += *materials[material].score;
        if entity.kind == KIND_CORE {
            self.cores_left -= 1;
        }
    }
    let mut updated: Array<Entity> = array![];
    let mut next = indices;
    let mut index = 0;
    for entity in entities {
        let mut entity = *entity;
        if let Some(target) = next.get(0) {
            if *target.unbox() == index {
                entity.alive = false;
                let _ = next.pop_front();
            }
        }
        updated.append(entity);
        index += 1;
    }
    self.entities = updated;
}

/// `calm::is_calm` on a motion.
fn is_calm(motion: @Motion) -> bool {
    let v = *motion.linvel;
    let w = *motion.angvel;
    if abs_raw(v.x) >= EPS_V.raw || abs_raw(v.y) >= EPS_V.raw || abs_raw(w) >= EPS_W.raw {
        return false;
    }
    dot2(v.x, v.x, v.y, v.y) < EPS_V_SQ && w * w < EPS_W_SQ
}

/// `calm::outside`.
fn outside(point: Vec2, bounds: (Fixed, Fixed, Fixed, Fixed)) -> bool {
    let (min_x, min_y, max_x, max_y) = bounds;
    point.x.raw < min_x.raw
        || point.x.raw > max_x.raw
        || point.y.raw < min_y.raw
        || point.y.raw > max_y.raw
}

/// `calm::AbsRawTrait::abs_raw`.
fn abs_raw(value: Fixed) -> i64 {
    if value.raw >= 0 {
        value.raw
    } else if value.raw == -0x8000000000000000 {
        0x7fffffffffffffff
    } else {
        -value.raw
    }
}
