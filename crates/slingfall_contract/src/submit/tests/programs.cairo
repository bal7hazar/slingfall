//! The program set (M7): `pin_program` with a grace period, `revoke_program`, and both tiers
//! refusing a program that is not valid now (never pinned, past its grace, revoked).

use slingfall_level::level::fixtures::PILE10_HASH;
use slingfall_level::outputs::OutputsTrait;
use snforge_std::{EventSpyAssertionsTrait, spy_events, start_cheat_block_timestamp};
use crate::submit::FOREVER;
use crate::submit::fixtures::{
    ATTEST_CHAIN_ID, ATTEST_EXPIRY, PILE10_INTEGRITY_FACT, PLAYER, golden_claim, reference_args,
    reference_outputs,
};
use super::settled::{IFakeSatelliteDispatcherTrait, reference_claim, setup_settled};
use super::super::{
    ISlingfallDispatcherTrait, ISlingfallGovernanceDispatcherTrait,
    ISlingfallGovernanceSafeDispatcherTrait, ISlingfallSafeDispatcherTrait, Slingfall,
};
use super::{ADMIN, OTHER, PROGRAM, address, as_caller, attest, deploy, panic_of, setup_stub, sign};

const NEXT: felt252 = PROGRAM + 1;

#[test]
fn test_pin_program_keeps_the_previous_for_the_grace_period() {
    let setup = deploy();
    assert_eq!(setup.governance.current_program(), 0);
    assert_eq!(setup.governance.program_valid_until(PROGRAM), 0);
    let mut spy = spy_events();
    start_cheat_block_timestamp(setup.address, 1_000);
    as_caller(setup, ADMIN);
    setup.governance.pin_program(PROGRAM, 3_600);
    assert_eq!(setup.governance.current_program(), PROGRAM);
    assert_eq!(setup.governance.program_valid_until(PROGRAM), FOREVER);
    setup.governance.pin_program(NEXT, 3_600);
    assert_eq!(setup.governance.current_program(), NEXT);
    assert_eq!(setup.governance.program_valid_until(NEXT), FOREVER);
    assert_eq!(setup.governance.program_valid_until(PROGRAM), 4_600);
    // Re-pinning the current program changes nothing else.
    setup.governance.pin_program(NEXT, 0);
    assert_eq!(setup.governance.program_valid_until(PROGRAM), 4_600);
    let events = array![
        Slingfall::ProgramPinned { program_hash: PROGRAM, previous: 0, previous_valid_until: 0 },
        Slingfall::ProgramPinned {
            program_hash: NEXT, previous: PROGRAM, previous_valid_until: 4_600,
        },
        Slingfall::ProgramPinned { program_hash: NEXT, previous: 0, previous_valid_until: 0 },
    ];
    for event in events {
        spy.assert_emitted(@array![(setup.address, Slingfall::Event::ProgramPinned(event))]);
    }
    // A former program pinned again is current again.
    setup.governance.pin_program(PROGRAM, 0);
    assert_eq!(setup.governance.program_valid_until(PROGRAM), FOREVER);
    assert_eq!(setup.governance.program_valid_until(NEXT), 1_000);
}

#[test]
fn test_pin_program_grace_saturates() {
    let setup = deploy();
    start_cheat_block_timestamp(setup.address, 1_000);
    as_caller(setup, ADMIN);
    setup.governance.pin_program(PROGRAM, 0);
    setup.governance.pin_program(NEXT, FOREVER);
    assert_eq!(setup.governance.program_valid_until(PROGRAM), FOREVER - 1);
}

#[test]
fn test_revoke_program() {
    let setup = deploy();
    as_caller(setup, ADMIN);
    setup.governance.pin_program(PROGRAM, 0);
    setup.governance.pin_program(NEXT, 3_600);
    let mut spy = spy_events();
    setup.governance.revoke_program(PROGRAM);
    assert_eq!(setup.governance.program_valid_until(PROGRAM), 0);
    assert_eq!(setup.governance.current_program(), NEXT);
    setup.governance.revoke_program(NEXT);
    assert_eq!(setup.governance.program_valid_until(NEXT), 0);
    assert_eq!(setup.governance.current_program(), 0);
    let event = Slingfall::ProgramRevoked { program_hash: NEXT };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::ProgramRevoked(event))]);
}

#[test]
#[feature("safe_dispatcher")]
fn test_program_admin_rejects() {
    let setup = deploy();
    as_caller(setup, ADMIN);
    assert_eq!(panic_of(setup.governance_safe.pin_program(0, 0)), 'program: zero');
    as_caller(setup, OTHER);
    assert_eq!(panic_of(setup.governance_safe.pin_program(PROGRAM, 0)), 'admin: caller');
    assert_eq!(panic_of(setup.governance_safe.revoke_program(PROGRAM)), 'admin: caller');
}

/// A settlement with a former program: accepted before `valid_until`, refused from it on.
#[test]
#[feature("safe_dispatcher")]
fn test_settled_stale_program_after_grace() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    start_cheat_block_timestamp(setup.address, 1_000);
    as_caller(setup, ADMIN);
    setup.governance.pin_program(NEXT, 100);
    as_caller(setup, OTHER);
    start_cheat_block_timestamp(setup.address, 1_100);
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)), 'submit: program',
    );
    start_cheat_block_timestamp(setup.address, 1_099);
    setup.game.submit_settled(reference_outputs(), reference_args(), PROGRAM);
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH).program_hash, PROGRAM);
}

/// An attestation naming a former program: the same rule.
#[test]
#[feature("safe_dispatcher")]
fn test_attested_stale_program_after_grace() {
    let setup = setup_stub();
    start_cheat_block_timestamp(setup.address, 1_000);
    as_caller(setup, ADMIN);
    setup.governance.pin_program(NEXT, 100);
    as_caller(setup, PLAYER);
    let claim = golden_claim();
    start_cheat_block_timestamp(setup.address, 1_100);
    assert_eq!(
        panic_of(setup.safe.submit(claim.to_felts(), sign(setup, claim))), 'submit: program',
    );
    start_cheat_block_timestamp(setup.address, 1_099);
    setup.game.submit(claim.to_felts(), sign(setup, claim));
}

/// `grace_s = 0` (a fix of an exploitable defect): the former program is refused at once.
#[test]
#[feature("safe_dispatcher")]
fn test_zero_grace_refuses_at_once() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    as_caller(setup, ADMIN);
    setup.governance.pin_program(NEXT, 0);
    as_caller(setup, PLAYER);
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)), 'submit: program',
    );
    let claim = golden_claim();
    assert_eq!(
        panic_of(setup.safe.submit(claim.to_felts(), sign(setup, claim))), 'submit: program',
    );
}

/// A revoked program (current or in its grace period) and one never pinned are refused by both
/// tiers.
#[test]
#[feature("safe_dispatcher")]
fn test_revoked_and_unknown_programs_rejected() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    let claim = golden_claim();
    // Never pinned.
    let unknown = attest(claim, ATTEST_CHAIN_ID, setup.address, NEXT, 1, ATTEST_EXPIRY);
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), unknown)), 'submit: program');
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, NEXT)), 'submit: program',
    );
    // Revoked while current.
    as_caller(setup, ADMIN);
    setup.governance.revoke_program(PROGRAM);
    as_caller(setup, PLAYER);
    assert_eq!(
        panic_of(setup.safe.submit(claim.to_felts(), sign(setup, claim))), 'submit: program',
    );
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)), 'submit: program',
    );
    // Revoked during its grace period.
    as_caller(setup, ADMIN);
    setup.governance.pin_program(PROGRAM, 0);
    setup.governance.pin_program(NEXT, 3_600);
    as_caller(setup, PLAYER);
    setup.game.submit(claim.to_felts(), sign(setup, claim));
    as_caller(setup, ADMIN);
    setup.governance.revoke_program(PROGRAM);
    as_caller(setup, PLAYER);
    let args = reference_args();
    assert_eq!(
        panic_of(setup.safe.submit_settled(reference_outputs(), args, PROGRAM)), 'submit: program',
    );
    // Nothing was recorded by the refused settlements.
    let inputs_hash = reference_claim().inputs_hash;
    assert_eq!(setup.game.attempt(PILE10_HASH, address(PLAYER), inputs_hash), 0);
}
