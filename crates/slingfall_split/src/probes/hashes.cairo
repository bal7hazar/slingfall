//! The class hashes of the alternatives' own classes, compiled as constants by layouts (c) and (d)
//! (`tests::hashes::test_pinned_probe_hashes` prints them when stale; `scripts/pin.py --probes`).

use starknet::ClassHash;

pub const TYPED_RULES_HASH: felt252 =
    0x3e04611738dc4c96ca2076c98be9148501931f43b2f2767a6dbef9f98c63f6a;
pub const EDIT_HASH: felt252 = 0x365ed50630cce019cc3a97fd1d127422ad4954837c494d2a5ab8b4d3b5da322;

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
