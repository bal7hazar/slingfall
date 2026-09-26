//! The `Slingfall` contract (`docs/DESIGN.md` D9): level registry, `simulate` (run in the SNIP-36
//! virtual OS), `submit` (`player == caller`, nullifier `poseidon(level_hash, player,
//! inputs_hash)`, the active `Verifier`, best score, leaderboard, `LevelValidated`) and a minimal
//! admin. No upgradeability yet.

use slingfall_level::outputs::Outputs;
use starknet::{ClassHash, ContractAddress};
use crate::registry::{LevelMeta, Record};
use crate::verifier::VerifierKind;

pub mod errors;
#[cfg(test)]
pub mod fixtures;
#[cfg(test)]
mod tests;

/// Players' entry points and reads.
#[starknet::interface]
pub trait ISlingfall<TState> {
    /// Registers a level given as its `Serde` felts (`docs/DESIGN.md` D2) after
    /// `LevelTrait::validate`; returns its `level_hash`. The caller is the author; the level is
    /// active.
    fn register_level(ref self: TState, level: Array<felt252>) -> felt252;
    /// Opens or closes a level to submissions; by its author or the admin.
    fn set_level_active(ref self: TState, level_hash: felt252, active: bool);
    /// The level's metadata (all zero when unknown).
    fn level(self: @TState, level_hash: felt252) -> LevelMeta;
    /// The level's `Serde` felts (empty when unknown).
    fn level_data(self: @TState, level_hash: felt252) -> Array<felt252>;
    /// Replays `inputs` (the `Serde` felts of an `Inputs`) on a registered level through a library
    /// call to the `SlingfallSim` class (`sim_class_hash`) and sends the outputs felts to
    /// `simulate::MARKER` as an L2 to L1 message from this contract. Meant for the virtual OS.
    fn simulate(ref self: TState, level_hash: felt252, inputs: Array<felt252>) -> Outputs;
    /// Records a replay's `outputs` (the 10 felts of D4) once `evidence` convinces the active
    /// verifier.
    fn submit(ref self: TState, outputs: Array<felt252>, evidence: Array<felt252>);
    /// `player`'s best validated attempt on the level (all zero when none).
    fn best(self: @TState, player: ContractAddress, level_hash: felt252) -> Record;
    /// Top `registry::LEADERBOARD_SIZE` won attempts, by decreasing score.
    fn leaderboard(self: @TState, level_hash: felt252) -> Array<(ContractAddress, u32)>;
}

/// Admin configuration: the verifier and its keys.
#[starknet::interface]
pub trait ISlingfallAdmin<TState> {
    fn admin(self: @TState) -> ContractAddress;
    fn virtual_os_hash(self: @TState) -> felt252;
    fn sim_class_hash(self: @TState) -> ClassHash;
    fn verifier(self: @TState) -> VerifierKind;
    fn attestation_key(self: @TState) -> felt252;
    fn set_admin(ref self: TState, admin: ContractAddress);
    /// The virtual-OS program hash the SNIP-36 proof facts must carry (versioned per Starknet
    /// release).
    fn set_virtual_os_hash(ref self: TState, virtual_os_hash: felt252);
    /// The class hash of `SlingfallSim`, the class `simulate` library-calls (zero: `simulate`
    /// panics `errors::SIMULATE_CLASS`).
    fn set_sim_class_hash(ref self: TState, sim_class_hash: ClassHash);
    fn set_verifier(ref self: TState, verifier: VerifierKind);
    /// Stark-curve public key of the `StubVerifier` attestations.
    fn set_attestation_key(ref self: TState, attestation_key: felt252);
}

#[starknet::contract]
pub mod Slingfall {
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use slingfall_level::level::{Level, LevelTrait};
    use slingfall_level::outputs::{Outputs, OutputsTrait};
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait,
    };
    use starknet::syscalls::send_message_to_l1_syscall;
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_number, get_block_timestamp,
        get_caller_address, get_contract_address, get_execution_info,
    };
    use crate::registry::{Entry, LevelMeta, Record, improves, insert};
    use crate::simulate::MARKER;
    use crate::simulate::class::{ISlingfallSimDispatcherTrait, ISlingfallSimLibraryDispatcher};
    use crate::verifier::{Snip36Verifier, StubVerifier, Verifier, VerifierKind};
    use super::errors;

    #[storage]
    struct Storage {
        admin: ContractAddress,
        virtual_os_hash: felt252,
        /// The class hash of `SlingfallSim` (`simulate` library-calls it).
        sim_class_hash: ClassHash,
        verifier: VerifierKind,
        attestation_key: felt252,
        levels: Map<felt252, LevelMeta>,
        /// `(level_hash, i)` -> the level's `i`-th felt: one storage write per felt (a
        /// `Vec::push` costs a length read and two writes).
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

    /// A validated attempt (emitted by every accepted `submit`, record or not).
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

    /// The verifier starts as `Snip36` with no program hash: nothing is accepted until the admin
    /// configures one.
    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        assert(admin.is_non_zero(), errors::ADMIN_ZERO);
        self.admin.write(admin);
    }

    #[abi(embed_v0)]
    impl SlingfallImpl of super::ISlingfall<ContractState> {
        fn register_level(ref self: ContractState, level: Array<felt252>) -> felt252 {
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

        fn set_level_active(ref self: ContractState, level_hash: felt252, active: bool) {
            let mut meta = self.levels.read(level_hash);
            assert(meta.version != 0, errors::LEVEL_UNKNOWN);
            let caller = get_caller_address();
            assert(caller == meta.author || caller == self.admin.read(), errors::LEVEL_CALLER);
            meta.active = active;
            self.levels.write(level_hash, meta);
            self.emit(LevelActiveSet { level_hash, active });
        }

        fn level(self: @ContractState, level_hash: felt252) -> LevelMeta {
            self.levels.read(level_hash)
        }

        fn level_data(self: @ContractState, level_hash: felt252) -> Array<felt252> {
            read_level(self, level_hash)
        }

        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            let level = read_level(@self, level_hash);
            assert(!level.is_empty(), errors::SIMULATE_LEVEL);
            let class_hash = self.sim_class_hash.read();
            assert(class_hash.is_non_zero(), errors::SIMULATE_CLASS);
            let outputs = ISlingfallSimLibraryDispatcher { class_hash }.simulate(level, inputs);
            send_message_to_l1_syscall(MARKER, outputs.to_felts().span()).unwrap_syscall();
            outputs
        }

        fn submit(ref self: ContractState, outputs: Array<felt252>, evidence: Array<felt252>) {
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
            assert(check(@self, claim, evidence.span()), errors::SUBMIT_PROOF);

            let Outputs { inputs_hash, score, won, .. } = claim;
            let key = (player, level_hash);
            if improves(@self.best.read(key), won, score) {
                self.best.write(key, Record { score, won, inputs_hash, block: get_block_number() });
                if won {
                    update_board(ref self, level_hash, player, score);
                }
            }
            self.emit(LevelValidated { player, level_hash, inputs_hash, score, won });
        }

        fn best(self: @ContractState, player: ContractAddress, level_hash: felt252) -> Record {
            self.best.read((player, level_hash))
        }

        fn leaderboard(self: @ContractState, level_hash: felt252) -> Array<(ContractAddress, u32)> {
            let mut rows = array![];
            for entry in read_board(self, level_hash) {
                rows.append((entry.player, entry.score));
            }
            rows
        }
    }

    #[abi(embed_v0)]
    impl SlingfallAdminImpl of super::ISlingfallAdmin<ContractState> {
        fn admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn virtual_os_hash(self: @ContractState) -> felt252 {
            self.virtual_os_hash.read()
        }

        fn sim_class_hash(self: @ContractState) -> ClassHash {
            self.sim_class_hash.read()
        }

        fn verifier(self: @ContractState) -> VerifierKind {
            self.verifier.read()
        }

        fn attestation_key(self: @ContractState) -> felt252 {
            self.attestation_key.read()
        }

        fn set_admin(ref self: ContractState, admin: ContractAddress) {
            assert_admin(@self);
            assert(admin.is_non_zero(), errors::ADMIN_ZERO);
            self.admin.write(admin);
        }

        fn set_virtual_os_hash(ref self: ContractState, virtual_os_hash: felt252) {
            assert_admin(@self);
            self.virtual_os_hash.write(virtual_os_hash);
        }

        fn set_sim_class_hash(ref self: ContractState, sim_class_hash: ClassHash) {
            assert_admin(@self);
            self.sim_class_hash.write(sim_class_hash);
        }

        fn set_verifier(ref self: ContractState, verifier: VerifierKind) {
            assert_admin(@self);
            self.verifier.write(verifier);
        }

        fn set_attestation_key(ref self: ContractState, attestation_key: felt252) {
            assert_admin(@self);
            self.attestation_key.write(attestation_key);
        }
    }

    fn assert_admin(self: @ContractState) {
        assert(get_caller_address() == self.admin.read(), errors::ADMIN_CALLER);
    }

    /// Runs the active verifier on `claim`.
    fn check(self: @ContractState, claim: Outputs, evidence: Span<felt252>) -> bool {
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

    fn read_level(self: @ContractState, level_hash: felt252) -> Array<felt252> {
        let mut felts = array![];
        for i in 0..self.level_len.read(level_hash) {
            felts.append(self.level_felts.read((level_hash, i)));
        }
        felts
    }

    fn read_board(self: @ContractState, level_hash: felt252) -> Array<Entry> {
        let stored = self.boards.entry(level_hash);
        let mut board = array![];
        for i in 0..stored.len() {
            board.append(stored.at(i).read());
        }
        board
    }

    /// Inserts a won record into the level's leaderboard, writing only the rows that change.
    fn update_board(
        ref self: ContractState, level_hash: felt252, player: ContractAddress, score: u32,
    ) {
        let old = read_board(@self, level_hash);
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
