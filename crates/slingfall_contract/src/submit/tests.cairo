//! Contract tests of `Slingfall`: deployed in snforge, called through the (safe) dispatchers,
//! `snforge_std` cheatcodes for the caller, the block, the proof facts, events and L1 messages.

use slingfall_level::hash::to_felts;
use slingfall_level::inputs::{Inputs, InputsTrait, Shot};
use slingfall_level::outputs::{Outputs, OutputsTrait};
use snforge_std::signature::KeyPairTrait;
use snforge_std::signature::stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, MessageToL1,
    MessageToL1SpyAssertionsTrait, declare, spy_events, spy_messages_to_l1,
    start_cheat_block_number, start_cheat_block_timestamp, start_cheat_caller_address,
    start_cheat_proof_facts,
};
use starknet::ContractAddress;
use crate::registry::{LEADERBOARD_SIZE, LevelMeta, Record};
use crate::simulate::MARKER;
use crate::verifier::{VerifierKind, attestation_hash, message_hash};
use super::fixtures::{
    ATTESTATION_KEY, GOLDEN_R, GOLDEN_S, ONE_BLOCK_HASH, PILE10_HASH, PLAYER, SECRET, golden_claim,
    one_block_felts, pile10_felts,
};
use super::{
    ISlingfallAdminDispatcher, ISlingfallAdminDispatcherTrait, ISlingfallAdminSafeDispatcher,
    ISlingfallAdminSafeDispatcherTrait, ISlingfallDispatcher, ISlingfallDispatcherTrait,
    ISlingfallSafeDispatcher, ISlingfallSafeDispatcherTrait, Slingfall,
};

const ADMIN: felt252 = 'admin';
const AUTHOR: felt252 = 'author';
const OTHER: felt252 = 'other';
const VIRTUAL_OS_HASH: felt252 = 0x53f6c9fc;

fn address(value: felt252) -> ContractAddress {
    value.try_into().unwrap()
}

#[derive(Drop, Copy)]
struct Setup {
    address: ContractAddress,
    game: ISlingfallDispatcher,
    safe: ISlingfallSafeDispatcher,
    admin: ISlingfallAdminDispatcher,
}

fn deploy() -> Setup {
    let class = declare("Slingfall").unwrap().contract_class();
    let (address, _) = class.deploy(@array![ADMIN]).unwrap();
    Setup {
        address,
        game: ISlingfallDispatcher { contract_address: address },
        safe: ISlingfallSafeDispatcher { contract_address: address },
        admin: ISlingfallAdminDispatcher { contract_address: address },
    }
}

/// Makes `caller` the caller of every following call to the contract.
fn as_caller(setup: Setup, caller: felt252) {
    start_cheat_caller_address(setup.address, address(caller));
}

/// Deployed, `pile10` registered by `AUTHOR`, the stub verifier on `ATTESTATION_KEY`, the caller
/// left to `PLAYER`.
fn setup_stub() -> Setup {
    let setup = deploy();
    as_caller(setup, AUTHOR);
    setup.game.register_level(pile10_felts());
    as_caller(setup, ADMIN);
    setup.admin.set_verifier(VerifierKind::Stub);
    setup.admin.set_attestation_key(ATTESTATION_KEY);
    as_caller(setup, PLAYER);
    setup
}

/// `[r, s]` of `SECRET` over the claim's attestation hash (snforge's Stark-curve signer).
fn sign(claim: Outputs) -> Array<felt252> {
    let key_pair = KeyPairTrait::<felt252, felt252>::from_secret_key(SECRET);
    let (r, s) = key_pair.sign(attestation_hash(claim.to_felts().span())).unwrap();
    array![r, s]
}

/// A claim of `player` on pile10 with the given attempt id (its `inputs_hash`), score and win.
fn claim(player: felt252, inputs_hash: felt252, score: u32, won: bool) -> Outputs {
    Outputs { player, inputs_hash, score, won, ..golden_claim() }
}

fn submit(setup: Setup, claim: Outputs) {
    as_caller(setup, claim.player);
    setup.game.submit(claim.to_felts(), sign(claim));
}

/// The first felt of a failed call's panic data.
fn panic_of<T, +Drop<T>>(result: Result<T, Array<felt252>>) -> felt252 {
    match result {
        Result::Ok(_) => panic!("expected a panic"),
        Result::Err(data) => *data[0],
    }
}

#[test]
fn test_register_and_read() {
    let setup = deploy();
    let mut spy = spy_events();
    start_cheat_block_timestamp(setup.address, 1_000);
    as_caller(setup, AUTHOR);
    assert_eq!(setup.game.register_level(pile10_felts()), PILE10_HASH);
    let expected = LevelMeta {
        author: address(AUTHOR), version: 1, active: true, registered_at: 1_000,
    };
    assert_eq!(setup.game.level(PILE10_HASH), expected);
    assert_eq!(setup.game.level_data(PILE10_HASH), pile10_felts());
    let event = Slingfall::LevelRegistered { level_hash: PILE10_HASH, author: address(AUTHOR) };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::LevelRegistered(event))]);
    // A second level, and an unknown hash reads as zero.
    assert_eq!(setup.game.register_level(one_block_felts()), ONE_BLOCK_HASH);
    assert_eq!(setup.game.level(ONE_BLOCK_HASH).version, 1);
    assert_eq!(setup.game.level(0x1234).version, 0);
    assert_eq!(setup.game.level_data(0x1234), array![]);
}

#[test]
#[feature("safe_dispatcher")]
fn test_register_rejects() {
    let setup = deploy();
    setup.game.register_level(pile10_felts());
    assert_eq!(panic_of(setup.safe.register_level(pile10_felts())), 'register: exists');
    let mut trailing = one_block_felts();
    trailing.append(0);
    assert_eq!(panic_of(setup.safe.register_level(trailing)), 'register: felts');
    let mut truncated = one_block_felts();
    let _ = truncated.pop_front();
    assert_eq!(panic_of(setup.safe.register_level(truncated)), 'register: felts');
    // `Level.version` is the first felt; `validate` runs.
    let mut felts = one_block_felts().span();
    let _ = felts.pop_front();
    let mut version_2 = array![2];
    version_2.append_span(felts);
    assert_eq!(panic_of(setup.safe.register_level(version_2)), 'level: version');
}

#[test]
#[feature("safe_dispatcher")]
fn test_set_level_active() {
    let setup = setup_stub();
    let mut spy = spy_events();
    as_caller(setup, AUTHOR);
    setup.game.set_level_active(PILE10_HASH, false);
    assert!(!setup.game.level(PILE10_HASH).active);
    let event = Slingfall::LevelActiveSet { level_hash: PILE10_HASH, active: false };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::LevelActiveSet(event))]);
    as_caller(setup, ADMIN);
    setup.game.set_level_active(PILE10_HASH, true);
    assert!(setup.game.level(PILE10_HASH).active);
    as_caller(setup, OTHER);
    assert_eq!(panic_of(setup.safe.set_level_active(PILE10_HASH, false)), 'level: caller');
    assert_eq!(panic_of(setup.safe.set_level_active(0x1234, false)), 'level: unknown');
}

#[test]
#[feature("safe_dispatcher")]
fn test_submit_inactive_level_rejected() {
    let setup = setup_stub();
    as_caller(setup, AUTHOR);
    setup.game.set_level_active(PILE10_HASH, false);
    as_caller(setup, PLAYER);
    let claim = golden_claim();
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), sign(claim))), 'submit: inactive');
    // Unknown level.
    let unknown = Outputs { level_hash: 0x1234, ..claim };
    assert_eq!(panic_of(setup.safe.submit(unknown.to_felts(), sign(unknown))), 'submit: level');
}

#[test]
#[feature("safe_dispatcher")]
fn test_submit_wrong_caller_rejected() {
    let setup = setup_stub();
    as_caller(setup, OTHER);
    let claim = golden_claim();
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), sign(claim))), 'submit: player');
}

#[test]
#[feature("safe_dispatcher")]
fn test_submit_replay_rejected() {
    let setup = setup_stub();
    let claim = golden_claim();
    setup.game.submit(claim.to_felts(), sign(claim));
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), sign(claim))), 'submit: nullifier');
    // The nullifier ignores the score: the same inputs cannot be claimed twice.
    let other = Outputs { score: 1, ..claim };
    assert_eq!(panic_of(setup.safe.submit(other.to_felts(), sign(other))), 'submit: nullifier');
}

#[test]
#[feature("safe_dispatcher")]
fn test_submit_malformed_outputs_rejected() {
    let setup = setup_stub();
    let mut felts = golden_claim().to_felts();
    felts.append(0);
    assert_eq!(panic_of(setup.safe.submit(felts, array![GOLDEN_R, GOLDEN_S])), 'outputs: length');
}

/// The Python vector (`tools/vectors.py golden`) is accepted by the deployed contract.
#[test]
fn test_stub_verifier_accepts_the_golden_attestation() {
    let setup = setup_stub();
    let mut spy = spy_events();
    start_cheat_block_number(setup.address, 77);
    setup.game.submit(golden_claim().to_felts(), array![GOLDEN_R, GOLDEN_S]);
    let expected = Record { score: 1650, won: true, inputs_hash: 0xabc, block: 77 };
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH), expected);
    let event = Slingfall::LevelValidated {
        player: address(PLAYER),
        level_hash: PILE10_HASH,
        inputs_hash: 0xabc,
        score: 1650,
        won: true,
    };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::LevelValidated(event))]);
    // snforge's signer derives the same public key as the Python helper.
    let key_pair = KeyPairTrait::<felt252, felt252>::from_secret_key(SECRET);
    assert_eq!(key_pair.public_key, ATTESTATION_KEY);
}

#[test]
#[feature("safe_dispatcher")]
fn test_stub_verifier_rejects() {
    let setup = setup_stub();
    let claim = golden_claim();
    let felts = claim.to_felts();
    let bad = array![GOLDEN_R, GOLDEN_S + 1];
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), bad)), 'submit: proof');
    // A signature of another claim.
    let other = sign(Outputs { score: 9_999, ..claim });
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), other)), 'submit: proof');
    assert_eq!(panic_of(setup.safe.submit(felts.clone(), array![])), 'submit: proof');
    // Another key.
    as_caller(setup, ADMIN);
    setup.admin.set_attestation_key(GOLDEN_R);
    as_caller(setup, PLAYER);
    assert_eq!(panic_of(setup.safe.submit(felts, array![GOLDEN_R, GOLDEN_S])), 'submit: proof');
}

#[test]
#[feature("safe_dispatcher")]
fn test_snip36_verifier_reads_the_proof_facts() {
    let setup = setup_stub();
    as_caller(setup, ADMIN);
    setup.admin.set_verifier(VerifierKind::Snip36);
    as_caller(setup, PLAYER);
    let claim = golden_claim();
    // No program hash configured: rejected even with matching facts.
    let message = message_hash(setup.address.into(), MARKER, claim.to_felts().span());
    start_cheat_proof_facts(setup.address, array![0, message].span());
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), array![])), 'submit: proof');
    as_caller(setup, ADMIN);
    setup.admin.set_virtual_os_hash(VIRTUAL_OS_HASH);
    as_caller(setup, PLAYER);
    // Wrong program, then a message from another contract.
    start_cheat_proof_facts(setup.address, array![VIRTUAL_OS_HASH + 1, message].span());
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), array![])), 'submit: proof');
    let foreign = message_hash(0x5afe, MARKER, claim.to_felts().span());
    start_cheat_proof_facts(setup.address, array![VIRTUAL_OS_HASH, foreign].span());
    assert_eq!(panic_of(setup.safe.submit(claim.to_felts(), array![])), 'submit: proof');
    // The facts of `simulate`'s message.
    start_cheat_proof_facts(setup.address, array![VIRTUAL_OS_HASH, 0x1, message].span());
    setup.game.submit(claim.to_felts(), array![]);
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH).score, 1650);
}

#[test]
fn test_best_score_rules() {
    let setup = setup_stub();
    // (attempt, score, won, expected best (score, won)).
    let steps: Array<(felt252, u32, bool, (u32, bool))> = array![
        (1, 0, false, (0, false)), // Equal to "no record": not stored.
        (2, 300, false, (300, false)), (3, 200, false, (300, false)),
        (4, 100, true, (100, true)), // A win beats any loss.
        (5, 5_000, false, (100, true)),
        (6, 100, true, (100, true)), // A tie keeps the record.
        (7, 2_100, true, (2_100, true)),
    ];
    for (attempt, score, won, expected) in steps {
        submit(setup, claim(PLAYER, attempt, score, won));
        let record = setup.game.best(address(PLAYER), PILE10_HASH);
        assert_eq!((record.score, record.won), expected);
    }
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH).inputs_hash, 7);
    // Records are per player.
    assert_eq!(setup.game.best(address(OTHER), PILE10_HASH).block, 0);
    assert_eq!(setup.game.best(address(OTHER), PILE10_HASH).score, 0);
}

#[test]
fn test_leaderboard_order() {
    let setup = setup_stub();
    // (player, score, won).
    let attempts: Array<(felt252, u32, bool)> = array![
        ('p1', 500, true), ('p2', 900, true), ('p3', 700, true), ('p4', 9_000, false),
        ('p5', 700, true), ('p1', 800, true), ('p2', 100, true),
    ];
    let mut id = 0;
    for (player, score, won) in attempts {
        id += 1;
        submit(setup, claim(player, id, score, won));
    }
    // Lost attempts are not ranked; ties keep the first to reach the score; a player has one row.
    let expected = array![
        (address('p2'), 900), (address('p1'), 800), (address('p3'), 700), (address('p5'), 700),
    ];
    assert_eq!(setup.game.leaderboard(PILE10_HASH), expected);
    assert_eq!(setup.game.leaderboard(ONE_BLOCK_HASH), array![]);
}

#[test]
fn test_leaderboard_keeps_the_top_ten() {
    let setup = setup_stub();
    for i in 0..12_u32 {
        submit(setup, claim(0x100 + i.into(), i.into(), 100 + i, true));
    }
    let board = setup.game.leaderboard(PILE10_HASH);
    assert_eq!(board.len(), LEADERBOARD_SIZE);
    assert_eq!(*board[0], (address(0x10b), 111));
    assert_eq!(*board[LEADERBOARD_SIZE - 1], (address(0x102), 102));
}

#[test]
#[feature("safe_dispatcher")]
fn test_simulate_sends_the_outputs_message() {
    let setup = setup_stub();
    let inputs = Inputs {
        player: PLAYER,
        shots: array![Shot { pull_x: -300, pull_y: 120, delay: 0, ability_tick: 0 }],
    };
    let mut messages = spy_messages_to_l1();
    let outputs = setup.game.simulate(PILE10_HASH, to_felts(@inputs));
    assert_eq!(outputs.level_hash, PILE10_HASH);
    assert_eq!(outputs.player, PLAYER);
    assert_eq!(outputs.inputs_hash, inputs.hash());
    let message = MessageToL1 {
        to_address: MARKER.try_into().unwrap(), payload: outputs.to_felts(),
    };
    messages.assert_sent(@array![(setup.address, message)]);
    assert_eq!(panic_of(setup.safe.simulate(0x1234, to_felts(@inputs))), 'simulate: level');
    assert_eq!(panic_of(setup.safe.simulate(PILE10_HASH, array![PLAYER])), 'simulate: inputs');
}

#[test]
#[feature("safe_dispatcher")]
fn test_admin() {
    let setup = deploy();
    assert_eq!(setup.admin.admin(), address(ADMIN));
    assert_eq!(setup.admin.verifier(), VerifierKind::Snip36);
    assert_eq!(setup.admin.virtual_os_hash(), 0);
    let safe = ISlingfallAdminSafeDispatcher { contract_address: setup.address };
    as_caller(setup, OTHER);
    assert_eq!(panic_of(safe.set_admin(address(OTHER))), 'admin: caller');
    assert_eq!(panic_of(safe.set_virtual_os_hash(1)), 'admin: caller');
    assert_eq!(panic_of(safe.set_verifier(VerifierKind::Stub)), 'admin: caller');
    assert_eq!(panic_of(safe.set_attestation_key(1)), 'admin: caller');
    as_caller(setup, ADMIN);
    setup.admin.set_virtual_os_hash(VIRTUAL_OS_HASH);
    setup.admin.set_verifier(VerifierKind::Stub);
    setup.admin.set_attestation_key(ATTESTATION_KEY);
    assert_eq!(panic_of(safe.set_admin(address(0))), 'admin: zero');
    setup.admin.set_admin(address(OTHER));
    assert_eq!(panic_of(safe.set_verifier(VerifierKind::Snip36)), 'admin: caller');
    as_caller(setup, OTHER);
    assert_eq!(
        (setup.admin.admin(), setup.admin.verifier(), setup.admin.attestation_key()),
        (address(OTHER), VerifierKind::Stub, ATTESTATION_KEY),
    );
    assert_eq!(setup.admin.virtual_os_hash(), VIRTUAL_OS_HASH);
    // The former admin is neither admin nor author of a level registered by the new one.
    setup.game.register_level(one_block_felts());
    as_caller(setup, ADMIN);
    assert_eq!(panic_of(setup.safe.set_level_active(ONE_BLOCK_HASH, false)), 'level: caller');
}

#[test]
fn test_constructor_rejects_the_zero_admin() {
    let class = declare("Slingfall").unwrap().contract_class();
    match class.deploy(@array![0]) {
        Result::Ok(_) => panic!("deployed with a zero admin"),
        Result::Err(data) => assert_eq!(*data[0], 'admin: zero'),
    }
}

/// Setup of `steps_submit__stub` without the submission: subtract it to get `submit` alone.
#[test]
fn steps_submit__stub_setup() {
    let setup = setup_stub();
    let claim = golden_claim();
    let _ = (claim.to_felts(), array![GOLDEN_R, GOLDEN_S], setup);
}

/// `submit` with the stub verifier: first record and leaderboard row of the player.
#[test]
fn steps_submit__stub() {
    let setup = setup_stub();
    let claim = golden_claim();
    setup.game.submit(claim.to_felts(), array![GOLDEN_R, GOLDEN_S]);
}

/// Deployment only: subtract it from `steps_register_level__pile10`.
#[test]
fn steps_register_level__deploy() {
    let _ = deploy();
}

#[test]
fn steps_register_level__pile10() {
    let setup = deploy();
    setup.game.register_level(pile10_felts());
}
