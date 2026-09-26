//! `BaseComponent`: the `Slingfall` contract without `simulate` (registry, `submit`, admin), the
//! same storage, entry points, checks and events as `slingfall_contract::submit::Slingfall`, as a
//! component so that every fixture carries it. `read_level` is the internal read `simulate` needs.

use slingfall_contract::registry::{LevelMeta, Record};
use starknet::ContractAddress;

/// `ISlingfall` without `simulate`.
#[starknet::interface]
pub trait ISlingfallBase<TState> {
    fn register_level(ref self: TState, level: Array<felt252>) -> felt252;
    fn set_level_active(ref self: TState, level_hash: felt252, active: bool);
    fn level(self: @TState, level_hash: felt252) -> LevelMeta;
    fn level_data(self: @TState, level_hash: felt252) -> Array<felt252>;
    fn submit(ref self: TState, outputs: Array<felt252>, evidence: Array<felt252>);
    fn best(self: @TState, player: ContractAddress, level_hash: felt252) -> Record;
    fn leaderboard(self: @TState, level_hash: felt252) -> Array<(ContractAddress, u32)>;
}

#[starknet::component]
pub mod BaseComponent {
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use slingfall_contract::registry::{Entry, LevelMeta, Record, improves, insert};
    use slingfall_contract::submit::{ISlingfallAdmin, errors};
    use slingfall_contract::verifier::{Snip36Verifier, StubVerifier, Verifier, VerifierKind};
    use slingfall_level::level::{Level, LevelTrait};
    use slingfall_level::outputs::{Outputs, OutputsTrait};
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait,
    };
    use starknet::{
        ContractAddress, get_block_number, get_block_timestamp, get_caller_address,
        get_contract_address, get_execution_info,
    };

    #[storage]
    pub struct Storage {
        admin: ContractAddress,
        virtual_os_hash: felt252,
        verifier: VerifierKind,
        attestation_key: felt252,
        levels: Map<felt252, LevelMeta>,
        level_felts: Map<(felt252, u32), felt252>,
        level_len: Map<felt252, u32>,
        nullifiers: Map<felt252, bool>,
        best: Map<(ContractAddress, felt252), Record>,
        boards: Map<felt252, Vec<Entry>>,
    }

    #[event]
    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub enum Event {
        LevelRegistered: LevelRegistered,
        LevelActiveSet: LevelActiveSet,
        LevelValidated: LevelValidated,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct LevelRegistered {
        #[key]
        pub level_hash: felt252,
        pub author: ContractAddress,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct LevelActiveSet {
        #[key]
        pub level_hash: felt252,
        pub active: bool,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct LevelValidated {
        #[key]
        pub player: ContractAddress,
        #[key]
        pub level_hash: felt252,
        pub inputs_hash: felt252,
        pub score: u32,
        pub won: bool,
    }

    #[embeddable_as(BaseImpl)]
    impl Base<
        TContractState, +HasComponent<TContractState>,
    > of super::ISlingfallBase<ComponentState<TContractState>> {
        fn register_level(
            ref self: ComponentState<TContractState>, level: Array<felt252>,
        ) -> felt252 {
            let mut felts = level.span();
            let decoded: Option<Level> = Serde::deserialize(ref felts);
            let Some(decoded) = decoded else {
                core::panic_with_felt252(errors::REGISTER_FELTS)
            };
            assert(felts.is_empty(), errors::REGISTER_FELTS);
            decoded.validate();
            let level_hash = decoded.hash();
            let meta = self.levels.read(level_hash);
            assert(meta.version == 0, errors::REGISTER_EXISTS);
            let author = get_caller_address();
            self
                .levels
                .write(
                    level_hash,
                    LevelMeta {
                        author,
                        version: decoded.version,
                        active: true,
                        registered_at: get_block_timestamp(),
                    },
                );
            let mut i: u32 = 0;
            for felt in level {
                self.level_felts.write((level_hash, i), felt);
                i += 1;
            }
            self.level_len.write(level_hash, i);
            self.emit(LevelRegistered { level_hash, author });
            level_hash
        }

        fn set_level_active(
            ref self: ComponentState<TContractState>, level_hash: felt252, active: bool,
        ) {
            let mut meta = self.levels.read(level_hash);
            assert(meta.version != 0, errors::LEVEL_UNKNOWN);
            let caller = get_caller_address();
            assert(caller == meta.author || caller == self.admin.read(), errors::LEVEL_CALLER);
            meta.active = active;
            self.levels.write(level_hash, meta);
            self.emit(LevelActiveSet { level_hash, active });
        }

        fn level(self: @ComponentState<TContractState>, level_hash: felt252) -> LevelMeta {
            self.levels.read(level_hash)
        }

        fn level_data(
            self: @ComponentState<TContractState>, level_hash: felt252,
        ) -> Array<felt252> {
            self.read_level(level_hash)
        }

        fn submit(
            ref self: ComponentState<TContractState>,
            outputs: Array<felt252>,
            evidence: Array<felt252>,
        ) {
            let claim = OutputsTrait::from_felts(outputs.span());
            let level_hash = claim.level_hash;
            let meta = self.levels.read(level_hash);
            assert(meta.version != 0, errors::SUBMIT_LEVEL);
            assert(meta.active, errors::SUBMIT_INACTIVE);
            let player = get_caller_address();
            assert(claim.player == player.into(), errors::SUBMIT_PLAYER);
            let nullifier = poseidon_hash_span(
                [level_hash, claim.player, claim.inputs_hash].span(),
            );
            assert(!self.nullifiers.read(nullifier), errors::SUBMIT_NULLIFIER);
            self.nullifiers.write(nullifier, true);
            assert(self.check(claim, evidence.span()), errors::SUBMIT_PROOF);

            let Outputs { inputs_hash, score, won, .. } = claim;
            let key = (player, level_hash);
            if improves(@self.best.read(key), won, score) {
                self.best.write(key, Record { score, won, inputs_hash, block: get_block_number() });
                if won {
                    self.update_board(level_hash, player, score);
                }
            }
            self.emit(LevelValidated { player, level_hash, inputs_hash, score, won });
        }

        fn best(
            self: @ComponentState<TContractState>, player: ContractAddress, level_hash: felt252,
        ) -> Record {
            self.best.read((player, level_hash))
        }

        fn leaderboard(
            self: @ComponentState<TContractState>, level_hash: felt252,
        ) -> Array<(ContractAddress, u32)> {
            let mut rows = array![];
            for entry in self.read_board(level_hash) {
                rows.append((entry.player, entry.score));
            }
            rows
        }
    }

    #[embeddable_as(AdminImpl)]
    impl Admin<
        TContractState, +HasComponent<TContractState>,
    > of ISlingfallAdmin<ComponentState<TContractState>> {
        fn admin(self: @ComponentState<TContractState>) -> ContractAddress {
            self.admin.read()
        }

        fn virtual_os_hash(self: @ComponentState<TContractState>) -> felt252 {
            self.virtual_os_hash.read()
        }

        fn verifier(self: @ComponentState<TContractState>) -> VerifierKind {
            self.verifier.read()
        }

        fn attestation_key(self: @ComponentState<TContractState>) -> felt252 {
            self.attestation_key.read()
        }

        fn set_admin(ref self: ComponentState<TContractState>, admin: ContractAddress) {
            self.assert_admin();
            assert(admin.is_non_zero(), errors::ADMIN_ZERO);
            self.admin.write(admin);
        }

        fn set_virtual_os_hash(ref self: ComponentState<TContractState>, virtual_os_hash: felt252) {
            self.assert_admin();
            self.virtual_os_hash.write(virtual_os_hash);
        }

        fn set_verifier(ref self: ComponentState<TContractState>, verifier: VerifierKind) {
            self.assert_admin();
            self.verifier.write(verifier);
        }

        fn set_attestation_key(ref self: ComponentState<TContractState>, attestation_key: felt252) {
            self.assert_admin();
            self.attestation_key.write(attestation_key);
        }
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>,
    > of InternalTrait<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>, admin: ContractAddress) {
            assert(admin.is_non_zero(), errors::ADMIN_ZERO);
            self.admin.write(admin);
        }

        fn assert_admin(self: @ComponentState<TContractState>) {
            assert(get_caller_address() == self.admin.read(), errors::ADMIN_CALLER);
        }

        fn check(
            self: @ComponentState<TContractState>, claim: Outputs, evidence: Span<felt252>,
        ) -> bool {
            match self.verifier.read() {
                VerifierKind::Snip36 => {
                    let facts = get_execution_info().unbox().tx_info.unbox().proof_facts;
                    let mut verifier = Snip36Verifier {
                        virtual_os_hash: self.virtual_os_hash.read(),
                        from: get_contract_address().into(),
                        facts,
                    };
                    verifier.check(claim, evidence)
                },
                VerifierKind::Stub => {
                    let mut verifier = StubVerifier { public_key: self.attestation_key.read() };
                    verifier.check(claim, evidence)
                },
            }
        }

        fn read_level(
            self: @ComponentState<TContractState>, level_hash: felt252,
        ) -> Array<felt252> {
            let mut felts = array![];
            for i in 0..self.level_len.read(level_hash) {
                felts.append(self.level_felts.read((level_hash, i)));
            }
            felts
        }

        fn read_board(self: @ComponentState<TContractState>, level_hash: felt252) -> Array<Entry> {
            let stored = self.boards.entry(level_hash);
            let mut board = array![];
            for i in 0..stored.len() {
                board.append(stored.at(i).read());
            }
            board
        }

        fn update_board(
            ref self: ComponentState<TContractState>,
            level_hash: felt252,
            player: ContractAddress,
            score: u32,
        ) {
            let old = self.read_board(level_hash);
            let new = insert(old.span(), player, score);
            let stored = self.boards.entry(level_hash);
            let old_len: u64 = old.len().into();
            let mut i: u64 = 0;
            for entry in new {
                if i >= old_len {
                    stored.push(entry);
                } else if *old[i.try_into().unwrap()] != entry {
                    stored.at(i).write(entry);
                }
                i += 1;
            }
        }
    }
}
