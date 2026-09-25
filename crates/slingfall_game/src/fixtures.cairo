//! The reference shot of pile10 and its golden outputs, shared by the tests of this crate, of
//! `slingfall_replay` and of the contract. The fixture levels themselves are
//! `slingfall_level::level::fixtures`.

use slingfall_level::inputs::{Inputs, Shot};
use slingfall_level::level::fixtures::PILE10_HASH;

/// The player of the fixtures (`'player'`, as the contract's tests).
pub const PLAYER: felt252 = 'player';
/// `inputs_hash` of [`reference_inputs`].
pub const REFERENCE_INPUTS_HASH: felt252 =
    0x31b10e77b97a88153b1e9d781ecddece54061fe1cf88e6a3660eee99fda4f3b;
/// `final_state_hash` of the reference shot.
pub const REFERENCE_FINAL_STATE_HASH: felt252 =
    0x2ff3945fee21a4cc7f9447a645a65108dd2a7e697f0c06e75ef0475bbef13e9;

pub fn shot(pull_x: i16, pull_y: i16, delay: u16) -> Shot {
    Shot { pull_x, pull_y, delay, ability_tick: 0 }
}

/// The reference shot of pile10 (`docs/PLAN.md`): pull (-600, -392), no delay.
pub fn reference_inputs() -> Inputs {
    Inputs { player: PLAYER, shots: array![shot(-600, -392, 0)] }
}

/// Golden D4 felts of the reference shot, from `scarb execute --executable-name main` (README):
/// won in one shot, 6 bodies destroyed at tick 83 (1 350) plus 2 unused shots (4 000), calm end
/// at tick 191 (the spent-pebble rule of D5, G3b).
pub fn reference_outputs() -> Array<felt252> {
    array![
        1, PILE10_HASH, 0, PLAYER, REFERENCE_INPUTS_HASH, 5350, 1, 1, 191,
        REFERENCE_FINAL_STATE_HASH,
    ]
}
