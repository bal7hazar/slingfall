//! Tests of `level`: felt layouts, Serde round trips, golden hashes, validation panics, probes.

use core::fmt::Debug;
use fixed::Fixed;
use glam::Vec2;
use slingfall_testing::opaque;
use crate::hash::{serde_hash, to_felts};
use crate::inputs::PULL_MAX;
use crate::level::fixtures::{
    CORES3_HASH, ONE_BLOCK_HASH, PILE10_HASH, cores3, cores3_felts, one_block, one_block_felts,
    pile10, pile10_felts,
};
use crate::level::{
    BodyDef, KIND_BLOCK, KIND_CORE, KIND_STATIC, LEVEL_VERSION, Level, LevelTrait, Material,
    PULL_RADIUS_MAX, Pose2, Rot2, SHOTS_MAX, ShapeDef, TICK_CAP_MAX,
};

const P_MINUS_1: felt252 = -1;

/// `n` as a Q32.32 value.
fn fx(n: i64) -> Fixed {
    Fixed { raw: n * 0x100000000 }
}

fn vec(x: i64, y: i64) -> Vec2 {
    Vec2 { x: fx(x), y: fx(y) }
}

fn upright(x: i64, y: i64) -> Pose2 {
    Pose2 { translation: vec(x, y), rotation: Rot2 { re: fx(1), im: fx(0) } }
}

fn material() -> Material {
    Material {
        density: fx(1),
        friction: Fixed { raw: 2576980378 },
        restitution: Fixed { raw: 429496730 },
        hp: 100,
        force_threshold: fx(40),
        damage_per_impulse_dt: fx(1),
        score: 50,
    }
}

fn block(x: i64, y: i64, material: u8) -> BodyDef {
    BodyDef {
        kind: KIND_BLOCK, shape: ShapeDef::Cuboid((fx(1), fx(1))), pose: upright(x, y), material,
    }
}

/// A valid level with the given shots, tick cap, pull radius and bodies, one material, bounds
/// `[-10, 50] × [-10, 40]` and the sling at `(3, 2)`.
pub fn minimal_level(shots: u8, tick_cap: u16, pull_radius: u16, bodies: Array<BodyDef>) -> Level {
    let mut projectiles: Array<u8> = array![];
    for _ in 0..shots {
        projectiles.append(0);
    }
    Level {
        version: LEVEL_VERSION,
        level_id: 7,
        seed: 0,
        gravity_y: Fixed { raw: -42133629174 },
        shots,
        tick_cap,
        bounds: (fx(-10), fx(-10), fx(50), fx(40)),
        sling_anchor: vec(3, 2),
        pull_radius,
        launch_scale: Fixed { raw: 85899346 },
        projectiles,
        materials: array![material()],
        bodies,
    }
}

fn valid() -> Level {
    minimal_level(3, 360, 1024, array![block(20, 1, 0)])
}

fn assert_round_trip<T, +Serde<T>, +PartialEq<T>, +Drop<T>, +Debug<T>>(value: T) {
    let felts = to_felts(@value);
    let mut span = felts.span();
    let back: T = Serde::deserialize(ref span).expect('round trip: deserialize');
    assert!(span.is_empty(), "round trip: trailing felts");
    assert_eq!(back, value);
}

// ---------------------------------------------------------------------------------------------
// Felt layout
// ---------------------------------------------------------------------------------------------

#[test]
fn test_shape_felt_layout() {
    // Variant index, then the payload; negative raw values are `P - x`.
    let ball = ShapeDef::Ball(Fixed { raw: -1 });
    assert_eq!(to_felts(@ball), array![0, P_MINUS_1]);
    let cuboid = ShapeDef::Cuboid((Fixed { raw: 2 }, Fixed { raw: -3 }));
    assert_eq!(to_felts(@cuboid), array![1, 2, -3]);
    let polygon = ShapeDef::Polygon(
        array![vec(0, 0), Vec2 { x: Fixed { raw: 5 }, y: Fixed { raw: -6 } }],
    );
    assert_eq!(to_felts(@polygon), array![2, 2, 0, 0, 5, -6]);
    let half_space = ShapeDef::HalfSpace(
        Vec2 { x: Fixed { raw: 0 }, y: Fixed { raw: 0x100000000 } },
    );
    assert_eq!(to_felts(@half_space), array![3, 0, 0x100000000]);
}

#[test]
fn test_pose_and_body_felt_layout() {
    // A `Pose2` is `[x, y, re, im]`, the layout of `rapier_math::pose2::Pose2`.
    let pose = Pose2 {
        translation: Vec2 { x: Fixed { raw: 1 }, y: Fixed { raw: -2 } },
        rotation: Rot2 { re: Fixed { raw: 3 }, im: Fixed { raw: -4 } },
    };
    assert_eq!(to_felts(@pose), array![1, -2, 3, -4]);
    let body = BodyDef {
        kind: KIND_CORE, shape: ShapeDef::Ball(Fixed { raw: 9 }), pose, material: 3,
    };
    assert_eq!(to_felts(@body), array![2, 0, 9, 1, -2, 3, -4, 3]);
}

#[test]
fn test_material_felt_layout() {
    let m = Material {
        density: Fixed { raw: 1 },
        friction: Fixed { raw: 2 },
        restitution: Fixed { raw: 3 },
        hp: 4,
        force_threshold: Fixed { raw: 5 },
        damage_per_impulse_dt: Fixed { raw: -6 },
        score: 7,
    };
    assert_eq!(to_felts(@m), array![1, 2, 3, 4, 5, -6, 7]);
}

#[test]
fn test_level_header_felt_layout() {
    let felts = to_felts(@minimal_level(2, 360, 1024, array![]));
    let expected: Array<felt252> = array![
        1, 7, 0, -42133629174, 2, 360, // version, id, seed, gravity_y, shots, tick_cap
        -10 * 0x100000000, -10 * 0x100000000, 50 * 0x100000000, 40 * 0x100000000, // bounds
        3 * 0x100000000, 2 * 0x100000000, // sling_anchor
        1024,
        85899346, // pull_radius, launch_scale
        2, 0, 0, // projectiles
        1, 0x100000000, 2576980378,
        429496730, 100, 40 * 0x100000000, 0x100000000, 50, // materials
        0 // bodies
    ];
    assert_eq!(felts, expected);
}

#[test]
fn test_extreme_raw_values_serialise_as_p_minus_x() {
    let most_negative = Fixed { raw: -0x8000000000000000 };
    let felts = to_felts(@ShapeDef::Ball(most_negative));
    // P - 2^63, with P = 2^251 + 17 * 2^192 + 1.
    let p_minus_2_63: felt252 = -0x8000000000000000;
    assert_eq!(felts, array![0, p_minus_2_63]);
    assert_round_trip(ShapeDef::Ball(most_negative));
    assert_round_trip(ShapeDef::Ball(Fixed { raw: 0x7fffffffffffffff }));
}

#[test]
fn test_fixture_felts_have_the_expected_length() {
    // The count is part of the felt layout: 14 header felts, the projectiles (1 + shots), the
    // materials (1 + 4 · 7), then the bodies (1 + for each: kind, shape, 4 pose felts, material).
    assert_eq!(one_block_felts().len(), 72);
    assert_eq!(pile10_felts().len(), 146);
    assert_eq!(cores3_felts().len(), 133);
}

// ---------------------------------------------------------------------------------------------
// Serde round trips
// ---------------------------------------------------------------------------------------------

#[test]
fn test_serde_round_trip_types() {
    assert_round_trip(material());
    assert_round_trip(Rot2 { re: Fixed { raw: -1 }, im: Fixed { raw: 1 } });
    assert_round_trip(upright(-3, 4));
    let shapes = array![
        ShapeDef::Ball(fx(-1)), ShapeDef::Cuboid((fx(1), Fixed { raw: -7 })),
        ShapeDef::Polygon(array![]), ShapeDef::Polygon(array![vec(1, 2), vec(-3, 4), vec(5, -6)]),
        ShapeDef::HalfSpace(vec(0, 1)),
    ];
    for shape in shapes {
        assert_round_trip(shape);
    }
    for kind in array![KIND_STATIC, KIND_BLOCK, KIND_CORE] {
        assert_round_trip(
            BodyDef { kind, shape: ShapeDef::Ball(fx(1)), pose: upright(-1, -2), material: 2 },
        );
    }
}

#[test]
fn test_serde_round_trip_fixtures() {
    assert_round_trip(one_block());
    assert_round_trip(pile10());
    assert_round_trip(cores3());
    assert_round_trip(valid());
}

#[test]
fn test_fixture_felts_are_the_serialised_level() {
    assert_eq!(to_felts(@one_block()), one_block_felts());
    assert_eq!(to_felts(@pile10()), pile10_felts());
    assert_eq!(to_felts(@cores3()), cores3_felts());
}

// ---------------------------------------------------------------------------------------------
// Hashes
// ---------------------------------------------------------------------------------------------

/// The golden hashes are generated by `tools/levelc/levelc.py` (which implements Poseidon in
/// Python) and checked here against Cairo's `poseidon_hash_span`.
#[test]
fn test_level_hash_is_golden() {
    let cases: Array<(Level, felt252)> = array![
        (one_block(), ONE_BLOCK_HASH), (pile10(), PILE10_HASH), (cores3(), CORES3_HASH),
    ];
    for (level, expected) in cases {
        assert_eq!(level.hash(), expected);
        assert_eq!(serde_hash(@level), expected);
    }
}

#[test]
fn test_level_hash_binds_every_field() {
    let base = valid().hash();
    let other_bodies = minimal_level(3, 360, 1024, array![block(20, 2, 0)]).hash();
    let other_tick_cap = minimal_level(3, 359, 1024, array![block(20, 1, 0)]).hash();
    let other_shots = minimal_level(4, 360, 1024, array![block(20, 1, 0)]).hash();
    assert!(base != other_bodies);
    assert!(base != other_tick_cap);
    assert!(base != other_shots);
    assert_eq!(base, valid().hash());
}

// ---------------------------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------------------------

#[test]
fn test_validate_accepts_fixtures_and_boundaries() {
    one_block().validate();
    pile10().validate();
    cores3().validate();
    // Boundary values of every checked field, all valid.
    assert_eq!(PULL_RADIUS_MAX, PULL_MAX.try_into().unwrap());
    let cases: Array<(u8, u16, u16)> = array![
        (1, 1, 1), (SHOTS_MAX, TICK_CAP_MAX, PULL_RADIUS_MAX), (3, 360, 1024),
    ];
    for (shots, tick_cap, pull_radius) in cases {
        minimal_level(shots, tick_cap, pull_radius, array![block(20, 1, 0)]).validate();
    }
    // A static body may lie outside the bounds; a polygon needs at least three vertices.
    let far = BodyDef {
        kind: KIND_STATIC,
        shape: ShapeDef::HalfSpace(vec(0, 1)),
        pose: upright(500, -500),
        material: 0,
    };
    let triangle = BodyDef {
        kind: KIND_STATIC,
        shape: ShapeDef::Polygon(array![vec(0, 0), vec(1, 0), vec(0, 1)]),
        pose: upright(0, 0),
        material: 0,
    };
    minimal_level(1, 1, 1, array![far, triangle]).validate();
    // Bounds and sling anchor are closed boxes: a body exactly on the border is inside.
    minimal_level(1, 1, 1, array![block(50, 40, 0), block(-10, -10, 0)]).validate();
}

#[test]
#[should_panic(expected: ('level: version',))]
fn test_validate_version() {
    let mut level = valid();
    level.version = LEVEL_VERSION + 1;
    level.validate();
}

#[test]
#[should_panic(expected: ('level: shots',))]
fn test_validate_shots_zero() {
    minimal_level(0, 360, 1024, array![]).validate();
}

#[test]
#[should_panic(expected: ('level: shots',))]
fn test_validate_shots_above_max() {
    minimal_level(SHOTS_MAX + 1, 360, 1024, array![]).validate();
}

#[test]
#[should_panic(expected: ('level: shots',))]
fn test_validate_projectiles_one_per_shot() {
    let mut level = valid();
    level.projectiles = array![0, 0];
    level.validate();
}

#[test]
#[should_panic(expected: ('level: tick cap',))]
fn test_validate_tick_cap_zero() {
    minimal_level(3, 0, 1024, array![]).validate();
}

#[test]
#[should_panic(expected: ('level: tick cap',))]
fn test_validate_tick_cap_above_max() {
    minimal_level(3, TICK_CAP_MAX + 1, 1024, array![]).validate();
}

#[test]
#[should_panic(expected: ('level: pull radius',))]
fn test_validate_pull_radius_zero() {
    minimal_level(3, 360, 0, array![]).validate();
}

#[test]
#[should_panic(expected: ('level: pull radius',))]
fn test_validate_pull_radius_above_pull_max() {
    minimal_level(3, 360, PULL_RADIUS_MAX + 1, array![]).validate();
}

#[test]
#[should_panic(expected: ('level: material',))]
fn test_validate_material_index() {
    minimal_level(3, 360, 1024, array![block(20, 1, 0), block(22, 1, 1)]).validate();
}

#[test]
#[should_panic(expected: ('level: body kind',))]
fn test_validate_body_kind() {
    let body = BodyDef {
        kind: KIND_CORE + 1, shape: ShapeDef::Ball(fx(1)), pose: upright(20, 1), material: 0,
    };
    minimal_level(3, 360, 1024, array![body]).validate();
}

#[test]
#[should_panic(expected: ('level: shape',))]
fn test_validate_polygon_needs_three_vertices() {
    let body = BodyDef {
        kind: KIND_BLOCK,
        shape: ShapeDef::Polygon(array![vec(0, 0), vec(1, 0)]),
        pose: upright(20, 1),
        material: 0,
    };
    minimal_level(3, 360, 1024, array![body]).validate();
}

#[test]
#[should_panic(expected: ('level: bounds',))]
fn test_validate_bounds_empty_x() {
    let mut level = valid();
    level.bounds = (fx(50), fx(-10), fx(50), fx(40));
    level.validate();
}

#[test]
#[should_panic(expected: ('level: bounds',))]
fn test_validate_bounds_inverted_y() {
    let mut level = valid();
    level.bounds = (fx(-10), fx(40), fx(50), fx(-10));
    level.validate();
}

#[test]
#[should_panic(expected: ('level: bounds',))]
fn test_validate_anchor_outside_bounds() {
    let mut level = valid();
    level.sling_anchor = Vec2 { x: fx(3), y: Fixed { raw: fx(50).raw + 1 } };
    level.validate();
}

#[test]
#[should_panic(expected: ('level: bounds',))]
fn test_validate_block_outside_bounds() {
    minimal_level(3, 360, 1024, array![block(20, 1, 0), block(-11, 1, 0)]).validate();
}

#[test]
#[should_panic(expected: ('level: bounds',))]
fn test_validate_block_one_ulp_outside_bounds() {
    let mut body = block(50, 40, 0);
    body.pose.translation.x = Fixed { raw: fx(50).raw + 1 };
    minimal_level(3, 360, 1024, array![body]).validate();
}

// ---------------------------------------------------------------------------------------------
// Step probes (`scripts/steps.py`); inputs go through `opaque`
// ---------------------------------------------------------------------------------------------

/// Cost of building `pile10` from its felts: subtract from the probes below that include it.
#[test]
fn steps_level_load__pile10() {
    opaque(pile10());
}

/// `level_hash` of `pile10`, including its construction (budget: 120k steps).
#[test]
fn steps_level_hash__pile10() {
    let level = opaque(pile10());
    opaque(level.hash());
}

/// `LevelTrait::validate` of `pile10`, including its construction.
#[test]
fn steps_level_validate__pile10() {
    let level = opaque(pile10());
    level.validate();
}
