//! Slingshot: pull clamped to the `pull_radius` disk, launch velocity `-pull · launch_scale`
//! (`docs/DESIGN.md` D3). Lot G3.
//!
//! Both formulas are the client's (`client/src/aim/pull.ts`, `client/src/aim/arc.ts`) bit for bit:
//! the clamp is integer-only (ceiling square root, quotients truncated toward zero) and the launch
//! velocity is an exact integer times raw product.

use core::num::traits::Sqrt;
use fixed::FixedTrait;
use rapier2d::prelude::{
    ColliderBuilderTrait, Fixed, Pose2, RigidBodyBuilderTrait, Rot2, Vec2, WorldTrait,
};
use slingfall_level::inputs::Shot;
use slingfall_level::level::Level;
use crate::calm::CalmTrait;
use crate::world::{Game, errors};

/// Radius of the pebble, 0.25 m (`docs/DESIGN.md` D12).
pub const PEBBLE_RADIUS: Fixed = Fixed { raw: 0x40000000 };
/// Density of the pebble, 4.
pub const PEBBLE_DENSITY: Fixed = Fixed { raw: 0x400000000 };
/// Friction of the pebble, 0.5.
pub const PEBBLE_FRICTION: Fixed = Fixed { raw: 0x80000000 };
/// Restitution of the pebble, 0.2 (raw rounded to nearest, as `levelc`).
pub const PEBBLE_RESTITUTION: Fixed = Fixed { raw: 858993459 };
/// `user_data` of the pebble's collider: above every entity index (entities use their index).
pub const PEBBLE_USER_DATA: u128 = 0x100000000;
/// Linear damping of the pebble, 1 (`docs/DESIGN.md` D5: a pebble rolling on flat ground would
/// never let the calm rule end the shot). D5's first choice, 0.5 / 2, still hit the tick cap on
/// three of the six measured pulls; 1 / 4 ends all six by the calm rule (lot G3b, `README.md`).
pub const PEBBLE_LINEAR_DAMPING: Fixed = Fixed { raw: 0x100000000 };
/// Angular damping of the pebble, 4.
pub const PEBBLE_ANGULAR_DAMPING: Fixed = Fixed { raw: 0x400000000 };
/// The only projectile kind for now: the pebble.
pub const KIND_PEBBLE: u8 = 0;

/// Clamps a pull to the disk of radius `radius` (`docs/DESIGN.md` D3, `clampPull` of
/// `client/src/aim/pull.ts`): kept when `px² + py² <= R²`; otherwise `s = ceil_isqrt(px² +
/// py²)`
/// and each component becomes `trunc(p · R / s)`, truncated toward zero. `s >= R + 1` there, so
/// the result lies inside the disk.
pub fn clamp_pull(px: i16, py: i16, radius: u16) -> (i16, i16) {
    let (ax, ay) = (magnitude(px), magnitude(py));
    let r: u64 = radius.into();
    let squared = ax * ax + ay * ay;
    if squared <= r * r {
        return (px, py);
    }
    let floor: u64 = squared.sqrt().into();
    let s = if floor * floor == squared {
        floor
    } else {
        floor + 1
    };
    // `squared > r² >= 0`, so `s >= 1`.
    let s: NonZero<u64> = s.try_into().unwrap();
    let (qx, _) = DivRem::div_rem(ax * r, s);
    let (qy, _) = DivRem::div_rem(ay * r, s);
    (signed(qx, px < 0), signed(qy, py < 0))
}

/// Launch velocity of a clamped pull: `(Fixed::from_int(-px) * launch_scale, Fixed::from_int(-py)
/// * launch_scale)`. `from_int` is exact and the product of an integer by a raw value needs no
/// rounding (the single floor of `Fixed * Fixed` is exact here): the client's `-pull ·
/// launch_scale`
/// on raw integers.
pub fn launch_velocity(px: i16, py: i16, launch_scale: Fixed) -> Vec2 {
    let px: i32 = px.into();
    let py: i32 = py.into();
    Vec2 {
        x: FixedTrait::from_int(-px) * launch_scale, y: FixedTrait::from_int(-py) * launch_scale,
    }
}

/// Spawns the pebble at `level.sling_anchor` (identity rotation, awake) with the launch velocity
/// of `shot`'s clamped pull, and starts a new shot: `shot_tick` and the calm counter restart. The
/// pebble carries [`PEBBLE_LINEAR_DAMPING`] and [`PEBBLE_ANGULAR_DAMPING`]. The `delay` ticks are
/// stepped by the caller before (`GameTrait::play_shot`).
///
/// # Panics
/// `errors::PEBBLE` when a pebble is already in the world; `errors::PROJECTILE_KIND` when the
/// level's projectile for this shot (`level.projectiles[game.shots_used]`) is not [`KIND_PEBBLE`]
/// (abilities are deferred).
pub fn launch(ref game: Game, level: @Level, shot: @Shot) {
    if game.pebble.is_some() {
        core::panic_with_felt252(errors::PEBBLE);
    }
    if *level.projectiles[game.shots_used.into()] != KIND_PEBBLE {
        core::panic_with_felt252(errors::PROJECTILE_KIND);
    }
    let (px, py) = clamp_pull(*shot.pull_x, *shot.pull_y, *level.pull_radius);
    let pose = Pose2 {
        translation: *level.sling_anchor,
        rotation: Rot2 { re: FixedTrait::from_int(1), im: FixedTrait::from_int(0) },
    };
    let body = RigidBodyBuilderTrait::dynamic()
        .position(pose)
        .linvel(launch_velocity(px, py, *level.launch_scale))
        .linear_damping(PEBBLE_LINEAR_DAMPING)
        .angular_damping(PEBBLE_ANGULAR_DAMPING)
        .build();
    let collider = ColliderBuilderTrait::ball(PEBBLE_RADIUS)
        .density(PEBBLE_DENSITY)
        .friction(PEBBLE_FRICTION)
        .restitution(PEBBLE_RESTITUTION)
        .user_data(PEBBLE_USER_DATA)
        .build();
    let (handle, _) = game.world.insert(body, collider);
    game.pebble = Some(handle);
    game.shot_tick = 0;
    game.calm = CalmTrait::new();
}

/// `|v|` of an `i16`, widened.
fn magnitude(v: i16) -> u64 {
    let wide: i32 = v.into();
    if wide < 0 {
        (-wide).try_into().unwrap()
    } else {
        wide.try_into().unwrap()
    }
}

/// `q` with the sign `negative`; `q <= 32768` (a quotient of `|p| · R / s` with `s > R`).
fn signed(q: u64, negative: bool) -> i16 {
    let wide: i32 = q.try_into().unwrap();
    let wide = if negative {
        -wide
    } else {
        wide
    };
    wide.try_into().unwrap()
}

#[cfg(test)]
mod tests {
    use rapier2d::prelude::{Fixed, Vec2};
    use slingfall_testing::opaque;
    use super::{clamp_pull, launch_velocity};

    /// `client/src/aim/pull.test.ts`, verbatim: `[px, py, radius, x, y]`.
    #[test]
    fn test_clamp_pull_client_vectors() {
        let cases: Array<(i16, i16, u16, i16, i16)> = array![
            (0, 0, 1024, 0, 0), (1024, 0, 1024, 1024, 0), (-1024, 0, 1024, -1024, 0),
            (600, 800, 1000, 600, 800), // exactly on the circle: kept
            (300, -400, 500, 300, -400),
            (300, -400, 499, 299, -399), (1000, 300, 1024, 979, 293),
            (-1000, -300, 1024, -979, -293), // symmetric: truncation toward zero, not floor
            (1024, 1024, 1024, 723, 723), (-1024, 1024, 1024, -723, 723),
            (1024, -1024, 512, 361, -361), (-7, 1, 3, -2, 0), (1, 1, 0, 0, 0),
        ];
        for (px, py, radius, x, y) in cases {
            assert_eq!(clamp_pull(opaque(px), py, radius), (x, y));
        }
    }

    /// The client's "never leaves the disk" sweep, same grid.
    #[test]
    fn test_clamp_pull_stays_in_the_disk() {
        let mut px: i16 = -1100;
        while px <= 1100 {
            let mut py: i16 = -1100;
            while py <= 1100 {
                let (x, y) = clamp_pull(px, py, 1024);
                let (x, y): (i64, i64) = (x.into(), y.into());
                assert!(x * x + y * y <= 1024 * 1024);
                py += 91;
            }
            px += 137;
        }
    }

    /// Extremes of `i16`: no overflow, the result stays inside the disk.
    #[test]
    fn test_clamp_pull_extremes() {
        // Python `math.isqrt` reference: s = 46341, 32768 · 1024 // 46341 = 724.
        assert_eq!(clamp_pull(-0x8000, -0x8000, 1024), (-724, -724));
        // Exact roots put the result on the circle.
        assert_eq!(clamp_pull(0x7fff, 0, 1024), (1024, 0));
        assert_eq!(clamp_pull(0, -0x8000, 1), (0, -1));
    }

    /// `client/src/aim/arc.test.ts`: pull `(-775, -270)`, `launch_scale` raw 85899346.
    #[test]
    fn test_launch_velocity_client_vector() {
        let v = launch_velocity(-775, -270, Fixed { raw: 85899346 });
        assert_eq!(v, Vec2 { x: Fixed { raw: 66571993150 }, y: Fixed { raw: 23192823420 } });
        let v = launch_velocity(1024, 0, Fixed { raw: 85899346 });
        assert_eq!(v, Vec2 { x: Fixed { raw: -87960930304 }, y: Fixed { raw: 0 } });
    }

    #[test]
    fn steps_clamp_pull__outside() {
        opaque(clamp_pull(opaque(1000), 300, 1024));
    }
}
