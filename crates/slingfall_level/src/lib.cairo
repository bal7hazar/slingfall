//! Slingfall level format: the `Level` a replay runs, the player's `Inputs`, the proven `Outputs`
//! and their Poseidon hashes (`docs/DESIGN.md` D2-D4). No `starknet` dependency (`AGENTS.md` §7).
//! Modules are pre-declared by the orchestrator (`docs/PLAN.md`, lot G2).

pub mod errors;
pub mod hash;
pub mod inputs;
pub mod level;
pub mod outputs;

#[cfg(test)]
mod tests {
    use fixed::Fixed;
    use slingfall_testing::opaque;

    /// Empty probe: the fixed overhead snforge charges to any test in this crate.
    #[test]
    fn steps_baseline() {}

    /// The felt layout of D2 relies on `Fixed` serialising as its raw `i64`, one felt,
    /// negative values as `P - x`.
    #[test]
    fn test_fixed_serde_is_one_raw_felt() {
        let cases: Array<(i64, felt252)> = array![(0, 0), (0x100000000, 0x100000000), (-1, -1)];
        for (raw, expected) in cases {
            let mut felts: Array<felt252> = array![];
            opaque(Fixed { raw }).serialize(ref felts);
            assert_eq!(felts, array![expected]);
        }
    }
}
