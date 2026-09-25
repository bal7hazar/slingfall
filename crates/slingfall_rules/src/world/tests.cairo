use core::poseidon::poseidon_hash_span;
use rapier2d::prelude::{
    CONTACT_FORCE_EVENTS, ColliderTrait, Fixed, IntegrationParameters, Pose2, RigidBodySetTrait,
    RigidBodyTrait, Rot2, Vec2, WorldTrait,
};
use slingfall_level::inputs::Shot;
use slingfall_level::level::{BodyDef, KIND_CORE, KIND_STATIC, Level, LevelTrait, ShapeDef};
use slingfall_testing::opaque;
use crate::world::fixtures::{CORES3_HASH, ONE_BLOCK_HASH, PILE10_HASH, cores3, one_block, pile10};
use crate::world::{Game, GameState, GameTrait};

/// The reference shot at pile10: first contact at shot tick 83, ends calm (see REPORT.md).
const SHOT: Shot = Shot { pull_x: -600, pull_y: -392, delay: 0, ability_tick: 0 };
/// Shot tick of the first contact of `SHOT` with pile10 (measured).
const FIRST_CONTACT: u32 = 83;

fn fixed(raw: i64) -> Fixed {
    Fixed { raw }
}

/// Every body of every fixture: kind, material, hit points, handles of slot `i`, body type, pose,
/// sleeping state, collider material, threshold, `user_data`, events.
#[test]
fn test_builder_maps_every_fixture_body() {
    let levels: Array<(Level, felt252, u8)> = array![
        (pile10(), PILE10_HASH, 1), (cores3(), CORES3_HASH, 3), (one_block(), ONE_BLOCK_HASH, 1),
    ];
    for (level, hash, cores) in levels {
        level.validate();
        let mut game = GameTrait::new(@level);
        assert_eq!(game.level_hash, hash);
        assert_eq!(game.cores_left, cores);
        assert_eq!((game.score, game.shots_used, game.tick, game.shot_tick), (0, 0, 0, 0));
        assert!(game.pebble.is_none());
        let params: IntegrationParameters = Default::default();
        assert_eq!(game.world.integration_parameters, params);
        assert_eq!(game.world.integration_parameters.dt.raw, 71582788);
        assert_eq!(game.world.integration_parameters.num_solver_iterations, 4);
        assert_eq!(game.world.gravity, Vec2 { x: fixed(0), y: level.gravity_y });
        assert_eq!(game.entities.len(), level.bodies.len());
        assert_eq!(game.world.bodies.len(), level.bodies.len());
        let mut i: u32 = 0;
        for def in level.bodies.span() {
            let entity = *game.entities[i];
            let material = *level.materials[(*def.material).into()];
            assert_eq!((entity.kind, entity.material), (*def.kind, *def.material));
            assert_eq!((entity.hp, entity.alive), (material.hp, true));
            assert_eq!((entity.body.index, entity.collider.index), (i, i));
            let body = game.world.body(entity.body).unwrap();
            let collider = game.world.collider(entity.collider).unwrap();
            assert_eq!(body.position(), *def.pose);
            assert_eq!(collider.position(), *def.pose);
            assert_eq!(collider.parent(), Some(entity.body));
            assert_eq!(collider.user_data, i.into());
            assert_eq!(collider.density(), material.density);
            assert_eq!(collider.friction(), material.friction);
            assert_eq!(collider.restitution(), material.restitution);
            assert_eq!(collider.contact_force_event_threshold(), material.force_threshold);
            if *def.kind == KIND_STATIC {
                assert!(body.is_fixed());
                assert_eq!(collider.active_events().bits, 0);
            } else {
                assert!(body.is_dynamic());
                assert!(body.is_sleeping());
                assert!(!body.is_moving());
                assert_eq!(collider.active_events(), CONTACT_FORCE_EVENTS);
            }
            i += 1;
        }
    }
}

/// D4 at tick 0: the hash of the stored poses of the dynamic bodies, level order.
#[test]
fn test_final_state_hash_at_t0_is_the_stored_poses() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    let mut felts: Array<felt252> = array![];
    for def in level.bodies.span() {
        if *def.kind != KIND_STATIC {
            def.pose.serialize(ref felts);
        }
    }
    assert_eq!(felts.len(), 40);
    assert_eq!(game.final_state_hash(), poseidon_hash_span(felts.span()));
}

/// D6 invariant on the level as built: pile10 at rest (asleep) for 120 ticks takes no damage,
/// never moves, and every tick is a D5 (1) end of shot.
#[test]
fn test_resting_pile10_takes_no_damage_over_120_ticks() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    let start = game.final_state_hash();
    let mut t = 0;
    while t != 120 {
        let report = game.tick(@level);
        assert_eq!(report.destroyed, array![]);
        assert!(report.shot_over && !report.capped && !report.won);
        t += 1;
    }
    assert_eq!(game.tick, 120);
    let mut i: u32 = 0;
    for entity in game.entities.span() {
        assert_eq!(*entity.hp, *level.materials[(*entity.material).into()].hp);
        if *entity.kind != KIND_STATIC {
            assert!(game.world.body(*entity.body).unwrap().is_sleeping());
        }
        i += 1;
    }
    assert_eq!(game.final_state_hash(), start);
}

/// The same pile woken up at rest: the static load alone exceeds timber's 40 N threshold under
/// the two inner bottom blocks (entities 2 and 3, about 41-43 N each), which lose hp until the
/// calm rule puts the pile back to sleep (tick 20): hp 100 -> 81 and 82. Measured, not tuned
/// (level design, lot G8). 22M steps: over the default snforge cap (see
/// `test_pile10_shot_ends_calm_before_the_cap`).
#[test]
#[ignore]
fn test_awake_pile10_load_damage_is_the_inner_bottom_timber() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    for entity in game.entities.span() {
        if *entity.kind != KIND_STATIC {
            let mut body = game.world.body(*entity.body).unwrap();
            body.wake_up(true);
            let _ = game.world.set_body(*entity.body, body);
        }
    }
    let mut t = 0;
    let mut over_at = 0;
    while t != 120 {
        let report = game.tick(@level);
        assert_eq!(report.destroyed, array![]);
        t += 1;
        if report.shot_over && over_at == 0 {
            over_at = t;
        }
    }
    let mut damaged: Array<(usize, u32)> = array![];
    let mut i = 0;
    for entity in game.entities.span() {
        if *entity.hp != *level.materials[(*entity.material).into()].hp {
            damaged.append((i, *entity.hp));
        }
        i += 1;
    }
    assert_eq!(over_at, 20);
    assert_eq!(damaged, array![(2, 81), (3, 82)]);
}

/// The reference shot destroys a block well within the cap (CI-sized: stops at the first
/// destruction).
#[test]
fn test_pile10_shot_destroys_a_block_within_the_cap() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    crate::sling::launch(ref game, @level, @SHOT);
    let mut destroyed = array![];
    while destroyed.is_empty() {
        let report = game.tick(@level);
        assert!(!report.shot_over);
        destroyed = report.destroyed;
    }
    // The first contact tick itself: frost, the core and three timber blocks at once.
    assert_eq!(game.shot_tick, FIRST_CONTACT);
    assert_eq!(destroyed, array![1, 2, 3, 8, 9, 10]);
}

/// The whole reference shot (43M steps: over the default snforge cap, run with
/// `snforge test -p slingfall_rules --include-ignored --max-n-steps 200000000`): the calm rule
/// ends it at shot tick 334, before the 360 cap; the level is won.
#[test]
#[ignore]
fn test_pile10_shot_ends_calm_before_the_cap() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    let report = game.play_shot(@level, @SHOT);
    println!("pile10 shot: {:?}, score {}", report, game.score);
    assert!(!report.capped);
    assert_eq!(report.shot_ticks, 334);
    assert_eq!(report.ticks, 334);
    assert_eq!(report.destroyed, array![1, 2, 3, 8, 9, 10]);
    assert!(report.won);
    // Frost 2 × 100, timber 3 × 50, the core 1 000, two unused shots × 2 000.
    assert_eq!(game.score, 5_350);
    assert_eq!(game.shots_used, 1);
    assert!(game.pebble.is_none());
    for entity in game.entities.span() {
        if *entity.alive && *entity.kind != KIND_STATIC {
            assert!(game.world.body(*entity.body).unwrap().is_sleeping());
        }
    }
}

/// Saves `game` through its felts (`Serde` of `GameState`) and restores it.
fn through_felts(ref game: Game) -> Game {
    let mut felts: Array<felt252> = array![];
    game.to_state().serialize(ref felts);
    let mut span = felts.span();
    let state: GameState = Serde::deserialize(ref span).unwrap();
    assert!(span.is_empty());
    GameTrait::from_state(state)
}

/// Steps `game` and its restored copy `ticks` more ticks; both must stay bit-exact.
fn assert_round_trip(ref game: Game, level: @Level, ticks: u32) {
    let mut copy = through_felts(ref game);
    assert_eq!(copy.to_state(), game.to_state());
    let mut t = 0;
    while t != ticks {
        assert_eq!(copy.tick(level), game.tick(level));
        t += 1;
    }
    assert_eq!(copy.final_state_hash(), game.final_state_hash());
    assert_eq!(copy.to_state(), game.to_state());
}

/// Round trip in flight (pebble in the air, pile asleep): 10 more ticks bit-exact.
#[test]
fn test_round_trip_mid_flight() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    crate::sling::launch(ref game, @level, @SHOT);
    let mut t = 0;
    while t != 40 {
        let _ = game.tick(@level);
        t += 1;
    }
    assert_round_trip(ref game, @level, 10);
}

/// Round trip during the impact (2 ticks after the first contact, frost already destroyed):
/// 10 more ticks bit-exact, removals and the pebble's handle included (over the default cap).
#[test]
#[ignore]
fn test_round_trip_mid_impact() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    crate::sling::launch(ref game, @level, @SHOT);
    while game.shot_tick != FIRST_CONTACT + 2 {
        let _ = game.tick(@level);
    }
    assert!(game.pebble.is_some());
    assert_round_trip(ref game, @level, 10);
}

/// A level with the pile10 materials and the given bodies (one shot, cap `tick_cap`).
fn custom_level(tick_cap: u16, launch_scale: i64, anchor_y: i64, bodies: Array<BodyDef>) -> Level {
    let base = pile10();
    Level {
        version: 1,
        level_id: 99,
        seed: 0,
        gravity_y: base.gravity_y,
        shots: 1,
        tick_cap,
        bounds: base.bounds,
        sling_anchor: Vec2 { x: fixed(0x300000000), y: fixed(anchor_y) },
        pull_radius: 1024,
        launch_scale: fixed(launch_scale),
        projectiles: array![0],
        materials: base.materials,
        bodies,
    }
}

fn ground() -> BodyDef {
    BodyDef {
        kind: KIND_STATIC,
        shape: ShapeDef::HalfSpace(Vec2 { x: fixed(0), y: fixed(0x100000000) }),
        pose: at(0, 0),
        material: 1,
    }
}

fn at(x: i64, y: i64) -> Pose2 {
    Pose2 {
        translation: Vec2 { x: fixed(x), y: fixed(y) },
        rotation: Rot2 { re: fixed(0x100000000), im: fixed(0) },
    }
}

/// Tunnelling at `v_max = 25 m/s` (pull 1000 × 0.025): the pebble (r 0.25) flies 3 m into a
/// static plank 0.5 m thick (x in [5.75, 6.25], 2 m tall) and must bounce back, not come out
/// behind it. 0.42 m per tick against a 1 m overlap window: no tunnelling (see REPORT.md).
#[test]
fn test_pebble_at_25_mps_does_not_tunnel_through_a_half_metre_plank() {
    let plank = BodyDef {
        kind: KIND_STATIC,
        shape: ShapeDef::Cuboid((fixed(0x40000000), fixed(0x100000000))),
        pose: at(0x600000000, 0x100000000),
        material: 1,
    };
    // Anchor (3, 1), launch scale 0.025 (raw rounded to nearest).
    let level = custom_level(60, 107374182, 0x100000000, array![ground(), plank]);
    let mut game = GameTrait::new(@level);
    crate::sling::launch(
        ref game, @level, @Shot { pull_x: -1000, pull_y: 0, delay: 0, ability_tick: 0 },
    );
    let pebble = game.pebble.unwrap();
    let v0 = game.world.body(pebble).unwrap().linvel().x;
    assert_eq!(v0.raw, 107374182000);
    let mut max_x = fixed(0);
    let mut t = 0;
    while t != 60 {
        let _ = game.tick(@level);
        let x = game.world.body(pebble).unwrap().translation().x;
        if x > max_x {
            max_x = x;
        }
        t += 1;
    }
    let body = game.world.body(pebble).unwrap();
    println!(
        "tunnelling: max x {} (raw), final x {}, final vx {}",
        max_x.raw,
        body.translation().x.raw,
        body.linvel().x.raw,
    );
    // The pebble never passes the plank's front face by more than its radius.
    assert!(max_x.raw < 0x600000000 - 0x40000000);
    assert!(body.translation().x.raw < 0x600000000);
    assert!(body.linvel().x.raw <= 0);
}

/// `delay` ticks are stepped without a pebble, count in `ticks` and `Game.tick`, not in the cap.
#[test]
fn test_play_shot_delay_and_cap() {
    // A core far away (x = 40), out of the pebble's reach in 30 ticks.
    let core = BodyDef {
        kind: KIND_CORE,
        shape: ShapeDef::Ball(fixed(1717986918)),
        pose: at(0x2800000000, 1717986918),
        material: 3,
    };
    let level = custom_level(30, 85899346, 0x280000000, array![ground(), core]);
    let mut game = GameTrait::new(@level);
    let report = game
        .play_shot(@level, @Shot { pull_x: -500, pull_y: 0, delay: 5, ability_tick: 0 });
    // A lone pebble rolls on flat ground: never calm, the cap ends the shot.
    assert_eq!((report.ticks, report.shot_ticks, report.capped), (35, 30, true));
    assert_eq!(report.destroyed, array![]);
    assert_eq!(game.tick, 35);
    assert_eq!(game.shots_used, 1);
    assert!(game.pebble.is_none());
    assert_eq!(game.world.bodies.len(), 2);
    assert!(!report.won);
    assert_eq!(game.score, 0);
}

#[test]
#[should_panic(expected: ('rules: level over',))]
fn test_play_shot_after_the_last_shot_panics() {
    let level = one_block();
    let mut game = GameTrait::new(@level);
    game.shots_used = 1;
    let _ = game.play_shot(@level, @SHOT);
}

#[test]
#[should_panic(expected: ('rules: level over',))]
fn test_play_shot_after_a_win_panics() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    game.cores_left = 0;
    let _ = game.play_shot(@level, @SHOT);
}

#[test]
#[should_panic(expected: ('rules: pebble in flight',))]
fn test_second_launch_panics() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    crate::sling::launch(ref game, @level, @SHOT);
    crate::sling::launch(ref game, @level, @SHOT);
}

#[test]
#[should_panic(expected: ('rules: polygon',))]
fn test_concave_polygon_panics() {
    // Clockwise triangle: rapier's `convex_polygon` rejects it.
    let polygon = BodyDef {
        kind: KIND_STATIC,
        shape: ShapeDef::Polygon(
            array![
                Vec2 { x: fixed(0), y: fixed(0) }, Vec2 { x: fixed(0), y: fixed(0x100000000) },
                Vec2 { x: fixed(0x100000000), y: fixed(0) },
            ],
        ),
        pose: at(0x500000000, 0),
        material: 1,
    };
    let level = custom_level(30, 85899346, 0x280000000, array![ground(), polygon]);
    let _ = GameTrait::new(@level);
}

/// The core count follows `KIND_CORE`.
#[test]
fn test_cores_counted() {
    let level = cores3();
    let game = GameTrait::new(@level);
    let mut cores = 0;
    for entity in game.entities.span() {
        if *entity.kind == KIND_CORE {
            cores += 1;
        }
    }
    assert_eq!(cores, 3);
}

// Step probes. `steps_<op>__<state>` minus `steps_setup__<state>` is the op; the rules' own
// overhead per tick is `steps_tick__<state>` minus `steps_step__<state>` (same setup).

#[test]
fn steps_game_new__pile10() {
    let level = opaque(pile10());
    let _ = opaque(GameTrait::new(@level).score);
}

#[test]
fn steps_final_state_hash__pile10() {
    let level = opaque(pile10());
    let mut game = GameTrait::new(@level);
    opaque(game.final_state_hash());
}

/// pile10 asleep, the pebble launched 10 ticks ago (in the air).
fn flight() -> (Game, Level) {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    crate::sling::launch(ref game, @level, @SHOT);
    let mut t = 0;
    while t != 10 {
        let _ = game.tick(@level);
        t += 1;
    }
    (game, opaque(level))
}

/// pile10 one tick before the first contact of `SHOT`.
fn impact() -> (Game, Level) {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    crate::sling::launch(ref game, @level, @SHOT);
    while game.shot_tick != FIRST_CONTACT - 1 {
        let _ = game.tick(@level);
    }
    (game, opaque(level))
}

#[test]
fn steps_setup__pile10_flight() {
    let (_, _) = flight();
}

#[test]
fn steps_tick__pile10_flight() {
    let (mut game, level) = flight();
    opaque(game.tick(@level));
}

#[test]
fn steps_step__pile10_flight() {
    let (mut game, _) = flight();
    opaque(game.world.step_with_force_events());
}

#[test]
fn steps_setup__pile10_impact() {
    let (_, _) = impact();
}

#[test]
fn steps_tick__pile10_impact() {
    let (mut game, level) = impact();
    opaque(game.tick(@level));
}

#[test]
fn steps_step__pile10_impact() {
    let (mut game, _) = impact();
    opaque(game.world.step_with_force_events());
}
