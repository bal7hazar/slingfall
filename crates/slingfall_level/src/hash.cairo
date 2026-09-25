//! `level_hash` and `inputs_hash`: `poseidon_hash_span` of the `Serde` felts
//! (`docs/DESIGN.md` D2, D3).

use core::poseidon::poseidon_hash_span;

/// The `Serde` felts of `value`, the layout that every hash of this crate commits to.
pub fn to_felts<T, +Serde<T>>(value: @T) -> Array<felt252> {
    let mut felts: Array<felt252> = array![];
    value.serialize(ref felts);
    felts
}

/// `poseidon_hash_span` of the `Serde` felts of `value`.
pub fn serde_hash<T, +Serde<T>>(value: @T) -> felt252 {
    poseidon_hash_span(to_felts(value).span())
}
