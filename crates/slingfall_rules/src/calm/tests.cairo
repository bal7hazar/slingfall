use rapier2d::prelude::{Fixed, Handle, Pose2, RigidBody, RigidBodyTrait, Rot2, Vec2, WorldTrait};
use slingfall_level::inputs::Shot;
use slingfall_level::level::Level;
use slingfall_testing::opaque;
use crate::world::fixtures::{one_block, pile10};
use crate::world::{Game, GameTrait};
use super::{CALM_TICKS, CalmTrait, EPS_V_SQ, EPS_W_SQ, is_calm};

fn fixed(raw: i64) -> Fixed {
    Fixed { raw }
}

fn moving(vx: i64, vy: i64, w: i64) -> RigidBody {
    let pose = Pose2 {
        translation: Vec2 { x: fixed(0), y: fixed(0) },
        rotation: Rot2 { re: fixed(0x100000000), im: fixed(0) },
    };
    let mut body = RigidBodyTrait::dynamic(pose);
    body.set_linvel(Vec2 { x: fixed(vx), y: fixed(vy) });
    body.set_angvel(fixed(w));
    body
}

/// Hand-computed squared compares (raw, `floor(a · b / 2^32)`): ε² floors to 10737418.
#[test]
fn test_is_calm_boundaries() {
    assert_eq!(EPS_V_SQ.raw, 10737418);
    assert_eq!(EPS_W_SQ.raw, 10737418);
    let cases: Array<(i64, i64, i64, bool)> = array![
        (0, 0, 0, true), //
        (171798692, 0, 0, true), // 0.04 m/s: 6871947 < ε²
        (-171798692, 0, 0, true), // sign does not matter
        (150323855, 150323855, 0, true), // 0.035 each: |v|² = 10522669 < ε²
        (152041842, 152041842, 0, false), // 0.0354 each: |v|² = 10764562 >= ε²
        (214748364, 0, 0, false), // just below ε: the floored square equals ε²
        (214748365, 0, 0, false), // ε
        (0, -214748365, 0, false), //
        (0, 0, 210453398, true), // ω = 0.049: ω² = 10312216 < ε²
        (0, 0, -214748365, false), // ω = -ε
        (0x7fffffffffffffff, 0, 0, false), // huge: rejected before any square
        (0, 0, -0x8000000000000000, false),
    ];
    for (vx, vy, w, expected) in cases {
        assert_eq!(is_calm(@moving(opaque(vx), vy, w)), expected);
    }
}

/// Wakes the body of entity `index` with a given velocity (written back to the world).
fn set_velocity(ref game: Game, index: usize, vx: i64) {
    let handle = *game.entities[index].body;
    let mut body = game.world.body(handle).unwrap();
    body.wake_up(true);
    body.set_linvel(Vec2 { x: fixed(vx), y: fixed(0) });
    let _ = game.world.set_body(handle, body);
}

/// Moves the body of `handle` to `(x, y)`.
fn move_to(ref game: Game, handle: Handle, x: i64, y: i64) {
    let mut body = game.world.body(handle).unwrap();
    body.set_translation(Vec2 { x: fixed(x), y: fixed(y) }, true);
    let _ = game.world.set_body(handle, body);
}

/// D5 (1): a world with every dynamic body asleep is over at once.
#[test]
fn test_update_all_asleep_is_over() {
    let level = one_block();
    let mut game = GameTrait::new(@level);
    let mut calm = CalmTrait::new();
    let report = calm.update(ref game, @level);
    assert!(report.shot_over);
    assert_eq!(report.out_of_bounds, array![]);
    assert_eq!(calm.ticks, 0);
}

/// D5 (2): awake but calm for `CALM_TICKS` consecutive updates, then everything sleeps; motion
/// restarts the count.
#[test]
fn test_update_counts_calm_ticks_then_sleeps_all() {
    let level = one_block();
    let mut game = GameTrait::new(@level);
    let mut calm = CalmTrait::new();
    // 0.04 m/s: awake and calm.
    set_velocity(ref game, 1, 171798692);
    let mut n: u8 = 1;
    while n != CALM_TICKS {
        assert!(!calm.update(ref game, @level).shot_over);
        assert_eq!(calm.ticks, n);
        n += 1;
    }
    // Motion (0.05 m/s) resets the count.
    set_velocity(ref game, 1, 214748365);
    assert!(!calm.update(ref game, @level).shot_over);
    assert_eq!(calm.ticks, 0);
    set_velocity(ref game, 1, 171798692);
    let mut n: u8 = 1;
    while n != CALM_TICKS {
        assert!(!calm.update(ref game, @level).shot_over);
        n += 1;
    }
    assert!(calm.update(ref game, @level).shot_over);
    assert_eq!(calm.ticks, 0);
    let block = game.world.body(*game.entities[1].body).unwrap();
    assert!(block.is_sleeping());
    assert_eq!(block.linvel(), Vec2 { x: fixed(0), y: fixed(0) });
}

/// Out-of-bounds: a core leaving the bounds is removed and counts as destroyed; the pebble is
/// removed too (not an entity). A body exactly on the boundary is inside.
#[test]
fn test_update_removes_out_of_bounds() {
    let level = one_block();
    let mut game = GameTrait::new(@level);
    let (_, _, max_x, _) = level.bounds;
    // On the boundary (x = max_x): inside.
    move_to(ref game, *game.entities[1].body, max_x.raw, 0x80000000);
    let mut calm = CalmTrait::new();
    assert_eq!(calm.update(ref game, @level).out_of_bounds, array![]);
    assert!(*game.entities[1].alive);
    // The core one raw unit beyond: removed, scored, the level is won.
    move_to(ref game, *game.entities[2].body, max_x.raw + 1, 0x80000000);
    let report = calm.update(ref game, @level);
    assert_eq!(report.out_of_bounds, array![2]);
    assert!(!*game.entities[2].alive);
    assert!(game.world.body(*game.entities[2].body).is_none());
    assert_eq!(game.cores_left, 0);
    assert_eq!(game.score, 1_000);
    // The pebble below min_y.
    launch(ref game, @level);
    let pebble = game.pebble.unwrap();
    move_to(ref game, pebble, 0, -0xa00000001);
    let report = calm.update(ref game, @level);
    assert_eq!(report.out_of_bounds, array![]);
    assert!(game.pebble.is_none());
    assert!(game.world.body(pebble).is_none());
    assert_eq!(game.score, 1_000);
}

fn launch(ref game: Game, level: @Level) {
    crate::sling::launch(
        ref game, level, @Shot { pull_x: -600, pull_y: -392, delay: 0, ability_tick: 0 },
    );
}

/// The pebble in flight keeps the shot going: not asleep, not calm.
#[test]
fn test_update_pebble_in_flight_is_not_over() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    launch(ref game, @level);
    let mut calm = CalmTrait::new();
    assert!(!calm.update(ref game, @level).shot_over);
    assert_eq!(calm.ticks, 0);
}

fn setup() -> (Game, Level) {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    launch(ref game, @level);
    let _ = game.tick(@level);
    (game, opaque(level))
}

/// Setup of `steps_calm__update`: subtract it.
#[test]
fn steps_calm__setup() {
    let (_, _) = setup();
}

/// One update on pile10 with the pebble in flight: 10 sleeping bodies, one awake.
#[test]
fn steps_calm__update() {
    let (mut game, level) = setup();
    let mut calm = CalmTrait::new();
    opaque(calm.update(ref game, @level));
}
