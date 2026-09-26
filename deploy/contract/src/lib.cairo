//! This package builds `slingfall_contract::submit::Slingfall` (Scarb.toml) and, for the devnet
//! only, `FakeSatellite`: the two reads `SatelliteVerifier` makes of Herodotus's Satellite, true
//! for the facts its deployer registered (`deploy/e2e.sh`'s mocked settled path). Never deployed
//! on a public network.

#[starknet::interface]
pub trait IFakeSatellite<TState> {
    /// Registers a translated (Poseidon) fact; deployer only.
    fn register(ref self: TState, fact_hash: felt252);
    /// Registers a bridged (keccak) fact; deployer only.
    fn register_keccak(ref self: TState, fact_hash: u256);
    fn isCairoFactValid(self: @TState, fact_hash: felt252, is_mocked: bool) -> bool;
    fn isKeccakVerifiedFactHashValid(self: @TState, fact_hash: u256) -> bool;
}

#[starknet::contract]
pub mod FakeSatellite {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        owner: ContractAddress,
        facts: Map<felt252, bool>,
        keccak_facts: Map<u256, bool>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.owner.write(owner);
    }

    #[abi(embed_v0)]
    impl FakeSatelliteImpl of super::IFakeSatellite<ContractState> {
        fn register(ref self: ContractState, fact_hash: felt252) {
            assert(get_caller_address() == self.owner.read(), 'fake: caller');
            self.facts.write(fact_hash, true);
        }

        fn register_keccak(ref self: ContractState, fact_hash: u256) {
            assert(get_caller_address() == self.owner.read(), 'fake: caller');
            self.keccak_facts.write(fact_hash, true);
        }

        fn isCairoFactValid(self: @ContractState, fact_hash: felt252, is_mocked: bool) -> bool {
            !is_mocked && self.facts.read(fact_hash)
        }

        fn isKeccakVerifiedFactHashValid(self: @ContractState, fact_hash: u256) -> bool {
            self.keccak_facts.read(fact_hash)
        }
    }
}
