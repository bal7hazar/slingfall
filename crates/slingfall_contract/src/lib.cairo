//! Slingfall Starknet contract: the level registry, `simulate` (executed in the SNIP-36 virtual
//! OS), `submit` (proof facts, nullifier, best score) and the `Verifier` interface
//! (`docs/DESIGN.md` D9). The only crate of the workspace that depends on `starknet`.
//! Modules are pre-declared by the orchestrator (`docs/PLAN.md`, lot G7).

pub mod registry;
pub mod simulate;
pub mod submit;
pub mod verifier;

#[cfg(test)]
mod tests {
    use core::poseidon::poseidon_hash_span;
    use slingfall_testing::opaque;

    /// Empty probe: the fixed overhead snforge charges to any test in this crate.
    #[test]
    fn steps_baseline() {}

    /// The nullifier of D9 is a Poseidon hash over three felts: order matters.
    #[test]
    fn test_nullifier_hash_is_ordered() {
        let (level_hash, player, inputs_hash) = opaque((1, 2, 3));
        let a = poseidon_hash_span([level_hash, player, inputs_hash].span());
        let b = poseidon_hash_span([player, level_hash, inputs_hash].span());
        assert_ne!(a, b);
        assert_eq!(a, poseidon_hash_span([1, 2, 3].span()));
    }
}
