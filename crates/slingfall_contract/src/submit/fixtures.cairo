//! Fixture levels of the contract tests: the felts of
//! `fixtures/levels/{pile10,one_block}.felts.json`
//! (`slingfall_level::level::fixtures` is test-only in its crate, so they are repeated here), and
//! the golden claim, key and signature of the verifier tests.

use slingfall_level::outputs::Outputs;

/// `fixtures/levels/pile10.json`: 146 felts.
pub fn pile10_felts() -> Array<felt252> {
    array![
        1, 2, 0, 3618502788666131213697322783095070105623107215331596699973092056093738391307, 3,
        360, 3618502788666131213697322783095070105623107215331596699973092056092922347521,
        3618502788666131213697322783095070105623107215331596699973092056092922347521, 214748364800,
        171798691840, 12884901888, 10737418240, 1024, 85899346, 3, 0, 0, 0, 4, 4294967296,
        2576980378, 429496730, 100, 171798691840, 4294967296, 50, 10737418240, 3435973837,
        214748365, 300, 515396075520, 1431655765, 150, 3865470566, 214748365, 858993459, 40,
        64424509440, 8589934592, 100, 4294967296, 2576980378, 429496730, 30, 42949672960,
        4294967296, 1000, 11, 0, 3, 0, 4294967296, 0, 0, 4294967296, 0, 1, 1, 1, 2147483648,
        2147483648, 77309411328, 2147483648, 4294967296, 0, 0, 1, 1, 2147483648, 2147483648,
        81604378624, 2147483648, 4294967296, 0, 0, 1, 1, 2147483648, 2147483648, 85899345920,
        2147483648, 4294967296, 0, 0, 1, 1, 2147483648, 2147483648, 90194313216, 2147483648,
        4294967296, 0, 0, 1, 1, 2147483648, 2147483648, 79456894976, 6442450944, 4294967296, 0, 1,
        1, 1, 2147483648, 2147483648, 83751862272, 6442450944, 4294967296, 0, 1, 1, 1, 2147483648,
        2147483648, 88046829568, 6442450944, 4294967296, 0, 1, 1, 1, 2147483648, 2147483648,
        81604378624, 10737418240, 4294967296, 0, 2, 1, 1, 2147483648, 2147483648, 85899345920,
        10737418240, 4294967296, 0, 2, 2, 0, 1717986918, 83751862272, 14602888806, 4294967296, 0, 3,
    ]
}

/// Golden `level_hash` of `pile10`.
pub const PILE10_HASH: felt252 = 0x1b7372774c035ddcb4f559f8a8e37e0215235d87aab0748de58ef2ba0c18b54;

/// `fixtures/levels/one_block.json`: 72 felts.
pub fn one_block_felts() -> Array<felt252> {
    array![
        1, 1, 0, 3618502788666131213697322783095070105623107215331596699973092056093738391307, 1,
        360, 3618502788666131213697322783095070105623107215331596699973092056092922347521,
        3618502788666131213697322783095070105623107215331596699973092056092922347521, 214748364800,
        171798691840, 12884901888, 10737418240, 1024, 85899346, 1, 0, 4, 4294967296, 2576980378,
        429496730, 100, 171798691840, 4294967296, 50, 10737418240, 3435973837, 214748365, 300,
        515396075520, 1431655765, 150, 3865470566, 214748365, 858993459, 40, 64424509440,
        8589934592, 100, 4294967296, 2576980378, 429496730, 30, 42949672960, 4294967296, 1000, 3, 0,
        3, 0, 4294967296, 0, 0, 4294967296, 0, 1, 1, 1, 2147483648, 2147483648, 85899345920,
        2147483648, 4294967296, 0, 0, 2, 0, 1717986918, 85899345920, 6012954214, 4294967296, 0, 3,
    ]
}

/// Golden `level_hash` of `one_block`.
pub const ONE_BLOCK_HASH: felt252 =
    0x5c2facd32b8c47ffd8909d04d73808bbf5967f1bb3a4ae762d2637fbe9e0431;

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
