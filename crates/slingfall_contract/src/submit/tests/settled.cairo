//! The settled tier: `SatelliteVerifier` on the deployed contract against `FakeSatellite` (a
//! registry of facts, so the test checks the exact fact queried), the E3a runs as vectors, the
//! upgrade of an attested attempt and the constants. The helpers are shared with `tiers`,
//! `programs` and `governance`.

use slingfall_level::level::fixtures::{ONE_BLOCK_HASH, PILE10_HASH, one_block_felts};
use slingfall_level::outputs::{Outputs, OutputsTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events,
};
use starknet::ContractAddress;
use crate::registry::Best;
use crate::submit::nullifier;
use crate::verifier::{SatelliteConfig, VerifierKind};
use super::super::fixtures::{
    ATLANTIC_BOOTLOADER_HASH, ONE_BLOCK_INTEGRITY_FACT, PILE10_INTEGRITY_FACT, PILE10_SHARP_FACT,
    PLAYER, SHARP_BOOTLOADER_HASH, one_block_miss_args, one_block_miss_outputs, reference_args,
    reference_outputs,
};
use super::super::{
    ISlingfallAdminDispatcherTrait, ISlingfallDispatcherTrait, ISlingfallGovernanceDispatcherTrait,
    ISlingfallSafeDispatcherTrait, ISlingfallSatelliteDispatcher,
    ISlingfallSatelliteDispatcherTrait, ISlingfallSatelliteSafeDispatcher,
    ISlingfallSatelliteSafeDispatcherTrait, Slingfall,
};
use super::{ADMIN, OTHER, PROGRAM, Setup, address, as_caller, panic_of, setup_stub, sign};

/// A Satellite that knows the facts it is told (`register`); `false` for everything else, and
/// always `false` for mocked facts.
#[starknet::interface]
pub trait IFakeSatellite<TState> {
    fn register(ref self: TState, fact_hash: felt252);
    fn register_keccak(ref self: TState, fact_hash: u256);
    fn isCairoFactValid(self: @TState, fact_hash: felt252, is_mocked: bool) -> bool;
    fn isKeccakVerifiedFactHashValid(self: @TState, fact_hash: u256) -> bool;
}

#[starknet::contract]
pub mod FakeSatellite {
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        facts: Map<felt252, bool>,
        keccak_facts: Map<u256, bool>,
    }

    #[abi(embed_v0)]
    impl FakeSatelliteImpl of super::IFakeSatellite<ContractState> {
        fn register(ref self: ContractState, fact_hash: felt252) {
            self.facts.write(fact_hash, true);
        }

        fn register_keccak(ref self: ContractState, fact_hash: u256) {
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

fn satellite_admin(setup: Setup) -> ISlingfallSatelliteDispatcher {
    ISlingfallSatelliteDispatcher { contract_address: setup.address }
}

fn satellite() -> IFakeSatelliteDispatcher {
    let class = declare("FakeSatellite").unwrap().contract_class();
    let (contract_address, _) = class.deploy(@array![]).unwrap();
    IFakeSatelliteDispatcher { contract_address }
}

fn config(satellite: ContractAddress) -> SatelliteConfig {
    SatelliteConfig {
        atlantic_bootloader_hash: ATLANTIC_BOOTLOADER_HASH,
        sharp_bootloader_hash: SHARP_BOOTLOADER_HASH,
        satellite_address: satellite,
    }
}

/// `setup_stub()` (pile10, the attestation key, `PROGRAM` pinned) plus one_block, the E3a
/// constants and an empty `FakeSatellite`; the caller left to `PLAYER`.
pub fn setup_settled() -> (Setup, IFakeSatelliteDispatcher) {
    let setup = setup_stub();
    let fake = satellite();
    setup.game.register_level(one_block_felts());
    as_caller(setup, ADMIN);
    satellite_admin(setup).set_satellite_config(config(fake.contract_address));
    as_caller(setup, PLAYER);
    (setup, fake)
}

pub fn reference_claim() -> Outputs {
    OutputsTrait::from_felts(reference_outputs().span())
}

/// The settled `Best` of the pile10 reference run at block and timestamp 0.
pub fn reference_settled() -> Best {
    Best {
        score: 5200,
        won: true,
        inputs_hash: reference_claim().inputs_hash,
        block: 0,
        timestamp: 0,
        settled: true,
        program_hash: PROGRAM,
    }
}

#[test]
fn test_settled_accepts_the_e3a_fact() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    let mut spy = spy_events();
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    let claim = reference_claim();
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH), reference_settled());
    assert_eq!(setup.game.best_settled(address(PLAYER), PILE10_HASH), reference_settled());
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(address(PLAYER), 5200)]);
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![(address(PLAYER), 5200)]);
    assert_eq!(
        setup.game.attempt(PILE10_HASH, address(PLAYER), claim.inputs_hash), nullifier::SETTLED,
    );
    let event = Slingfall::LevelValidated {
        player: address(PLAYER),
        level_hash: PILE10_HASH,
        inputs_hash: claim.inputs_hash,
        score: 5200,
        won: true,
        settled: true,
        program_hash: PROGRAM,
        proven: false,
    };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::LevelValidated(event))]);
    // The other E3a run (a lost attempt: no record, the nullifier is spent).
    fake.register(ONE_BLOCK_INTEGRITY_FACT);
    setup.game.submit_settled(one_block_miss_outputs(), one_block_miss_args(), PROGRAM);
    let miss = OutputsTrait::from_felts(one_block_miss_outputs().span());
    assert_eq!(
        setup.game.attempt(ONE_BLOCK_HASH, address(PLAYER), miss.inputs_hash), nullifier::SETTLED,
    );
}

/// The bridged keccak fact alone (Atlantic's translation stalls, `docs/proving.md`).
#[test]
fn test_settled_accepts_the_bridged_keccak_fact() {
    let (setup, fake) = setup_settled();
    fake.register_keccak(PILE10_SHARP_FACT);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    assert!(setup.game.best(address(PLAYER), PILE10_HASH).settled);
}

/// `verifier = Satellite` closes `submit` (the run's argument is no evidence there any more) and
/// leaves `submit_settled` open.
#[test]
#[feature("safe_dispatcher")]
fn test_satellite_verifier_leaves_only_submit_settled() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    as_caller(setup, ADMIN);
    setup.admin.set_verifier(VerifierKind::Satellite);
    as_caller(setup, PLAYER);
    let claim = reference_claim();
    let attested = sign(setup, claim);
    assert_eq!(panic_of(setup.safe.submit(reference_outputs(), attested)), 'submit: proof');
    assert_eq!(panic_of(setup.safe.submit(reference_outputs(), reference_args())), 'submit: proof');
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    assert!(setup.game.best(address(PLAYER), PILE10_HASH).settled);
}

/// Both tiers with no `set_verifier`: the constructor's attestation and the Satellite.
#[test]
fn test_both_tiers_coexist_without_a_verifier_switch() {
    let (setup, fake) = setup_settled();
    assert_eq!(setup.admin.verifier(), VerifierKind::Stub);
    let claim = reference_claim();
    setup.game.submit(reference_outputs(), sign(setup, claim));
    let other = Outputs { inputs_hash: 0x1, ..claim };
    setup.game.submit(other.to_felts(), sign(setup, other));
    fake.register(PILE10_INTEGRITY_FACT);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    assert_eq!(
        setup.game.attempt(PILE10_HASH, address(PLAYER), claim.inputs_hash), nullifier::SETTLED,
    );
    assert_eq!(setup.game.attempt(PILE10_HASH, address(PLAYER), 0x1), nullifier::ATTESTED);
}

/// Attested, then settled by a second submission of the same attempt; nothing else is admitted.
#[test]
#[feature("safe_dispatcher")]
fn test_attested_attempt_upgrades_to_settled() {
    let (setup, fake) = setup_settled();
    let claim = reference_claim();
    setup.game.submit(reference_outputs(), sign(setup, claim));
    let record = setup.game.best(address(PLAYER), PILE10_HASH);
    assert!(!record.settled);
    assert_eq!(
        setup.game.attempt(PILE10_HASH, address(PLAYER), claim.inputs_hash), nullifier::ATTESTED,
    );
    // Attested twice: refused.
    let attested = sign(setup, claim);
    assert_eq!(panic_of(setup.safe.submit(reference_outputs(), attested)), 'submit: nullifier');
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![]);
    // No fact yet: refused, the attempt stays attested.
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)), 'submit: proof',
    );
    fake.register(PILE10_INTEGRITY_FACT);
    let mut spy = spy_events();
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH), Best { settled: true, ..record });
    assert_eq!(setup.game.best_settled(address(PLAYER), PILE10_HASH), reference_settled());
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(address(PLAYER), 5200)]);
    let event = Slingfall::LevelValidated {
        player: address(PLAYER),
        level_hash: PILE10_HASH,
        inputs_hash: claim.inputs_hash,
        score: 5200,
        won: true,
        settled: true,
        program_hash: PROGRAM,
        proven: false,
    };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::LevelValidated(event))]);
    // Settled: neither tier again.
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), reference_args(), PROGRAM)),
        'submit: nullifier',
    );
    let attested = sign(setup, claim);
    assert_eq!(panic_of(setup.safe.submit(reference_outputs(), attested)), 'submit: nullifier');
}

/// Settling an attested attempt that is not the best record leaves the record as it is.
#[test]
fn test_upgrade_of_a_non_best_attempt_keeps_the_record() {
    let (setup, fake) = setup_settled();
    let claim = reference_claim();
    // The reference attempt is attested, then a better (attested) one becomes the record.
    setup.game.submit(reference_outputs(), sign(setup, claim));
    let better = Outputs { inputs_hash: 0xbe77e1, score: 9_000, ..claim };
    setup.game.submit(better.to_felts(), sign(setup, better));
    fake.register(PILE10_INTEGRITY_FACT);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    let record = setup.game.best(address(PLAYER), PILE10_HASH);
    assert_eq!((record.score, record.inputs_hash, record.settled), (9_000, 0xbe77e1, false));
    assert_eq!(
        setup.game.attempt(PILE10_HASH, address(PLAYER), claim.inputs_hash), nullifier::SETTLED,
    );
}

#[test]
#[feature("safe_dispatcher")]
fn test_settled_rejects_wrong_constants_and_runs() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    fake.register_keccak(PILE10_SHARP_FACT);
    let good = config(fake.contract_address);
    let other = satellite();
    // Each constant wrong (or unset) in turn.
    let configs: Array<SatelliteConfig> = array![
        SatelliteConfig { atlantic_bootloader_hash: ATLANTIC_BOOTLOADER_HASH + 1, ..good },
        SatelliteConfig { satellite_address: other.contract_address, ..good },
        SatelliteConfig { atlantic_bootloader_hash: 0, ..good },
        SatelliteConfig { sharp_bootloader_hash: 0, ..good },
        SatelliteConfig { satellite_address: 0.try_into().unwrap(), ..good },
    ];
    for bad in configs {
        as_caller(setup, ADMIN);
        satellite_admin(setup).set_satellite_config(bad);
        as_caller(setup, PLAYER);
        assert_eq!(
            panic_of(setup.safe.submit_settled(reference_outputs(), reference_args(), PROGRAM)),
            'submit: proof',
        );
    }
    // A wrong SHARP bootloader hash only moves the translated fact: rejected by a Satellite that
    // has only that one.
    let poseidon_only = satellite();
    poseidon_only.register(PILE10_INTEGRITY_FACT);
    as_caller(setup, ADMIN);
    satellite_admin(setup)
        .set_satellite_config(
            SatelliteConfig {
                sharp_bootloader_hash: SHARP_BOOTLOADER_HASH + 1,
                satellite_address: poseidon_only.contract_address,
                ..good,
            },
        );
    as_caller(setup, PLAYER);
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)), 'submit: proof',
    );
    // The right constants, the wrong run: other inputs, another claim, another program (valid in
    // the set, but not the one the fact was proven with).
    as_caller(setup, ADMIN);
    satellite_admin(setup).set_satellite_config(good);
    setup.governance.pin_program(PROGRAM + 1, 3_600);
    as_caller(setup, PLAYER);
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), one_block_miss_args(), PROGRAM)),
        'submit: proof',
    );
    let inflated = Outputs { score: 9_999, ..reference_claim() }.to_felts();
    assert_eq!(
        panic_of(setup.safe.submit_settled(inflated, reference_args(), PROGRAM)), 'submit: proof',
    );
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM + 1)),
        'submit: proof',
    );
    // Then accepted (the former program, in its grace period).
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
}

#[test]
#[feature("safe_dispatcher")]
fn test_satellite_config_is_admin_only() {
    let (setup, fake) = setup_settled();
    let safe = ISlingfallSatelliteSafeDispatcher { contract_address: setup.address };
    assert_eq!(satellite_admin(setup).satellite_config(), config(fake.contract_address));
    as_caller(setup, OTHER);
    assert_eq!(panic_of(safe.set_satellite_config(config(fake.contract_address))), 'admin: caller');
}

/// Setup of the `steps_submit_settled__*` probes without the submission.
#[test]
fn steps_submit_settled__setup() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    fake.register_keccak(PILE10_SHARP_FACT);
    let _ = (reference_outputs(), reference_args(), setup);
}

/// `submit_settled(pile10 reference)`, the translated fact on the Satellite (one Poseidon).
#[test]
fn steps_submit_settled__pile10_integrity() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    fake.register_keccak(PILE10_SHARP_FACT);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
}

/// `submit_settled(pile10 reference)`, only the bridged keccak fact (the Poseidon read fails,
/// then the Keccak).
#[test]
fn steps_submit_settled__pile10_keccak() {
    let (setup, fake) = setup_settled();
    fake.register_keccak(PILE10_SHARP_FACT);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
}
