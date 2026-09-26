//! Fixtures of the contract tests: the golden claim, key and signature of the verifier tests. The
//! fixture levels are `slingfall_level::level::fixtures`.

use slingfall_level::hash::to_felts;
use slingfall_level::inputs::{Inputs, Shot};
use slingfall_level::level::fixtures::PILE10_HASH;
use slingfall_level::outputs::Outputs;

// Golden vectors of `crates/slingfall_contract/tools/vectors.py golden`.

/// Test attestation secret key ('slingfall'): never a deployment key.
pub const SECRET: felt252 = 'slingfall';
/// Stark-curve public key of `SECRET`.
pub const ATTESTATION_KEY: felt252 =
    0x1969604bead70945f115b9ae5912e373de3a9c29bc9a7dc2f2842fe14cc6dde;
/// The player of the golden claim.
pub const PLAYER: felt252 = 'player';
/// `verifier::attestation_hash` of the golden claim's felts.
pub const GOLDEN_ATTESTATION_HASH: felt252 =
    0x3b737b679b6dadbaf81a339e82fab5d613db6a613bbd1c601785f242aa2c0e9;
/// ECDSA signature `(r, s)` of `GOLDEN_ATTESTATION_HASH` by `SECRET`.
pub const GOLDEN_R: felt252 = 0x3fdb3b83cb47b48c799b969bc14b76d51dd3425a33e8e94c8f8430a26bc3f18;
pub const GOLDEN_S: felt252 = 0xb783e02ebce061eb256c330b4dcfcc902d24d06a8965e26a9e319fcba00fd2;
/// `from` of the message-hash vector.
pub const MESSAGE_FROM: felt252 = 0x5afe;
/// `verifier::message_hash(MESSAGE_FROM, MARKER, golden claim felts)`.
pub const GOLDEN_MESSAGE_HASH: felt252 =
    0x2b71979fe789aea951ef427aeae50af0bfd7c4bb4f9b0239e9873ddb910730b;

/// The golden claim: `[1, PILE10_HASH, 0, PLAYER, 0xabc, 1650, 1, 2, 431, 0x33]`.
pub fn golden_claim() -> Outputs {
    Outputs {
        version: 1,
        level_hash: PILE10_HASH,
        seed: 0,
        player: PLAYER,
        inputs_hash: 0xabc,
        score: 1650,
        won: true,
        shots_used: 2,
        ticks_run: 431,
        final_state_hash: 0x33,
    }
}

/// The G4b golden shot on pile10 (`slingfall_game::fixtures::reference_outputs`'s inputs): the
/// reference pull of the `main` executable, player `PLAYER`.
pub fn reference_inputs() -> Array<felt252> {
    to_felts(
        @Inputs {
            player: PLAYER,
            shots: array![Shot { pull_x: -600, pull_y: -392, delay: 0, ability_tick: 0 }],
        },
    )
}

/// The felts `main` (and so `simulate`) returns for `reference_inputs()` on pile10.
pub fn reference_outputs() -> Array<felt252> {
    array![
        1, PILE10_HASH, 0, PLAYER,
        0x31b10e77b97a88153b1e9d781ecddece54061fe1cf88e6a3660eee99fda4f3b, 5350, 1, 1, 191,
        0x2ff3945fee21a4cc7f9447a645a65108dd2a7e697f0c06e75ef0475bbef13e9,
    ]
}
