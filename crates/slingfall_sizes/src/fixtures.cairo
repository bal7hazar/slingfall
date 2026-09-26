//! The layered fixtures (a)-(e) of `crate`'s table: `BaseComponent` plus a `simulate` entry point
//! with a growing hook. `simulate_with` is the body of `Slingfall::simulate` with the hook as a
//! parameter.

use slingfall_contract::simulate::{MARKER, SimulateHook, run};
use slingfall_contract::submit::errors;
use slingfall_level::outputs::{Outputs, OutputsTrait};
use starknet::SyscallResultTrait;
use starknet::syscalls::send_message_to_l1_syscall;

/// `simulate` on a registered level: its stored felts (`level`) and the `inputs` felts.
#[starknet::interface]
pub trait ISimulate<TState> {
    fn simulate(ref self: TState, level_hash: felt252, inputs: Array<felt252>) -> Outputs;
}

/// `Slingfall::simulate` after the level read: decode, validate, `Hook`, then the L2 to L1
/// message.
pub fn simulate_with<impl Hook: SimulateHook>(
    level: Array<felt252>, inputs: Array<felt252>,
) -> Outputs {
    assert(!level.is_empty(), errors::SIMULATE_LEVEL);
    let outputs = run::<Hook>(level.span(), inputs.span());
    send_message_to_l1_syscall(MARKER, outputs.to_felts().span()).unwrap_syscall();
    outputs
}

/// (a) Registry, `submit` and admin: `Slingfall` without `simulate`.
#[starknet::contract]
pub mod SizeA_Registry {
    use starknet::ContractAddress;
    use crate::base::BaseComponent;

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
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.base.initializer(admin);
    }
}

/// (b) + `simulate` with the stub hook: `Level` / `Inputs` decode, validate, hashes. The modules
/// below differ from this one in their hook only.
#[starknet::contract]
pub mod SizeB_Decode {
    use slingfall_contract::simulate::StubSimulateHook;
    use slingfall_level::outputs::Outputs;
    use starknet::ContractAddress;
    use crate::base::BaseComponent;

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
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.base.initializer(admin);
    }

    #[abi(embed_v0)]
    impl SimulateImpl of super::ISimulate<ContractState> {
        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            super::simulate_with::<StubSimulateHook>(self.base.read_level(level_hash), inputs)
        }
    }
}

#[starknet::contract]
pub mod SizeC_World {
    use slingfall_level::outputs::Outputs;
    use starknet::ContractAddress;
    use crate::base::BaseComponent;
    use crate::hooks::WorldHook;

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
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.base.initializer(admin);
    }

    #[abi(embed_v0)]
    impl SimulateImpl of super::ISimulate<ContractState> {
        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            super::simulate_with::<WorldHook>(self.base.read_level(level_hash), inputs)
        }
    }
}

#[starknet::contract]
pub mod SizeC2_GameNew {
    use slingfall_level::outputs::Outputs;
    use starknet::ContractAddress;
    use crate::base::BaseComponent;
    use crate::hooks::GameNewHook;

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
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.base.initializer(admin);
    }

    #[abi(embed_v0)]
    impl SimulateImpl of super::ISimulate<ContractState> {
        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            super::simulate_with::<GameNewHook>(self.base.read_level(level_hash), inputs)
        }
    }
}

#[starknet::contract]
pub mod SizeD_OneStep {
    use slingfall_level::outputs::Outputs;
    use starknet::ContractAddress;
    use crate::base::BaseComponent;
    use crate::hooks::OneStepHook;

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
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.base.initializer(admin);
    }

    #[abi(embed_v0)]
    impl SimulateImpl of super::ISimulate<ContractState> {
        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            super::simulate_with::<OneStepHook>(self.base.read_level(level_hash), inputs)
        }
    }
}

#[starknet::contract]
pub mod SizeD2_OneTick {
    use slingfall_level::outputs::Outputs;
    use starknet::ContractAddress;
    use crate::base::BaseComponent;
    use crate::hooks::OneTickHook;

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
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.base.initializer(admin);
    }

    #[abi(embed_v0)]
    impl SimulateImpl of super::ISimulate<ContractState> {
        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            super::simulate_with::<OneTickHook>(self.base.read_level(level_hash), inputs)
        }
    }
}

#[starknet::contract]
pub mod SizeE_Simulate {
    use slingfall_contract::simulate::replay_hook::ReplaySimulateHook;
    use slingfall_level::outputs::Outputs;
    use starknet::ContractAddress;
    use crate::base::BaseComponent;

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
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        BaseEvent: BaseComponent::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.base.initializer(admin);
    }

    #[abi(embed_v0)]
    impl SimulateImpl of super::ISimulate<ContractState> {
        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            super::simulate_with::<ReplaySimulateHook>(self.base.read_level(level_hash), inputs)
        }
    }
}
