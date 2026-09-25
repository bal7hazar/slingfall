use rapier2d::prelude::{
    ContactForceEvent, Fixed, Handle, RigidBodySetTrait, RigidBodyTrait, WorldTrait,
};
use slingfall_testing::opaque;
use crate::world::fixtures::pile10;
use crate::world::{Game, GameTrait};
use super::{apply, damage_of, entity_of, remove};

/// Materials of the fixtures: 0 timber, 1 slate, 2 frost, 3 core.
const TIMBER: usize = 0;
const SLATE: usize = 1;
const FROST: usize = 2;
const CORE: usize = 3;

/// Handle of slot `index`, generation 0 (every fixture entity).
fn slot(index: u32) -> Handle {
    Handle { index, generation: 0 }
}

/// A force event between two colliders with `total_force_magnitude = force` (raw).
fn event(collider1: u32, collider2: u32, force: i64) -> ContactForceEvent {
    ContactForceEvent {
        collider1: slot(collider1),
        collider2: slot(collider2),
        total_force_magnitude: Fixed { raw: force },
        ..Default::default(),
    }
}

/// D6 goldens, computed by hand (Python integers, `tools`-free): `excess = force - threshold`
/// (raw), `floor(excess · dpi / 2^32)`, then `>> 32`. `[material, force raw, damage]`.
#[test]
fn test_damage_of_goldens() {
    let level = pile10();
    let materials = level.materials.span();
    let cases: Array<(usize, i64, u32)> = array![
        (TIMBER, 193273528320, 5), // 45 N: excess 5 N
        (TIMBER, 171798691840, 0), // 40 N: at the threshold, no damage (strict)
        (TIMBER, 173946175488, 0), // 40.5 N: floor(0.5) = 0
        (TIMBER, 604516646912, 100), // 140.75 N: floor(100.75)
        (TIMBER, 42949672960, 0), // 10 N: below the threshold
        (SLATE, 644245094400, 9), // 150 N: 30 · 0.3333333333 = 9.99…, floored
        (SLATE, 1803886264320, 99), // 420 N: 300 · 0.3333333333 = 99.99…
        (SLATE, 257698037760, 0), // 60 N: below
        (FROST, 65498251264, 0), // 15.25 N: 0.25 · 2 = 0.5, floored
        (FROST, 85899345920, 10), // 20 N: 5 · 2
        (FROST, 257698037760, 90), // 60 N: 45 · 2
        (CORE, 257698037760, 50), // 60 N: 50 · 1
        (CORE, 4294967296000, 990) // 1000 N
    ];
    for (material, force, expected) in cases {
        assert_eq!(damage_of(Fixed { raw: force }, materials[material]), expected);
    }
}

/// Pile10 slots: 0 ground, 1-4 timber, 5-7 slate, 8-9 frost, 10 core; 11 is not an entity.
#[test]
fn test_apply_three_events() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    let events = array![
        // Ground (static, no damage) and timber 2: 45 N, 5 hp.
        event(
            0, 2, 193273528320,
        ), // Frost 8 and the core: 60 N, 90 hp (40 -> 0) and 50 hp (30 -> 0).
        event(
            8, 10, 257698037760,
        ), // Slate 5 and a non-entity (the pebble's slot): 150 N, 9 hp to the slate only.
        event(5, 11, 644245094400),
    ];
    let destroyed = apply(ref game, @level, events.span());
    assert_eq!(destroyed, array![8, 10]);
    let hp: Array<u32> = array![300, 100, 95, 100, 100, 291, 300, 300, 0, 40, 0];
    let mut i = 0;
    for entity in game.entities.span() {
        assert_eq!(*entity.hp, *hp[i]);
        // `apply` only damages; the removal is `remove`'s.
        assert!(*entity.alive);
        i += 1;
    }
}

/// Several events on one entity add up and saturate at 0; the ground and dead entities take no
/// damage; an entity already at 0 is not destroyed twice.
#[test]
fn test_apply_sums_saturates_and_skips() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    // Timber 1: 60 N twice (20 + 20), then 140.75 N against slate 5 (100): saturates.
    let events = array![
        event(1, 0, 257698037760), event(0, 1, 257698037760), event(1, 5, 604516646912),
    ];
    assert_eq!(apply(ref game, @level, events.span()), array![1]);
    assert_eq!(*game.entities[1].hp, 0);
    assert_eq!(*game.entities[0].hp, *level.materials[1].hp);
    // Slate 5 is the other side of the third event: 20.75 N over 120 N · 0.3333333333 = 6.
    assert_eq!(*game.entities[5].hp, 294);
    // Below every threshold: nothing.
    assert_eq!(apply(ref game, @level, array![event(2, 3, 4294967296)].span()), array![]);
    assert_eq!(apply(ref game, @level, array![].span()), array![]);
    // A dead entity is skipped.
    remove(ref game, @level, array![1].span());
    assert_eq!(apply(ref game, @level, array![event(1, 0, 604516646912)].span()), array![]);
}

#[test]
fn test_entity_of() {
    let level = pile10();
    let game = GameTrait::new(@level);
    let entities = game.entities.span();
    assert_eq!(entity_of(entities, slot(0)), Some(0));
    assert_eq!(entity_of(entities, slot(10)), Some(10));
    assert_eq!(entity_of(entities, slot(11)), None);
    // A reused slot has a new generation: not the entity.
    assert_eq!(entity_of(entities, Handle { index: 3, generation: 1 }), None);
}

/// `remove` removes in the given (ascending) order, scores, counts the cores down.
#[test]
fn test_remove_scores_and_counts_cores() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    remove(ref game, @level, array![8, 10].span());
    assert_eq!(game.score, 1_100);
    assert_eq!(game.cores_left, 0);
    assert!(crate::score::won(@game));
    assert!(!*game.entities[8].alive && !*game.entities[10].alive && *game.entities[9].alive);
    assert!(game.world.body(slot(8)).is_none());
    assert!(game.world.body(slot(10)).is_none());
    assert!(game.world.collider(slot(8)).is_none());
    assert_eq!(game.world.bodies.len(), 9);
}

/// `World::remove_body` wakes the bodies in contact with the removed colliders itself (no
/// `wake_contact_partners` call needed): removing timber 1 wakes timber 2 (side by side) and
/// slate 5 (on top), not timber 4 (two blocks away).
#[test]
fn test_remove_body_wakes_contact_partners() {
    let level = pile10();
    let mut game = GameTrait::new(@level);
    for entity in game.entities.span() {
        if *entity.kind != 0 {
            assert!(game.world.body(*entity.body).unwrap().is_sleeping());
        }
    }
    remove(ref game, @level, array![1].span());
    assert!(!game.world.body(slot(2)).unwrap().is_sleeping());
    assert!(!game.world.body(slot(5)).unwrap().is_sleeping());
    assert!(game.world.body(slot(4)).unwrap().is_sleeping());
    assert!(game.world.body(slot(10)).unwrap().is_sleeping());
}

fn three_events() -> Array<ContactForceEvent> {
    array![event(0, 2, 193273528320), event(8, 10, 257698037760), event(5, 11, 644245094400)]
}

fn setup() -> (Game, slingfall_level::level::Level, Array<ContactForceEvent>) {
    let level = pile10();
    let game = GameTrait::new(@level);
    (game, level, opaque(three_events()))
}

/// Setup of `steps_damage__3_events`: subtract it.
#[test]
fn steps_damage__setup() {
    let (_, _, _) = setup();
}

#[test]
fn steps_damage__3_events() {
    let (mut game, level, events) = setup();
    let destroyed = apply(ref game, @level, events.span());
    opaque(destroyed);
}
