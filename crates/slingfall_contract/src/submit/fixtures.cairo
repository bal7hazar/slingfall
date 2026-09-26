//! Fixtures of the contract tests: the golden claim, key and signature of the verifier tests. The
//! fixture levels are `slingfall_level::level::fixtures`.

use slingfall_level::hash::to_felts;
use slingfall_level::inputs::{Inputs, Shot};
use slingfall_level::level::fixtures::{ONE_BLOCK_HASH, PILE10_HASH, one_block_felts, pile10_felts};
use slingfall_level::outputs::Outputs;
use crate::verifier::run_args;

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

// The two runs of lot E3a proven by Atlantic (`fixtures/proofs/atlantic/<case>.json`), player
// `PLAYER`: their facts are on the Sepolia Satellite (the keccak one bridged, 2026-09-26).

/// The bootloader's hash of `c1main` in E3a (rapier2d alpha.2).
pub const E3A_CHILD_PROGRAM_HASH: felt252 =
    0x128791df23988bef1c8aef3be7ce36ad68278d19878369e5fb7ed2515d5b053;
/// Atlantic's bootloader.
pub const ATLANTIC_BOOTLOADER_HASH: felt252 =
    0x288ba12915c0c7e91df572cf3ed0c9f391aa673cb247c5a208beaa50b668f09;
/// Integrity's `SHARP_BOOTLOADER_PROGRAM_HASH`.
pub const SHARP_BOOTLOADER_HASH: felt252 =
    0x5ab580b04e3532b6b18f81cfa654a05e29dd8e2352d88df1e765a84072db07;
/// Herodotus's Satellite on Starknet Sepolia.
pub const SATELLITE_SEPOLIA: felt252 =
    0x421cd95f9ddabdd090db74c9429f257cb6bc1ccc339278d1db1de39156676e;
/// `pile10-reference`: `reference_outputs()` on pile10 with `reference_inputs()`.
pub const PILE10_INTEGRITY_FACT: felt252 =
    0xe120cbc84792ceef50edce9bfe16fc45d4b683823634baedc342a6fa2a5bfa;
pub const PILE10_SHARP_FACT: u256 =
    0xfa838c8705c1dc9e990043073cef186903ae622569765ea50f0a9b20d4faf144;
/// Felts of Atlantic's bootloader output for `pile10-reference`.
pub const PILE10_OUTPUT_LEN: usize = 172;
/// `one_block-miss`: `one_block_miss_outputs()` on one_block with `one_block_miss_inputs()`.
pub const ONE_BLOCK_INTEGRITY_FACT: felt252 =
    0x2667b3e4e61c635b2a2209c138b0c431f98e332a5d6e75dcfc7c1658b5c6bf5;
pub const ONE_BLOCK_SHARP_FACT: u256 =
    0xdaff80a0ac4b923b7fb238706af52180b6382e396c12a8c21fc743616a7adc9d;

/// `c1main`'s argument for `pile10-reference`: `[len(pile10), pile10..., len(inputs), inputs...]`.
pub fn reference_args() -> Array<felt252> {
    run_args(pile10_felts().span(), reference_inputs().span())
}

/// `c1main`'s argument for `one_block-miss`.
pub fn one_block_miss_args() -> Array<felt252> {
    run_args(one_block_felts().span(), one_block_miss_inputs().span())
}

/// The shot of `one_block-miss` (pull `(-150, -150)`), player `PLAYER`.
pub fn one_block_miss_inputs() -> Array<felt252> {
    to_felts(
        @Inputs {
            player: PLAYER,
            shots: array![Shot { pull_x: -150, pull_y: -150, delay: 0, ability_tick: 0 }],
        },
    )
}

/// The outputs of `one_block-miss` (a lost attempt, score 0).
pub fn one_block_miss_outputs() -> Array<felt252> {
    array![
        1, ONE_BLOCK_HASH, 0, PLAYER,
        0x209b82eb4432eaf2569fe2ca05ae6191c451af7f3ecdc6df1b17f9bb02f7998, 0, 0, 1, 120,
        0x612b0349b4ca8083c61573d3504e1e4fad7958423ed9fbd1816d9f8dfad52cf,
    ]
}
