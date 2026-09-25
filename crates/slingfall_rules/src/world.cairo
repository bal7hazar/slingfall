//! World builder from a `Level`: shapes, materials, `user_data`, pre-slept bodies
//! (`docs/DESIGN.md` D2). Lot G3.
//!
//! [`Game`] is the whole state of a replay: the rapier [`World`] plus the game fields. One body
//! and one collider per `BodyDef`, inserted in level order into an empty world, so entity `i`
//! owns the body and collider handles of slot index `i` (checked at build time); the pebble is
//! the only other body. [`GameTrait::tick`] is one 60 Hz tick of the rules: step with force
//! events, damage (D6), removals, out-of-bounds and calm (D5), win (D7).

use core::poseidon::poseidon_hash_span;
use rapier2d::prelude::{
    CONTACT_FORCE_EVENTS, ColliderBuilder, ColliderBuilderTrait, Fixed, Handle,
    IntegrationParameters, RigidBodyBuilderTrait, RigidBodyTrait, Vec2, World, WorldState,
    WorldTrait,
};
use slingfall_level::inputs::Shot;
use slingfall_level::level::{KIND_CORE, KIND_STATIC, Level, LevelTrait, ShapeDef};
use crate::calm::{Calm, CalmTrait, sleep_all};
use crate::{damage, score, sling};

#[cfg(test)]
pub mod fixtures;
#[cfg(test)]
mod tests;

/// Panic messages of the rules (`felt252` short strings, stable API, `AGENTS.md` §7).
pub mod errors {
    /// A `ShapeDef::Polygon` that rapier rejects (not strictly convex counter-clockwise, or more
    /// than 8 vertices).
    pub const POLYGON: felt252 = 'rules: polygon';
    /// The world did not issue entity `i` the handles of slot `i` (an internal invariant).
    pub const HANDLE_ORDER: felt252 = 'rules: handle order';
    /// `launch` while a pebble is already in the world.
    pub const PEBBLE: felt252 = 'rules: pebble in flight';
    /// `launch` of a shot whose `level.projectiles` kind is not 0 (pebble); abilities are deferred.
    pub const PROJECTILE_KIND: felt252 = 'rules: projectile kind';
    /// `play_shot` after the level was won or every shot was used.
    pub const LEVEL_OVER: felt252 = 'rules: level over';
}

/// A body of the level and its game state. `kind` and `material` are the `BodyDef`'s.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Entity {
    pub body: Handle,
    pub collider: Handle,
    pub kind: u8,
    pub material: u8,
    /// Hit points left; starts at the material's `hp`, never negative.
    pub hp: u32,
    /// `false` once destroyed (damage or out of bounds): the body is no longer in the world.
    pub alive: bool,
}

/// A replay in progress. Holds dicts (the world): pass it by `ref`. Saved and restored for the
/// chunked replay through [`GameTrait::to_state`] / [`GameTrait::from_state`].
#[derive(Destruct)]
pub struct Game {
    pub world: World,
    pub level_hash: felt252,
    /// One per `level.bodies`, same order.
    pub entities: Array<Entity>,
    pub cores_left: u8,
    pub score: u32,
    pub shots_used: u8,
    /// Ticks stepped since the start of the level, every shot and delay included.
    pub tick: u32,
    /// Ticks stepped since the current pebble was launched (the tick cap counts these).
    pub shot_tick: u32,
    pub pebble: Option<Handle>,
    /// The pebble has had its first contact (a contact-force event involving it): it no longer
    /// counts in the calm test (D5, spent pebble). Cleared at launch.
    pub pebble_contact: bool,
    /// `shot_tick` of that first contact, 0 while there is none.
    pub pebble_contact_tick: u32,
    pub calm: Calm,
}

/// [`Game`] with its world saved as a [`WorldState`]: every field `Serde`.
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct GameState {
    pub world: WorldState,
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
}

/// What one tick did.
#[derive(Drop, Debug, PartialEq)]
pub struct TickReport {
    /// Entities destroyed this tick: by damage (ascending), then out of bounds (ascending).
    pub destroyed: Array<usize>,
    /// The shot is over: D5 (1) all asleep, (2) calm (the spent pebble excluded), or (3) the tick
    /// cap.
    pub shot_over: bool,
    /// Every core is destroyed.
    pub won: bool,
    /// The shot is over by the tick cap only (neither D5 (1) nor (2) held).
    pub capped: bool,
}

/// What one shot did.
#[derive(Drop, Debug, PartialEq)]
pub struct ShotReport {
    /// Ticks stepped: the delay, then the flight until the end of the shot.
    pub ticks: u32,
    /// Ticks from the launch to the end of the shot.
    pub shot_ticks: u32,
    /// The shot ended on the tick cap rather than on D5 (1) or (2).
    pub capped: bool,
    /// Entities destroyed during the shot, in tick order.
    pub destroyed: Array<usize>,
    /// The level is won (the unused-shot bonus is included in `Game.score`).
    pub won: bool,
}

#[generate_trait]
pub impl GameImpl of GameTrait {
    /// Builds the world of `level`: gravity `(0, gravity_y)`, rapier's default parameters (dt
    /// 1/60, 4 solver iterations); per `BodyDef`, a fixed body (static) or a dynamic body inserted
    /// asleep at its stored pose (block, core), and one collider with the material's density,
    /// friction, restitution and `contact_force_event_threshold = force_threshold`, `user_data` =
    /// entity index, contact-force events on blocks and cores.
    ///
    /// # Panics
    /// `errors::POLYGON` for a polygon rapier rejects; an out-of-range material index (run
    /// `LevelTrait::validate` first).
    fn new(level: @Level) -> Game {
        let params: IntegrationParameters = Default::default();
        let mut world = WorldTrait::new(Vec2 { x: Fixed { raw: 0 }, y: *level.gravity_y }, params);
        let materials = level.materials.span();
        let mut entities: Array<Entity> = array![];
        let mut cores_left: u8 = 0;
        let mut index: usize = 0;
        for def in level.bodies.span() {
            let kind = *def.kind;
            let material = *materials[(*def.material).into()];
            let mut collider = shape(def.shape)
                .density(material.density)
                .friction(material.friction)
                .restitution(material.restitution)
                .contact_force_event_threshold(material.force_threshold)
                .user_data(index.into());
            let body = if kind == KIND_STATIC {
                RigidBodyBuilderTrait::fixed().position(*def.pose).build()
            } else {
                collider = collider.active_events(CONTACT_FORCE_EVENTS);
                RigidBodyBuilderTrait::dynamic().position(*def.pose).sleeping(true).build()
            };
            let (body, collider) = world.insert(body, collider.build());
            if body.index != index || collider.index != index {
                core::panic_with_felt252(errors::HANDLE_ORDER);
            }
            entities
                .append(
                    Entity {
                        body, collider, kind, material: *def.material, hp: material.hp, alive: true,
                    },
                );
            if kind == KIND_CORE {
                cores_left += 1;
            }
            index += 1;
        }
        let mut game = Game {
            world,
            level_hash: level.hash(),
            entities,
            cores_left,
            score: 0,
            shots_used: 0,
            tick: 0,
            shot_tick: 0,
            pebble: None,
            pebble_contact: false,
            pebble_contact_tick: 0,
            calm: CalmTrait::new(),
        };
        settle(ref game);
        game
    }

    /// Saves the game: the world through `WorldTrait::to_state`, the rest copied.
    fn to_state(ref self: Game) -> GameState {
        let mut entities: Array<Entity> = array![];
        entities.append_span(self.entities.span());
        GameState {
            world: self.world.to_state(),
            level_hash: self.level_hash,
            entities,
            cores_left: self.cores_left,
            score: self.score,
            shots_used: self.shots_used,
            tick: self.tick,
            shot_tick: self.shot_tick,
            pebble: self.pebble,
            pebble_contact: self.pebble_contact,
            pebble_contact_tick: self.pebble_contact_tick,
            calm: self.calm,
        }
    }

    /// Restores a game saved by [`GameTrait::to_state`]; it steps exactly as the saved one.
    fn from_state(state: GameState) -> Game {
        let GameState {
            world,
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
        Game {
            world: WorldTrait::from_state(world),
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
        }
    }

    /// One tick: `step_with_force_events`, damage (D6) and its removals (ascending handles),
    /// out-of-bounds removals and the calm rule (D5), the tick cap, the win check (D7).
    fn tick(ref self: Game, level: @Level) -> TickReport {
        let (_, events) = self.world.step_with_force_events();
        self.tick += 1;
        self.shot_tick += 1;
        if self.pebble.is_some()
            && !self.pebble_contact
            && sling::pebble_touched(self.entities.span(), events.span()) {
            self.pebble_contact = true;
            self.pebble_contact_tick = self.shot_tick;
        }
        let mut destroyed = damage::apply(ref self, level, events.span());
        damage::remove(ref self, level, destroyed.span());
        let mut calm = self.calm;
        let report = calm.update(ref self, level);
        self.calm = calm;
        destroyed.append_span(report.out_of_bounds.span());
        let capped = !report.shot_over && self.shot_tick >= (*level.tick_cap).into();
        TickReport {
            destroyed, shot_over: report.shot_over || capped, won: score::won(@self), capped,
        }
    }

    /// One shot: `shot.delay` ticks without a pebble (stepped like any tick), the launch, ticks
    /// until the shot is over, then [`GameTrait::end_shot`].
    ///
    /// # Panics
    /// `errors::LEVEL_OVER` when the level is already won or every shot was used.
    fn play_shot(ref self: Game, level: @Level, shot: @Shot) -> ShotReport {
        if score::won(@self) || self.shots_used >= *level.shots {
            core::panic_with_felt252(errors::LEVEL_OVER);
        }
        let mut destroyed: Array<usize> = array![];
        let mut ticks: u32 = 0;
        let delay: u32 = (*shot.delay).into();
        while ticks != delay {
            let report = self.tick(level);
            destroyed.append_span(report.destroyed.span());
            ticks += 1;
        }
        sling::launch(ref self, level, shot);
        let mut capped = false;
        loop {
            let report = self.tick(level);
            destroyed.append_span(report.destroyed.span());
            ticks += 1;
            if report.shot_over {
                capped = report.capped;
                break;
            }
        }
        let shot_ticks = self.shot_tick;
        self.end_shot(level, !capped);
        ShotReport { ticks, shot_ticks, capped, destroyed, won: score::won(@self) }
    }

    /// Ends the current shot: removes the pebble (if still in the world), counts the shot and,
    /// when the level is won, scores the unused shots. After a calm end (`at_rest`), the bodies
    /// the pebble's removal woke up (`World::remove_body` wakes its contact partners) are put back
    /// to sleep: they were asleep and at rest the tick before, and the next shot's flight then
    /// steps a sleeping structure.
    fn end_shot(ref self: Game, level: @Level, at_rest: bool) {
        if let Some(pebble) = self.pebble {
            let _ = self.world.remove_body(pebble);
            self.pebble = None;
            if at_rest {
                sleep_all(ref self);
            }
        }
        self.shots_used += 1;
        if score::won(@self) {
            score::on_win(ref self, *level.shots - self.shots_used);
        }
    }

    /// D4 `final_state_hash`: Poseidon over the raw poses `[x, y, re, im]` of the dynamic bodies
    /// still in the world, in ascending handle (slot) order, the pebble included while it exists.
    /// Takes `ref` because the world's sets are dicts.
    fn final_state_hash(ref self: Game) -> felt252 {
        let mut felts: Array<felt252> = array![];
        let mut pebble = self.pebble;
        for entity in self.entities.span() {
            if let Some(handle) = pebble {
                if handle.index < *entity.body.index {
                    self.world.body(handle).unwrap().position().serialize(ref felts);
                    pebble = None;
                }
            }
            if *entity.alive && *entity.kind != KIND_STATIC {
                self.world.body(*entity.body).unwrap().position().serialize(ref felts);
            }
        }
        if let Some(handle) = pebble {
            self.world.body(handle).unwrap().position().serialize(ref felts);
        }
        poseidon_hash_span(felts.span())
    }
}

/// Makes the pre-slept start stick. rapier's user-changes stage wakes the parent of every
/// collider flagged as changed (a freshly inserted one included) at the next step, so bodies
/// built `sleeping(true)` would all wake at tick 1 and the whole structure would be solved during
/// the pebble's flight. One step with `dt = 0` consumes those flags (and builds the mass
/// properties, broad-phase and contact pairs) without moving anything: integration and the solver
/// scale every velocity and position update by `dt`. Then every dynamic body goes back to sleep
/// at its stored pose and `dt` is restored. The step's events are dropped; `tick` stays 0.
fn settle(ref game: Game) {
    let dt = game.world.integration_parameters.dt;
    game.world.integration_parameters.dt = Fixed { raw: 0 };
    let _ = game.world.step();
    game.world.integration_parameters.dt = dt;
    sleep_all(ref game);
}

/// The collider builder of a level shape, default settings otherwise.
fn shape(def: @ShapeDef) -> ColliderBuilder {
    match def {
        ShapeDef::Ball(radius) => ColliderBuilderTrait::ball(*radius),
        ShapeDef::Cuboid((hx, hy)) => ColliderBuilderTrait::cuboid(*hx, *hy),
        ShapeDef::Polygon(points) => ColliderBuilderTrait::convex_polygon(points.span())
            .expect(errors::POLYGON),
        ShapeDef::HalfSpace(normal) => ColliderBuilderTrait::halfspace(*normal),
    }
}
