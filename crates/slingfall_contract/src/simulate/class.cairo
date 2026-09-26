//! The simulation class `SlingfallSim` (`docs/DESIGN.md` D9, two-class layout): the physics alone,
//! no storage. `Slingfall::simulate` runs it through `library_call_syscall` (its code executes in
//! `Slingfall`'s context, so the L2 to L1 message is still sent by `Slingfall`); it is declared
//! separately and its class hash is `Slingfall`'s `sim_class_hash`. It is too large to declare on
//! its own (CASM 5.3x the class limit until rapier-cairo's cuts land): `tools/classsize` reports
//! its figures without failing on them.

use slingfall_level::outputs::Outputs;

/// The entry point `Slingfall` library-calls (selector `simulate`).
#[starknet::interface]
pub trait ISlingfallSim<TState> {
    /// Decodes the `Serde` felts of a level and of an `Inputs`, validates the inputs against the
    /// level and replays them (`simulate::run` with the real hook): pure, the D4 outputs.
    fn simulate(self: @TState, level: Array<felt252>, inputs: Array<felt252>) -> Outputs;
}

#[starknet::contract]
pub mod SlingfallSim {
    use slingfall_level::outputs::Outputs;
    use crate::simulate::{ActiveHook, run};

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl SlingfallSimImpl of super::ISlingfallSim<ContractState> {
        fn simulate(
            self: @ContractState, level: Array<felt252>, inputs: Array<felt252>,
        ) -> Outputs {
            run::<ActiveHook>(level.span(), inputs.span())
        }
    }
}
