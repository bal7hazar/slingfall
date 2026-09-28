//! v2 storage read by v3 code: `SlingfallV2Storage` freezes v2's `Storage` (`submit.cairo` at
//! `2625ad1`, the contract live on Sepolia since lot D2) and v2's `Best` packing, writes one value
//! of every kind, then replaces its class with `Slingfall` (what `upgrade` does); v3 reads them
//! back through its interface and proves an attempt v2 attested.

use core::poseidon::poseidon_hash_span;
use slingfall_level::level::fixtures::{PILE10_HASH, pile10_felts};
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};
use starknet::ContractAddress;
use crate::registry::{Best, LevelMeta};
use crate::submit::fixtures::{ATTESTATION_KEY, PLAYER, reference_inputs};
use crate::submit::{FOREVER, nullifier};
use crate::verifier::{SatelliteConfig, VerifierKind};
use super::proven::{BUNDLE, configure_proven, finalize, reference_chain, submit_links};
use super::super::{
    ISlingfallAdminDispatcherTrait, ISlingfallDispatcherTrait, ISlingfallGovernanceDispatcherTrait,
    ISlingfallProvenDispatcherTrait, ISlingfallSatelliteDispatcher,
    ISlingfallSatelliteDispatcherTrait,
};
use super::{ADMIN, AUTHOR, OTHER, PROGRAM, address, setup_at};

/// v2's `Best`, frozen with its packing (`registry.cairo` at `2625ad1`).
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct V2Best {
    pub score: u32,
    pub won: bool,
    pub inputs_hash: felt252,
    pub block: u64,
    pub timestamp: u64,
    pub settled: bool,
    pub program_hash: felt252,
}

#[derive(Copy, Drop, starknet::Store)]
pub struct V2PackedBest {
    meta: felt252,
    inputs_hash: felt252,
    program_hash: felt252,
}

pub impl V2BestStorePacking of starknet::storage_access::StorePacking<V2Best, V2PackedBest> {
    fn pack(value: V2Best) -> V2PackedBest {
        let low: u128 = value.score.into()
            + if value.won {
                0x100000000
            } else {
                0
            }
            + if value.settled {
                0x200000000
            } else {
                0
            }
            + value.block.into() * 0x400000000;
        let meta: u256 = u256 { low, high: value.timestamp.into() };
        V2PackedBest {
            meta: meta.try_into().unwrap(),
            inputs_hash: value.inputs_hash,
            program_hash: value.program_hash,
        }
    }

    fn unpack(value: V2PackedBest) -> V2Best {
        let meta: u256 = value.meta.into();
        let (block, flags) = DivRem::div_rem(meta.low, 0x400000000);
        let (settled, rest) = DivRem::div_rem(flags, 0x200000000);
        let (won, score) = DivRem::div_rem(rest, 0x100000000);
        V2Best {
            score: score.try_into().unwrap(),
            won: won != 0,
            inputs_hash: value.inputs_hash,
            block: block.try_into().unwrap(),
            timestamp: meta.high.try_into().unwrap(),
            settled: settled != 0,
            program_hash: value.program_hash,
        }
    }
}

#[starknet::interface]
pub trait IV2Storage<TState> {
    /// Writes one value of every v2 storage variable (the attempt of `reference_inputs()`
    /// attested, another settled).
    fn seed(ref self: TState);
    fn replace(ref self: TState, class_hash: starknet::ClassHash);
}

#[starknet::contract]
pub mod SlingfallV2Storage {
    use slingfall_level::level::fixtures::{PILE10_HASH, pile10_felts};
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapWriteAccess, StoragePathEntry, StoragePointerWriteAccess,
        Vec,
    };
    use starknet::{ClassHash, ContractAddress};
    use crate::registry::{Entry, LevelMeta};
    use crate::verifier::{SatelliteConfig, VerifierKind};
    use super::{V2Best, v2_values};

    // v2's storage, verbatim but for `Best` (frozen as `V2Best`).
    #[storage]
    struct Storage {
        admin: ContractAddress,
        pending_admin: ContractAddress,
        virtual_os_hash: felt252,
        sim_class_hash: ClassHash,
        verifier: VerifierKind,
        attestation_key: felt252,
        attestation_epoch: u64,
        satellite: SatelliteConfig,
        programs: Map<felt252, u64>,
        current_program: felt252,
        expire_delay: u64,
        levels: Map<felt252, LevelMeta>,
        level_felts: Map<(felt252, u32), felt252>,
        level_len: Map<felt252, u32>,
        nullifiers: Map<felt252, u8>,
        best: Map<(ContractAddress, felt252), V2Best>,
        best_settled: Map<(ContractAddress, felt252), V2Best>,
        boards_settled: Map<felt252, Vec<Entry>>,
        boards_provisional: Map<felt252, Vec<Entry>>,
    }

    #[abi(embed_v0)]
    impl V2StorageImpl of super::IV2Storage<ContractState> {
        fn seed(ref self: ContractState) {
            let v = v2_values();
            self.admin.write(v.admin);
            self.pending_admin.write(v.pending_admin);
            self.virtual_os_hash.write(v.virtual_os_hash);
            self.sim_class_hash.write(v.sim_class_hash);
            self.verifier.write(v.verifier);
            self.attestation_key.write(v.attestation_key);
            self.attestation_epoch.write(v.attestation_epoch);
            self.satellite.write(v.satellite);
            self.programs.write(v.program, v.program_valid_until);
            self.current_program.write(v.program);
            self.expire_delay.write(v.expire_delay);
            self.levels.write(PILE10_HASH, v.level);
            let mut i: u32 = 0;
            for felt in pile10_felts() {
                self.level_felts.write((PILE10_HASH, i), felt);
                i += 1;
            }
            self.level_len.write(PILE10_HASH, i);
            self.nullifiers.write(v.attested_key, 1);
            self.nullifiers.write(v.settled_key, 2);
            self.best.write((v.player, PILE10_HASH), v.best);
            self.best_settled.write((v.other, PILE10_HASH), v.best_settled);
            self
                .boards_provisional
                .entry(PILE10_HASH)
                .push(Entry { player: v.player, score: 1650 });
            self.boards_settled.entry(PILE10_HASH).push(Entry { player: v.other, score: 700 });
        }

        fn replace(ref self: ContractState, class_hash: ClassHash) {
            starknet::syscalls::replace_class_syscall(class_hash).unwrap();
        }
    }
}

/// What `seed` writes.
#[derive(Drop, Copy)]
pub struct V2Values {
    admin: ContractAddress,
    pending_admin: ContractAddress,
    virtual_os_hash: felt252,
    sim_class_hash: starknet::ClassHash,
    verifier: VerifierKind,
    attestation_key: felt252,
    attestation_epoch: u64,
    satellite: SatelliteConfig,
    program: felt252,
    program_valid_until: u64,
    expire_delay: u64,
    level: LevelMeta,
    attested_key: felt252,
    settled_key: felt252,
    player: ContractAddress,
    other: ContractAddress,
    best: V2Best,
    best_settled: V2Best,
}

pub fn v2_values() -> V2Values {
    let inputs_hash = poseidon_hash_span(reference_inputs().span());
    V2Values {
        admin: address(ADMIN),
        pending_admin: address(OTHER),
        virtual_os_hash: 0x53f6c9fc,
        sim_class_hash: 0x5117.try_into().unwrap(),
        verifier: VerifierKind::Stub,
        attestation_key: ATTESTATION_KEY,
        attestation_epoch: 3,
        satellite: SatelliteConfig {
            atlantic_bootloader_hash: 0xa,
            sharp_bootloader_hash: 0xb,
            satellite_address: address(0xc),
        },
        program: PROGRAM,
        program_valid_until: FOREVER,
        expire_delay: 3_600,
        level: LevelMeta {
            author: address(AUTHOR), version: 1, active: true, registered_at: 12_345,
        },
        attested_key: poseidon_hash_span([PILE10_HASH, PLAYER, inputs_hash].span()),
        settled_key: poseidon_hash_span([PILE10_HASH, OTHER, 0x77].span()),
        player: address(PLAYER),
        other: address(OTHER),
        best: V2Best {
            score: 1650,
            won: true,
            inputs_hash,
            block: 0x123456789,
            timestamp: 0xfedcba987,
            settled: false,
            program_hash: PROGRAM,
        },
        best_settled: V2Best {
            score: 700,
            won: true,
            inputs_hash: 0x77,
            block: 5,
            timestamp: 6,
            settled: true,
            program_hash: PROGRAM,
        },
    }
}

/// `v` as v3 reads it.
fn as_best(v: V2Best) -> Best {
    Best {
        score: v.score,
        won: v.won,
        inputs_hash: v.inputs_hash,
        block: v.block,
        timestamp: v.timestamp,
        settled: v.settled,
        program_hash: v.program_hash,
    }
}

#[test]
fn test_v2_storage_is_read_by_v3() {
    let class = declare("SlingfallV2Storage").unwrap().contract_class();
    let (contract_address, _) = class.deploy(@array![]).unwrap();
    let v2 = IV2StorageDispatcher { contract_address };
    v2.seed();
    v2.replace(*declare("Slingfall").unwrap().contract_class().class_hash);
    let setup = setup_at(contract_address);
    let v = v2_values();
    // Admin, verifier, keys, Satellite, programs.
    assert_eq!(setup.admin.admin(), v.admin);
    assert_eq!(setup.governance.pending_admin(), v.pending_admin);
    assert_eq!(setup.admin.virtual_os_hash(), v.virtual_os_hash);
    assert_eq!(setup.admin.sim_class_hash(), v.sim_class_hash);
    assert_eq!(setup.admin.verifier(), v.verifier);
    assert_eq!(setup.admin.attestation_key(), v.attestation_key);
    assert_eq!(setup.governance.attestation_epoch(), v.attestation_epoch);
    let satellite = ISlingfallSatelliteDispatcher { contract_address };
    assert_eq!(satellite.satellite_config(), v.satellite);
    assert_eq!(setup.governance.program_valid_until(v.program), v.program_valid_until);
    assert_eq!(setup.governance.current_program(), v.program);
    assert_eq!(setup.governance.expire_delay(), v.expire_delay);
    // Levels, nullifiers, records, boards.
    assert_eq!(setup.game.level(PILE10_HASH), v.level);
    assert_eq!(setup.game.level_data(PILE10_HASH), pile10_felts());
    let inputs_hash = v.best.inputs_hash;
    assert_eq!(setup.game.attempt(PILE10_HASH, v.player, inputs_hash), nullifier::ATTESTED);
    assert_eq!(setup.game.attempt(PILE10_HASH, v.other, 0x77), nullifier::SETTLED);
    assert_eq!(setup.game.best(v.player, PILE10_HASH), as_best(v.best));
    assert_eq!(setup.game.best_settled(v.other, PILE10_HASH), as_best(v.best_settled));
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![(v.player, 1650)]);
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(v.other, 700)]);
    // v3's own storage starts empty: no SNIP-36 tier until the admin configures it.
    let p = super::proven::proven_of(setup);
    assert_eq!((p.proven.chunk_marker(), p.proven.current_virtual_os()), (0, 0));
    assert_eq!(p.proven.current_chain(), address(0));
    // Configured, v3 proves the attempt v2 attested: the record is marked settled in place.
    let p = configure_proven(setup);
    let chain = reference_chain(2);
    submit_links(p, @chain);
    finalize(p, @chain);
    assert_eq!(setup.game.attempt(PILE10_HASH, v.player, inputs_hash), nullifier::PROVEN);
    let expected = Best { settled: true, program_hash: BUNDLE, ..as_best(v.best) };
    assert_eq!(setup.game.best(v.player, PILE10_HASH), expected);
    let expected = Best { block: 110, timestamp: 0, ..expected };
    assert_eq!(setup.game.best_settled(v.player, PILE10_HASH), expected);
}
