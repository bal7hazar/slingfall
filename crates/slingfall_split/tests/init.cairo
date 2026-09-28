//! `init` on declared classes against main's `GameTrait::new`: the world built from the level, the
//! settle step with `SlimSplitStages`, the sleeps.

use rapier2d::prelude::WorldTrait;
use rapier2d::world::basic_state::into_basic_state;
use slingfall_level::level::fixtures::pile10;
use slingfall_rules::world::GameTrait;
use slingfall_split::hashes::GameClasses;
use slingfall_split::init::{build, settle, settle_sleeps};
use crate::harness::install;

pub fn first_difference(a: Span<felt252>, b: Span<felt252>) -> Option<u32> {
    let mut i = 0;
    let n = if a.len() < b.len() {
        a.len()
    } else {
        b.len()
    };
    while i != n {
        if a[i] != b[i] {
            return Some(i);
        }
        i += 1;
    }
    if a.len() != b.len() {
        Some(n)
    } else {
        None
    }
}

#[test]
fn steps_init_world_is_mains() {
    install();
    let level = pile10();
    let mut game = GameTrait::new(@level);
    let mut expected = array![];
    game.world.to_state().serialize(ref expected);
    let (world, rules) = build(@level);
    let world = settle::<GameClasses>(world);
    let mut world = world;
    slingfall_split::world::apply_ops(ref world, settle_sleeps(@rules).span());
    let mut got = array![];
    into_basic_state(world).serialize(ref got);
    if let Some(i) = first_difference(got.span(), expected.span()) {
        println!(
            "first difference at felt {i} of {} / {}: got {:x}, main {:x}",
            got.len(),
            expected.len(),
            *got.at(i),
            *expected.at(i),
        );
        let from = if i > 12 {
            i - 12
        } else {
            0
        };
        println!("got  {:?}", got.span().slice(from, 24));
        println!("main {:?}", expected.span().slice(from, 24));
        panic!("init world differs from main's");
    }
}

/// The felts of the chain's state at every fixture boundary (`world ++ rules`): the calldata of
/// a `step_chunk` transaction is these, the inputs and two felts.
#[test]
fn test_state_felts() {
    let cases: Array<(ByteArray, Array<u32>)> = array![
        ("reference", array![0, 40, 50, 60, 70, 80, 90, 100, 107]),
        ("owner", array![0, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 151]),
    ];
    for (case, ticks) in cases {
        for tick in ticks {
            let (world, rules) = crate::harness::state(@case, tick);
            println!("felts {case} {tick}: world {} rules {}", world.len(), rules.len());
        }
    }
}
