//! The reference shot of pile10 and its golden outputs, shared by the tests of this crate, of
//! `slingfall_replay` and of the contract. The fixture levels themselves are
//! `slingfall_level::level::fixtures`.

use slingfall_level::inputs::{Inputs, Shot};
use slingfall_level::level::fixtures::PILE10_HASH;

/// The player of the fixtures (`'player'`, as the contract's tests).
pub const PLAYER: felt252 = 'player';
/// `inputs_hash` of [`reference_inputs`].
pub const REFERENCE_INPUTS_HASH: felt252 =
    0x5c242b3f403a2cc4fbf7e6f51d9ceab41baeabb21691fed72ec2cdce0d51d8f;
/// `final_state_hash` of the reference shot.
pub const REFERENCE_FINAL_STATE_HASH: felt252 =
    0x135df25e65cc5905398c07fc0fb89cb47ee2360a8704793595e82dd6cfbb255;

pub fn shot(pull_x: i16, pull_y: i16, delay: u16) -> Shot {
    Shot { pull_x, pull_y, delay, ability_tick: 0 }
}

/// The reference shot of pile10 (`docs/PLAN.md`): pull (-604, -392), no delay.
pub fn reference_inputs() -> Inputs {
    Inputs { player: PLAYER, shots: array![shot(-604, -392, 0)] }
}

/// Golden D4 felts of the reference shot, from `scarb execute --executable-name main` (README):
/// won in one shot, the core and 2 frost blocks destroyed (1 200) plus 2 unused shots (4 000),
/// the shot ends at tick 107 (the spent-pebble rule of D5, G3b).
pub fn reference_outputs() -> Array<felt252> {
    array![
        1, PILE10_HASH, 0, PLAYER, REFERENCE_INPUTS_HASH, 5200, 1, 1, 107,
        REFERENCE_FINAL_STATE_HASH,
    ]
}
