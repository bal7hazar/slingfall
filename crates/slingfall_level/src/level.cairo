//! `Level`, `Material`, `BodyDef`, `ShapeDef` and their `Serde` felt layout (`docs/DESIGN.md` D2).
//!
//! The felt layout of a level is the `Serde` layout of `Level`: every scalar is one felt holding
//! its raw Q32.32 `i64` (a negative value `-x` is `P - x`), arrays are length-prefixed, an enum is
//! its variant index then its payload, and a `Pose2` is `[x, y, re, im]`.

use fixed::Fixed;
use glam::Vec2;
use crate::errors;
use crate::hash::serde_hash;

pub mod fixtures;
#[cfg(test)]
pub mod tests;

/// The format version of `Level.version`, echoed in the outputs.
pub const LEVEL_VERSION: u16 = 1;
/// Largest `Level.shots`.
pub const SHOTS_MAX: u8 = 5;
/// Largest `Level.tick_cap` (ticks per shot).
pub const TICK_CAP_MAX: u16 = 360;
/// Largest `Level.pull_radius`: `inputs::PULL_MAX` as a `u16`.
pub const PULL_RADIUS_MAX: u16 = 1024;
/// `BodyDef.kind` of a body that never moves.
pub const KIND_STATIC: u8 = 0;
/// `BodyDef.kind` of a destructible block.
pub const KIND_BLOCK: u8 = 1;
/// `BodyDef.kind` of a target: destroying every core wins the level.
pub const KIND_CORE: u8 = 2;

/// `Pose2` / `Rot2` are rapier's own types (`rapier_math`, re-exported by `rapier2d::prelude`):
/// translation then rotation, felts `[x, y, re, im]`; one type shared with the rules and the
/// engine.
pub use rapier2d::prelude::{Pose2, Rot2};

/// Physical and game properties of a body: rapier's density, friction and restitution, then the
/// damage model of `docs/DESIGN.md` D6 (`hp -= floor((force - force_threshold) ·
/// damage_per_impulse_dt)`) and the score of the body when destroyed. Seven felts.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Material {
    pub density: Fixed,
    pub friction: Fixed,
    pub restitution: Fixed,
    pub hp: u32,
    pub force_threshold: Fixed,
    pub damage_per_impulse_dt: Fixed,
    pub score: u32,
}

/// Collider shape, in the body frame. Felts: variant index, then the payload.
#[derive(Drop, Serde, PartialEq, Debug)]
pub enum ShapeDef {
    /// Circle of the given radius.
    Ball: Fixed,
    /// Box of the given half extents (`hx`, `hy`).
    Cuboid: (Fixed, Fixed),
    /// Convex polygon, counter-clockwise vertices.
    Polygon: Array<Vec2>,
    /// Half-plane bounded by the line through the origin, with the given outward unit normal.
    HalfSpace: Vec2,
}

/// One body of the level. `kind` is `KIND_STATIC`, `KIND_BLOCK` or `KIND_CORE`; `material` indexes
/// `Level.materials`. Dynamic bodies are stored pre-settled and start asleep.
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct BodyDef {
    pub kind: u8,
    pub shape: ShapeDef,
    pub pose: Pose2,
    pub material: u8,
}

/// A level: world settings, sling, projectiles, materials and bodies.
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct Level {
    /// Format version, `LEVEL_VERSION`; echoed in the outputs.
    pub version: u16,
    /// Human identifier; the identity on-chain is `level_hash`.
    pub level_id: u32,
    /// Reserved (no randomness in the MVP); echoed in the outputs.
    pub seed: felt252,
    pub gravity_y: Fixed,
    /// Shots per attempt, `1..=SHOTS_MAX`.
    pub shots: u8,
    /// Ticks per shot, `1..=TICK_CAP_MAX`.
    pub tick_cap: u16,
    /// Despawn AABB `(min_x, min_y, max_x, max_y)`.
    pub bounds: (Fixed, Fixed, Fixed, Fixed),
    pub sling_anchor: Vec2,
    /// Radius of the disk the pull is clamped to, in pull units, `1..=PULL_RADIUS_MAX`.
    pub pull_radius: u16,
    /// Pull units to velocity: `v = -pull · launch_scale`.
    pub launch_scale: Fixed,
    /// Projectile kind of each shot (MVP: all 0 = pebble); one entry per shot.
    pub projectiles: Array<u8>,
    pub materials: Array<Material>,
    pub bodies: Array<BodyDef>,
}

pub trait LevelTrait {
    /// `level_hash`: `poseidon_hash_span` of the `Serde` felts of the level.
    fn hash(self: @Level) -> felt252;
    /// Panics (`errors::*`) unless the level is well formed: version, shots, tick cap, pull
    /// radius, non-empty bounds holding the sling anchor and every non-static body, body kinds,
    /// material indices and polygon sizes.
    fn validate(self: @Level);
}

impl LevelImpl of LevelTrait {
    fn hash(self: @Level) -> felt252 {
        serde_hash(self)
    }

    fn validate(self: @Level) {
        if *self.version != LEVEL_VERSION {
            core::panic_with_felt252(errors::VERSION);
        }
        let shots = *self.shots;
        if shots == 0 || shots > SHOTS_MAX || self.projectiles.len() != shots.into() {
            core::panic_with_felt252(errors::SHOTS);
        }
        let tick_cap = *self.tick_cap;
        if tick_cap == 0 || tick_cap > TICK_CAP_MAX {
            core::panic_with_felt252(errors::TICK_CAP);
        }
        let pull_radius = *self.pull_radius;
        if pull_radius == 0 || pull_radius > PULL_RADIUS_MAX {
            core::panic_with_felt252(errors::PULL_RADIUS);
        }
        let (min_x, min_y, max_x, max_y) = *self.bounds;
        if min_x.raw >= max_x.raw || min_y.raw >= max_y.raw {
            core::panic_with_felt252(errors::BOUNDS);
        }
        let anchor = *self.sling_anchor;
        if !inside(anchor, min_x, min_y, max_x, max_y) {
            core::panic_with_felt252(errors::BOUNDS);
        }
        let materials = self.materials.len();
        for body in self.bodies.span() {
            if *body.kind > KIND_CORE {
                core::panic_with_felt252(errors::BODY_KIND);
            }
            if (*body.material).into() >= materials {
                core::panic_with_felt252(errors::MATERIAL);
            }
            if let ShapeDef::Polygon(points) = body.shape {
                if points.len() < 3 {
                    core::panic_with_felt252(errors::SHAPE);
                }
            }
            if *body.kind != KIND_STATIC
                && !inside(*body.pose.translation, min_x, min_y, max_x, max_y) {
                core::panic_with_felt252(errors::BOUNDS);
            }
        }
    }
}

/// `point` lies in the closed box `[min_x, max_x] × [min_y, max_y]`.
fn inside(point: Vec2, min_x: Fixed, min_y: Fixed, max_x: Fixed, max_y: Fixed) -> bool {
    point.x.raw >= min_x.raw
        && point.x.raw <= max_x.raw
        && point.y.raw >= min_y.raw
        && point.y.raw <= max_y.raw
}
