//! Lever (iii), the two-class layout: `SplitCore` is `Slingfall` whose `simulate` reads the level
//! and hands the felts to `SplitSim::run` through `library_call_syscall` (the simulation class's
//! code runs in `SplitCore`'s context: the L2 to L1 message is still sent by `SplitCore`);
//! `SplitSim` has no storage and carries the physics alone.

use slingfall_level::outputs::Outputs;

/// The simulation class: `simulate::run` with the real hook on the given felts.
#[starknet::interface]
pub trait ISplitSim<TState> {
    fn run(self: @TState, level: Array<felt252>, inputs: Array<felt252>) -> Outputs;
}

#[starknet::contract]
pub mod SplitSim {
    use slingfall_contract::simulate::replay_hook::ReplaySimulateHook;
    use slingfall_contract::simulate::run;
    use slingfall_level::outputs::Outputs;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl SplitSimImpl of super::ISplitSim<ContractState> {
        fn run(self: @ContractState, level: Array<felt252>, inputs: Array<felt252>) -> Outputs {
            run::<ReplaySimulateHook>(level.span(), inputs.span())
        }
    }
}

#[starknet::contract]
pub mod SplitCore {
    use slingfall_contract::simulate::MARKER;
    use slingfall_contract::submit::errors;
    use slingfall_level::outputs::{Outputs, OutputsTrait};
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::send_message_to_l1_syscall;
    use starknet::{ClassHash, ContractAddress, SyscallResultTrait};
    use crate::base::BaseComponent;
    use super::{ISplitSimDispatcherTrait, ISplitSimLibraryDispatcher};

    component!(path: BaseComponent, storage: base, event: BaseEvent);
    #[abi(embed_v0)]
    impl BaseImpl = BaseComponent::BaseImpl<ContractState>;
    #[abi(embed_v0)]
    impl AdminImpl = BaseComponent::AdminImpl<ContractState>;
    impl InternalImpl = BaseComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        base: BaseComponent::Storage,
        /// The class hash of `SplitSim` (set at deployment; an admin setter in a real layout).
        sim_class: ClassHash,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress, sim_class: ClassHash) {
        self.base.initializer(admin);
        self.sim_class.write(sim_class);
    }

    #[abi(embed_v0)]
    impl SimulateImpl of crate::fixtures::ISimulate<ContractState> {
        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            let level = self.base.read_level(level_hash);
            assert(!level.is_empty(), errors::SIMULATE_LEVEL);
            let sim = ISplitSimLibraryDispatcher { class_hash: self.sim_class.read() };
            let outputs = sim.run(level, inputs);
            send_message_to_l1_syscall(MARKER, outputs.to_felts().span()).unwrap_syscall();
            outputs
        }
    }
}
