//! Tick by tick against main: a layout's world class stepped one tick per chunk (`k = 1`) next to
//! main's own chunk logic (`slingfall_game::chunk::step_state`, in process, the whole engine),
//! from main's state at the window's start; after every tick the whole state must be equal, bit
//! for bit: the world (bodies, colliders, contact pairs with their force-event statuses) and the
//! rules state (every entity's `hp` and `alive`, which the tick's force events decide through the
//! damage rule, the score, the calm counter, the pebble). Heavy (`#[ignore]`): run with
//! `snforge test ticks_ --include-ignored`, one window at a time.

use slingfall_game::chunk::{ChunkState, step_state};
use slingfall_game::play::{NoopObserver, decode};
use slingfall_level::inputs::Inputs;
use crate::harness::{chunk, deploy, install, load, raw, split_state};

pub fn ticks(layout: ByteArray, case: ByteArray, start: u32, end: u32) {
    install();
    let raw = raw(@layout);
    let address = deploy(layout);
    let felts = load(@case, format!("state_{start}"));
    let mut state: ChunkState = decode(felts.span(), 'fixture: state');
    let (mut world, mut rules) = split_state(felts.span());
    let inputs_felts = load(@case, "inputs");
    let inputs: Inputs = decode(inputs_felts.span(), 'fixture: inputs');
    let mut tick = start;
    while tick != end {
        let mut obs: NoopObserver = Default::default();
        let (next, _) = step_state(state, @inputs, 0, 1, ref obs);
        let over = next.shots_used == 1;
        let mut next_felts = array![];
        next.serialize(ref next_felts);
        let (main_world, main_rules) = split_state(next_felts.span());
        let mut expected = main_world.clone();
        main_rules.span().serialize(ref expected);
        expected.append(1);
        expected.append(over.into());
        let out = chunk(address, raw, world.span(), rules.span(), inputs_felts.span(), 0, 1);
        assert!(out == expected.span(), "{case}: tick {} differs from main", tick + 1);
        state = next;
        world = main_world;
        rules = main_rules;
        tick += 1;
        if over {
            break;
        }
    }
    assert!(tick == end, "{case}: the shot ended at tick {tick}, not {end}");
}

#[test]
#[ignore]
fn ticks_e_owner_000_040() {
    ticks("WorldClass", "owner", 0, 40);
}

#[test]
#[ignore]
fn ticks_e_owner_040_070() {
    ticks("WorldClass", "owner", 40, 70);
}

#[test]
#[ignore]
fn ticks_e_owner_070_100() {
    ticks("WorldClass", "owner", 70, 100);
}

#[test]
#[ignore]
fn ticks_e_owner_100_130() {
    ticks("WorldClass", "owner", 100, 130);
}

#[test]
#[ignore]
fn ticks_e_owner_130_151() {
    ticks("WorldClass", "owner", 130, 151);
}

#[test]
#[ignore]
fn ticks_e_reference_000_040() {
    ticks("WorldClass", "reference", 0, 40);
}

#[test]
#[ignore]
fn ticks_e_reference_040_080() {
    ticks("WorldClass", "reference", 40, 80);
}

#[test]
#[ignore]
fn ticks_e_reference_080_107() {
    ticks("WorldClass", "reference", 80, 107);
}

#[test]
#[ignore]
fn ticks_b_owner_000_040() {
    ticks("FallbackGame", "owner", 0, 40);
}

#[test]
#[ignore]
fn ticks_b_owner_040_070() {
    ticks("FallbackGame", "owner", 40, 70);
}

#[test]
#[ignore]
fn ticks_b_owner_070_100() {
    ticks("FallbackGame", "owner", 70, 100);
}

#[test]
#[ignore]
fn ticks_b_owner_100_130() {
    ticks("FallbackGame", "owner", 100, 130);
}

#[test]
#[ignore]
fn ticks_b_owner_130_151() {
    ticks("FallbackGame", "owner", 130, 151);
}

#[test]
#[ignore]
fn ticks_b_reference_000_040() {
    ticks("FallbackGame", "reference", 0, 40);
}

#[test]
#[ignore]
fn ticks_b_reference_040_080() {
    ticks("FallbackGame", "reference", 40, 80);
}

#[test]
#[ignore]
fn ticks_b_reference_080_107() {
    ticks("FallbackGame", "reference", 80, 107);
}
