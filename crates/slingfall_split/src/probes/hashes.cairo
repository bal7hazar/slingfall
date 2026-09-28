//! The class hash of the alternatives' rules class, compiled as a constant by layouts (c) and (d)
//! (`tests::hashes::test_pinned_probe_hashes` prints it when stale; `scripts/pin.py --probes`).

use starknet::ClassHash;

pub const TYPED_RULES_HASH: felt252 =
    0x28f9c0efe05acc34803979286a1ed42f747b5e595040e311b53fb251894fcf2;

/// Where the alternatives find their rules class.
pub trait ProbeHashes {
    /// `crate::probes::layouts::TypedRulesClass`.
    fn typed_rules() -> ClassHash;
}

/// The alternatives' class at its declared hash.
pub impl PinnedProbes of ProbeHashes {
    fn typed_rules() -> ClassHash {
        const H: ClassHash = TYPED_RULES_HASH.try_into().unwrap();
        H
    }
}
