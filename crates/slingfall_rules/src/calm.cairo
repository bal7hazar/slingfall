//! End of shot: all asleep, calm over 20 ticks, tick cap; out-of-bounds removal
//! (`docs/DESIGN.md` D5). Lot G3.
//!
//! One pass per tick reads every live dynamic body once (the pebble included) and decides both
//! rules: a body whose translation leaves `level.bounds` is removed (a block or core counts as
//! destroyed and scores; the pebble is simply removed), and the shot is over when every remaining
//! dynamic body is asleep, or when every awake one has `|v|² < ε_v²` and `ω² < ε_ω²` for
//! `CALM_TICKS` consecutive ticks (then all of them are put to sleep). The tick cap is checked by
//! `GameTrait::tick`, which knows `shot_tick`.

use fixed::wide::dot2;
use rapier2d::prelude::{Fixed, RigidBody, RigidBodyTrait, Vec2, WorldTrait};
use slingfall_level::level::{KIND_STATIC, Level};
use crate::damage;
use crate::world::Game;

/// Consecutive calm ticks that end a shot.
pub const CALM_TICKS: u8 = 20;
/// `ε_v = 0.05 m/s`, raw rounded to nearest; a component at or above it is not calm.
pub const EPS_V: Fixed = Fixed { raw: 214748365 };
/// `ε_v² = 0.0025 m²/s²`, raw floored (`floor(0.0025 · 2^32)`).
pub const EPS_V_SQ: Fixed = Fixed { raw: 10737418 };
/// `ε_ω = 0.05 rad/s`, raw rounded to nearest.
pub const EPS_W: Fixed = Fixed { raw: 214748365 };
/// `ε_ω² = 0.0025 rad²/s²`, raw floored.
pub const EPS_W_SQ: Fixed = Fixed { raw: 10737418 };

/// The calm counter of the current shot. Part of the game state (`Serde`, chunked replays).
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Calm {
    /// Consecutive ticks with every awake dynamic body calm.
    pub ticks: u8,
}

/// What [`CalmTrait::update`] found this tick.
#[derive(Drop, Debug, PartialEq)]
pub struct CalmReport {
    /// Entities removed for leaving the bounds, ascending (the pebble is not an entity).
    pub out_of_bounds: Array<usize>,
    /// D5 (1) or (2) holds: the shot is over.
    pub shot_over: bool,
}

#[generate_trait]
pub impl CalmImpl of CalmTrait {
    /// A counter at zero.
    fn new() -> Calm {
        Calm { ticks: 0 }
    }

    /// Runs after each tick's damage removals: removes the out-of-bounds bodies, then decides
    /// whether the shot is over (D5 (1) all asleep, or (2) calm for `CALM_TICKS` ticks, in which
    /// case every awake dynamic body is put to sleep).
    fn update(ref self: Calm, ref game: Game, level: @Level) -> CalmReport {
        let bounds = *level.bounds;
        let mut out_of_bounds: Array<usize> = array![];
        let mut all_asleep = true;
        let mut all_calm = true;
        let mut index = 0;
        for entity in game.entities.span() {
            if *entity.alive && *entity.kind != KIND_STATIC {
                let body = game.world.body(*entity.body).unwrap();
                if !body.is_sleeping() {
                    if outside(body.translation(), bounds) {
                        out_of_bounds.append(index);
                    } else {
                        all_asleep = false;
                        all_calm = all_calm && is_calm(@body);
                    }
                }
            }
            index += 1;
        }
        if let Some(pebble) = game.pebble {
            let body = game.world.body(pebble).unwrap();
            if !body.is_sleeping() {
                if outside(body.translation(), bounds) {
                    let _ = game.world.remove_body(pebble);
                    game.pebble = None;
                } else {
                    all_asleep = false;
                    all_calm = all_calm && is_calm(@body);
                }
            }
        }
        damage::remove(ref game, level, out_of_bounds.span());
        let shot_over = if all_asleep {
            self.ticks = 0;
            true
        } else if all_calm {
            self.ticks += 1;
            if self.ticks >= CALM_TICKS {
                sleep_all(ref game);
                self.ticks = 0;
                true
            } else {
                false
            }
        } else {
            self.ticks = 0;
            false
        };
        CalmReport { out_of_bounds, shot_over }
    }
}

/// `|v|² < ε_v²` and `ω² < ε_ω²`, squared compares through one fused `dot2` and one
/// product.
/// A component at or above `ε` fails first (and the squares then cannot overflow): its floored
/// square is already at least `ε²`, so the prefilter never changes the answer.
pub fn is_calm(body: @RigidBody) -> bool {
    let v = body.linvel();
    let w = body.angvel();
    if v.x.abs_raw() >= EPS_V.raw || v.y.abs_raw() >= EPS_V.raw || w.abs_raw() >= EPS_W.raw {
        return false;
    }
    dot2(v.x, v.x, v.y, v.y) < EPS_V_SQ && w * w < EPS_W_SQ
}

/// Puts every awake live dynamic body (the pebble included) to sleep: `sleep()` and write back.
pub fn sleep_all(ref game: Game) {
    for entity in game.entities.span() {
        if *entity.alive && *entity.kind != KIND_STATIC {
            sleep_body(ref game, *entity.body);
        }
    }
    if let Some(pebble) = game.pebble {
        sleep_body(ref game, pebble);
    }
}

fn sleep_body(ref game: Game, handle: rapier2d::prelude::Handle) {
    let mut body = game.world.body(handle).unwrap();
    if !body.is_sleeping() {
        body.sleep();
        let _ = game.world.set_body(handle, body);
    }
}

/// `point` lies outside the closed box `bounds = (min_x, min_y, max_x, max_y)`.
fn outside(point: Vec2, bounds: (Fixed, Fixed, Fixed, Fixed)) -> bool {
    let (min_x, min_y, max_x, max_y) = bounds;
    point.x.raw < min_x.raw
        || point.x.raw > max_x.raw
        || point.y.raw < min_y.raw
        || point.y.raw > max_y.raw
}

/// `|raw|`, saturating at `i64::MAX` for `i64::MIN`.
#[generate_trait]
impl AbsRawImpl of AbsRawTrait {
    fn abs_raw(self: Fixed) -> i64 {
        if self.raw >= 0 {
            self.raw
        } else if self.raw == -0x8000000000000000 {
            0x7fffffffffffffff
        } else {
            -self.raw
        }
    }
}

#[cfg(test)]
mod tests;
