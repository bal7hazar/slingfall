//! Governance and the attack surface of research 06 §2: the two-step admin transfer, `upgrade`,
//! attestation replays (another contract, chain, epoch, program, after expiry), the relayed
//! settlement and the race on the nullifier.

use slingfall_level::level::fixtures::PILE10_HASH;
use slingfall_level::outputs::{Outputs, OutputsTrait};
use snforge_std::{
    DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events, start_cheat_block_timestamp,
};
use crate::submit::fixtures::{
    ATTESTATION_KEY, ATTEST_CHAIN_ID, ATTEST_EXPIRY, PILE10_INTEGRITY_FACT, PLAYER, golden_claim,
    reference_args, reference_outputs,
};
use crate::submit::nullifier;
use super::settled::{
    IFakeSatelliteDispatcherTrait, reference_claim, reference_settled, setup_settled,
};
use super::super::{
    ISlingfallAdminDispatcherTrait, ISlingfallAdminSafeDispatcher,
    ISlingfallAdminSafeDispatcherTrait, ISlingfallDispatcherTrait,
    ISlingfallGovernanceDispatcherTrait, ISlingfallGovernanceSafeDispatcherTrait,
    ISlingfallSafeDispatcherTrait, Slingfall,
};
use super::{ADMIN, OTHER, PROGRAM, address, as_caller, attest, deploy, panic_of, setup_stub, sign};

/// The class `upgrade` installs in the test: one entry point.
#[starknet::interface]
pub trait INextVersion<TState> {
    fn version(self: @TState) -> felt252;
}

#[starknet::contract]
pub mod NextVersion {
    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl NextVersionImpl of super::INextVersion<ContractState> {
        fn version(self: @ContractState) -> felt252 {
            'v3'
        }
    }
}

#[test]
#[feature("safe_dispatcher")]
fn test_two_step_admin_transfer() {
    let setup = deploy();
    let admin_safe = ISlingfallAdminSafeDispatcher { contract_address: setup.address };
    let mut spy = spy_events();
    as_caller(setup, ADMIN);
    setup.admin.set_admin(address(OTHER));
    assert_eq!(setup.governance.pending_admin(), address(OTHER));
    // Proposed is not admin yet; nobody else can accept.
    assert_eq!(setup.admin.admin(), address(ADMIN));
    as_caller(setup, OTHER);
    assert_eq!(panic_of(setup.governance_safe.pin_program(PROGRAM, 0)), 'admin: caller');
    as_caller(setup, PLAYER);
    assert_eq!(panic_of(setup.governance_safe.accept_admin()), 'admin: pending');
    as_caller(setup, OTHER);
    setup.governance.accept_admin();
    assert_eq!(setup.admin.admin(), address(OTHER));
    assert_eq!(setup.governance.pending_admin(), 0.try_into().unwrap());
    assert_eq!(panic_of(setup.governance_safe.accept_admin()), 'admin: pending');
    as_caller(setup, ADMIN);
    assert_eq!(panic_of(admin_safe.set_admin(address(ADMIN))), 'admin: caller');
    let started = Slingfall::AdminTransferStarted {
        admin: address(ADMIN), pending: address(OTHER),
    };
    let transferred = Slingfall::AdminTransferred {
        previous: address(ADMIN), admin: address(OTHER),
    };
    spy
        .assert_emitted(
            @array![
                (setup.address, Slingfall::Event::AdminTransferStarted(started)),
                (setup.address, Slingfall::Event::AdminTransferred(transferred)),
            ],
        );
}

/// Proposing another address replaces the pending one; proposing oneself cancels.
#[test]
#[feature("safe_dispatcher")]
fn test_admin_transfer_cancelled() {
    let setup = deploy();
    as_caller(setup, ADMIN);
    setup.admin.set_admin(address(OTHER));
    setup.admin.set_admin(address(PLAYER));
    as_caller(setup, OTHER);
    assert_eq!(panic_of(setup.governance_safe.accept_admin()), 'admin: pending');
    as_caller(setup, ADMIN);
    setup.admin.set_admin(address(ADMIN));
    as_caller(setup, PLAYER);
    assert_eq!(panic_of(setup.governance_safe.accept_admin()), 'admin: pending');
    assert_eq!(setup.admin.admin(), address(ADMIN));
}

#[test]
#[feature("safe_dispatcher")]
fn test_upgrade() {
    let setup = setup_stub();
    let class_hash = *declare("NextVersion").unwrap().contract_class().class_hash;
    as_caller(setup, OTHER);
    assert_eq!(panic_of(setup.governance_safe.upgrade(class_hash)), 'admin: caller');
    as_caller(setup, ADMIN);
    assert_eq!(panic_of(setup.governance_safe.upgrade(0.try_into().unwrap())), 'upgrade: zero');
    let mut spy = spy_events();
    setup.governance.upgrade(class_hash);
    spy
        .assert_emitted(
            @array![
                (setup.address, Slingfall::Event::Upgraded(Slingfall::Upgraded { class_hash })),
            ],
        );
    // The address now runs the new class.
    assert_eq!(INextVersionDispatcher { contract_address: setup.address }.version(), 'v3');
}

/// A second deployment sharing the key.
fn second(key: felt252) -> super::Setup {
    let setup = setup_stub();
    as_caller(setup, ADMIN);
    setup.admin.set_attestation_key(key);
    as_caller(setup, PLAYER);
    setup
}

/// An attestation for one deployment, chain, epoch, program or time is refused everywhere else.
#[test]
#[feature("safe_dispatcher")]
fn test_attestation_replays_rejected() {
    let setup = setup_stub();
    let other = second(ATTESTATION_KEY);
    let claim = golden_claim();
    let felts = claim.to_felts();
    // Another contract (its own attestation is accepted there).
    let evidence = attest(claim, ATTEST_CHAIN_ID, other.address, PROGRAM, 1, ATTEST_EXPIRY);
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), evidence)), 'submit: proof');
    // Another chain.
    let evidence = attest(claim, 'SN_MAIN', setup.address, PROGRAM, 1, ATTEST_EXPIRY);
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), evidence)), 'submit: proof');
    // After expiry (the program still current).
    start_cheat_block_timestamp(setup.address, ATTEST_EXPIRY);
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), sign(setup, claim))), 'submit: proof');
    start_cheat_block_timestamp(setup.address, 0);
    // Another program: signed for a valid one, presented as another valid one.
    as_caller(setup, ADMIN);
    setup.governance.pin_program(PROGRAM + 1, 3_600);
    as_caller(setup, PLAYER);
    let signed = attest(claim, ATTEST_CHAIN_ID, setup.address, PROGRAM + 1, 1, ATTEST_EXPIRY);
    let swapped = array![PROGRAM, *signed[1], *signed[2], *signed[3]];
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), swapped)), 'submit: proof');
    // Another epoch: rotating to the same key bumps it and voids every earlier signature.
    let before = sign(setup, claim);
    as_caller(setup, ADMIN);
    let mut spy = spy_events();
    setup.admin.set_attestation_key(ATTESTATION_KEY);
    assert_eq!(setup.governance.attestation_epoch(), 2);
    let event = Slingfall::AttestationKeySet { attestation_key: ATTESTATION_KEY, epoch: 2 };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::AttestationKeySet(event))]);
    as_caller(setup, PLAYER);
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), before)), 'submit: proof');
    let now = attest(claim, ATTEST_CHAIN_ID, setup.address, PROGRAM, 2, ATTEST_EXPIRY);
    setup.game.submit(felts.clone(), now);
    // The other deployment accepts its own.
    let evidence = attest(claim, ATTEST_CHAIN_ID, other.address, PROGRAM, 2, ATTEST_EXPIRY);
    other.game.submit(felts, evidence);
}

/// A third party settles the player's proven attempt: the record is the player's.
#[test]
fn test_relayed_settle_by_a_third_party() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    as_caller(setup, OTHER);
    let mut spy = spy_events();
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    let player = address(PLAYER);
    assert_eq!(setup.game.best_settled(player, PILE10_HASH), reference_settled());
    assert_eq!(setup.game.best(address(OTHER), PILE10_HASH).score, 0);
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(player, 5200)]);
    let event = Slingfall::LevelValidated {
        player,
        level_hash: PILE10_HASH,
        inputs_hash: reference_claim().inputs_hash,
        score: 5200,
        won: true,
        settled: true,
        program_hash: PROGRAM,
    };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::LevelValidated(event))]);
}

/// A relay settles the attested attempt of the player (the upgrade path works relayed too).
#[test]
fn test_relayed_settle_upgrades_the_attested_attempt() {
    let (setup, fake) = setup_settled();
    setup.game.submit(reference_outputs(), sign(setup, reference_claim()));
    fake.register(PILE10_INTEGRITY_FACT);
    as_caller(setup, OTHER);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    let best = setup.game.best(address(PLAYER), PILE10_HASH);
    assert!(best.settled);
}

/// Player and relay race: whoever comes second reverts on the nullifier.
#[test]
#[feature("safe_dispatcher")]
fn test_race_loser_reverts_on_the_nullifier() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    as_caller(setup, OTHER);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    as_caller(setup, PLAYER);
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)),
        'submit: nullifier',
    );
    // The other way round on a fresh deployment.
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    as_caller(setup, OTHER);
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)),
        'submit: nullifier',
    );
    let inputs_hash = reference_claim().inputs_hash;
    assert_eq!(setup.game.attempt(PILE10_HASH, address(PLAYER), inputs_hash), nullifier::SETTLED);
}

/// The attested tier still binds the caller: a relay cannot submit someone's attestation.
#[test]
#[feature("safe_dispatcher")]
fn test_attested_submit_is_not_relayable() {
    let setup = setup_stub();
    let claim = golden_claim();
    as_caller(setup, OTHER);
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), sign(setup, claim))), 'submit: player');
}

/// A claimed player that is not an address (over 2^251) cannot be recorded.
#[test]
#[feature("safe_dispatcher")]
fn test_settle_rejects_a_player_that_is_not_an_address() {
    let (setup, _) = setup_settled();
    let outputs = Outputs { player: -1, ..reference_claim() }.to_felts();
    let args = reference_args();
    assert_eq!(panic_of(setup.safe.submit_settled(outputs, args, PROGRAM)), 'submit: player');
}
