//! The class hashes of the alternatives' own classes, compiled as constants by layouts (c) and (d)
//! (`tests::hashes::test_pinned_probe_hashes` prints them when stale; `scripts/pin.py --probes`).

use starknet::ClassHash;

// Build root of these class hashes:
// /home/runner/work/slingfall/slingfall
pub const TYPED_RULES_HASH: felt252 =
    0x438904a2a6a570332184f699a77a9cd8dc7f5ba43fc2a6cc5d5f9846c63a6fb;
pub const EDIT_HASH: felt252 = 0x77758904171475cd7b6c83480ec0b14cbf5ed0f45f9cf12000021fe3164d31c;

/// Where the alternatives find their classes.
pub trait ProbeHashes {
    /// `crate::probes::layouts::TypedRulesClass`.
    fn typed_rules() -> ClassHash;
    /// `crate::probes::layouts::EditClass` (the game's own World edits, layout (d)).
    fn edit() -> ClassHash;
}

/// The alternatives' classes at their declared hashes.
pub impl PinnedProbes of ProbeHashes {
    fn typed_rules() -> ClassHash {
        const H: ClassHash = TYPED_RULES_HASH.try_into().unwrap();
        H
    }

    fn edit() -> ClassHash {
        const H: ClassHash = EDIT_HASH.try_into().unwrap();
        H
    }
}
