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
    0xf23e293dc0e3bdde13040eb03964304bb82d8c9315e65865bf93e2cc5fcd0a;
/// ECDSA signature `(r, s)` of `GOLDEN_ATTESTATION_HASH` by `SECRET`.
pub const GOLDEN_R: felt252 = 0x4a13c6238b607f1571896992647877421057f184e686fc0fccf4e26b777e668;
pub const GOLDEN_S: felt252 = 0x5add451759eeed34bfd22bf8872d6e9460b3fbbc56b89086c203ff34ffe214a;
/// `from` of the message-hash vector.
pub const MESSAGE_FROM: felt252 = 0x5afe;
/// `verifier::message_hash(MESSAGE_FROM, MARKER, golden claim felts)`.
pub const GOLDEN_MESSAGE_HASH: felt252 =
    0x743c2d89f0290e5c22ae2ce6d52430d15361a740d330187e43f4bfe65eaea2f;

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
            shots: array![Shot { pull_x: -604, pull_y: -392, delay: 0, ability_tick: 0 }],
        },
    )
}

/// The felts `main` (and so `simulate`) returns for `reference_inputs()` on pile10.
pub fn reference_outputs() -> Array<felt252> {
    array![
        1, PILE10_HASH, 0, PLAYER,
        0x5c242b3f403a2cc4fbf7e6f51d9ceab41baeabb21691fed72ec2cdce0d51d8f, 5200, 1, 1, 107,
        0x135df25e65cc5905398c07fc0fb89cb47ee2360a8704793595e82dd6cfbb255,
    ]
}
