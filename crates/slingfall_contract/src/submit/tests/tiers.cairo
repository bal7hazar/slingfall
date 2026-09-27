//! The two tiers side by side: a provisional record never hides a settled one (`best_settled`, the
//! settled `leaderboard`), and `expire` demotes an old unsettled provisional record.

use slingfall_level::level::fixtures::PILE10_HASH;
use slingfall_level::outputs::Outputs;
use snforge_std::{EventSpyAssertionsTrait, spy_events, start_cheat_block_timestamp};
use crate::registry::Best;
use crate::submit::DEFAULT_EXPIRE_DELAY;
use crate::submit::fixtures::{PILE10_INTEGRITY_FACT, PLAYER, reference_args, reference_outputs};
use super::settled::{
    IFakeSatelliteDispatcherTrait, reference_claim, reference_settled, setup_settled,
};
use super::super::{
    ISlingfallDispatcherTrait, ISlingfallGovernanceDispatcherTrait,
    ISlingfallGovernanceSafeDispatcherTrait, ISlingfallSafeDispatcherTrait, Slingfall,
};
use super::{
    ADMIN, OTHER, Setup, address, as_caller, claim, panic_of, provisional, setup_stub, sign, submit,
};

/// `PLAYER`'s reference run settled (5200, won) at timestamp 0.
fn settle_reference(setup: Setup) {
    as_caller(setup, PLAYER);
    setup.game.submit_settled(reference_outputs(), reference_args(), super::PROGRAM);
}

/// An attested attempt of `PLAYER` with a higher score than the reference, at `timestamp`.
fn attest_better(setup: Setup, inputs_hash: felt252, score: u32, timestamp: u64) -> Outputs {
    start_cheat_block_timestamp(setup.address, timestamp);
    let better = Outputs { inputs_hash, score, ..reference_claim() };
    submit(setup, better);
    better
}

#[test]
fn test_provisional_record_never_hides_the_settled_one() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    settle_reference(setup);
    attest_better(setup, 0xbe77e1, 9_000, 0);
    let player = address(PLAYER);
    assert_eq!(setup.game.best(player, PILE10_HASH), provisional(0xbe77e1, 9_000, true));
    assert_eq!(setup.game.best_settled(player, PILE10_HASH), reference_settled());
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(player, 5200)]);
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![(player, 9_000)]);
    // A lower attested attempt changes nothing.
    attest_better(setup, 0x10, 100, 0);
    assert_eq!(setup.game.best(player, PILE10_HASH).score, 9_000);
    assert_eq!(setup.game.best_settled(player, PILE10_HASH), reference_settled());
}

/// A settled attempt better than the provisional best moves both records and both boards.
#[test]
fn test_better_settled_attempt_moves_both_tiers() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    attest_better(setup, 0x10, 100, 0);
    settle_reference(setup);
    let player = address(PLAYER);
    assert_eq!(setup.game.best(player, PILE10_HASH), reference_settled());
    assert_eq!(setup.game.best_settled(player, PILE10_HASH), reference_settled());
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(player, 5200)]);
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![(player, 5200)]);
}

/// Before the delay: refused; from it on: the record falls back to the settled best, anyone may
/// call it, once.
#[test]
#[feature("safe_dispatcher")]
fn test_expire_before_and_after_the_delay() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    settle_reference(setup);
    let better = attest_better(setup, 0xbe77e1, 9_000, 1_000);
    let player = address(PLAYER);
    as_caller(setup, OTHER);
    start_cheat_block_timestamp(setup.address, 1_000 + DEFAULT_EXPIRE_DELAY - 1);
    assert_eq!(panic_of(setup.safe.expire(PILE10_HASH, player)), 'expire: early');
    start_cheat_block_timestamp(setup.address, 1_000 + DEFAULT_EXPIRE_DELAY);
    let mut spy = spy_events();
    setup.game.expire(PILE10_HASH, player);
    assert_eq!(setup.game.best(player, PILE10_HASH), reference_settled());
    assert_eq!(setup.game.best_settled(player, PILE10_HASH), reference_settled());
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![(player, 5200)]);
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(player, 5200)]);
    let event = Slingfall::RecordExpired {
        player, level_hash: PILE10_HASH, inputs_hash: better.inputs_hash,
    };
    spy.assert_emitted(@array![(setup.address, Slingfall::Event::RecordExpired(event))]);
    assert_eq!(panic_of(setup.safe.expire(PILE10_HASH, player)), 'expire: none');
    // The attempt itself stays attested: it can still be settled (not with the reference fact).
    assert_eq!(setup.game.attempt(PILE10_HASH, player, 0xbe77e1), 1);
}

/// With no settled record, `expire` empties the record and drops the provisional-board row; the
/// other rows keep their order.
#[test]
fn test_expire_without_settled_record_drops_the_row() {
    let setup = setup_stub();
    submit(setup, claim('p1', 1, 900, true));
    submit(setup, claim('p2', 2, 800, true));
    submit(setup, claim('p3', 3, 700, true));
    start_cheat_block_timestamp(setup.address, DEFAULT_EXPIRE_DELAY);
    setup.game.expire(PILE10_HASH, address('p2'));
    let none = Best {
        score: 0,
        won: false,
        inputs_hash: 0,
        block: 0,
        timestamp: 0,
        settled: false,
        program_hash: 0,
    };
    assert_eq!(setup.game.best(address('p2'), PILE10_HASH), none);
    let expected = array![(address('p1'), 900), (address('p3'), 700)];
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), expected);
    // The row can come back: a new attempt of the same player.
    submit(setup, claim('p2', 4, 950, true));
    let expected = array![(address('p2'), 950), (address('p1'), 900), (address('p3'), 700)];
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), expected);
}

/// A lost provisional record over no settled one: the record goes, no board row to move.
#[test]
fn test_expire_lost_provisional_record() {
    let setup = setup_stub();
    submit(setup, claim(PLAYER, 1, 300, false));
    submit(setup, claim('p1', 2, 900, true));
    start_cheat_block_timestamp(setup.address, DEFAULT_EXPIRE_DELAY);
    setup.game.expire(PILE10_HASH, address(PLAYER));
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH).score, 0);
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![(address('p1'), 900)]);
}

/// Nothing to expire: no record, a settled best, a provisional record settled since.
#[test]
#[feature("safe_dispatcher")]
fn test_expire_rejects_settled_or_absent_records() {
    let (setup, fake) = setup_settled();
    fake.register(PILE10_INTEGRITY_FACT);
    start_cheat_block_timestamp(setup.address, DEFAULT_EXPIRE_DELAY);
    let player = address(PLAYER);
    assert_eq!(panic_of(setup.safe.expire(PILE10_HASH, player)), 'expire: none');
    // Attested, then settled by upgrade.
    setup.game.submit(reference_outputs(), sign(setup, reference_claim()));
    settle_reference(setup);
    start_cheat_block_timestamp(setup.address, 3 * DEFAULT_EXPIRE_DELAY);
    assert_eq!(panic_of(setup.safe.expire(PILE10_HASH, player)), 'expire: none');
    assert!(setup.game.best(player, PILE10_HASH).settled);
}

/// An expired attempt settled later is the record again.
#[test]
fn test_expired_attempt_settled_later() {
    let (setup, fake) = setup_settled();
    setup.game.submit(reference_outputs(), sign(setup, reference_claim()));
    start_cheat_block_timestamp(setup.address, DEFAULT_EXPIRE_DELAY);
    setup.game.expire(PILE10_HASH, address(PLAYER));
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![]);
    fake.register(PILE10_INTEGRITY_FACT);
    start_cheat_block_timestamp(setup.address, 0);
    settle_reference(setup);
    assert_eq!(setup.game.best(address(PLAYER), PILE10_HASH), reference_settled());
    assert_eq!(setup.game.leaderboard(PILE10_HASH), array![(address(PLAYER), 5200)]);
    assert_eq!(setup.game.leaderboard_provisional(PILE10_HASH), array![(address(PLAYER), 5200)]);
}

#[test]
#[feature("safe_dispatcher")]
fn test_set_expire_delay() {
    let setup = setup_stub();
    assert_eq!(setup.governance.expire_delay(), DEFAULT_EXPIRE_DELAY);
    as_caller(setup, OTHER);
    assert_eq!(panic_of(setup.governance_safe.set_expire_delay(60)), 'admin: caller');
    as_caller(setup, ADMIN);
    setup.governance.set_expire_delay(60);
    assert_eq!(setup.governance.expire_delay(), 60);
    submit(setup, claim(PLAYER, 1, 300, true));
    start_cheat_block_timestamp(setup.address, 59);
    assert_eq!(panic_of(setup.safe.expire(PILE10_HASH, address(PLAYER))), 'expire: early');
    start_cheat_block_timestamp(setup.address, 60);
    setup.game.expire(PILE10_HASH, address(PLAYER));
}

/// `expire` on a full board, the probe of its worst case (the row removed from the top).
#[test]
fn steps_expire__full_board() {
    let setup = setup_stub();
    for i in 0..10_u32 {
        submit(setup, claim(0x100 + i.into(), i.into(), 1_000 - i, true));
    }
    start_cheat_block_timestamp(setup.address, DEFAULT_EXPIRE_DELAY);
    setup.game.expire(PILE10_HASH, address(0x100));
}

/// Setup of `steps_expire__full_board` without the call.
#[test]
fn steps_expire__setup() {
    let setup = setup_stub();
    for i in 0..10_u32 {
        submit(setup, claim(0x100 + i.into(), i.into(), 1_000 - i, true));
    }
    start_cheat_block_timestamp(setup.address, DEFAULT_EXPIRE_DELAY);
}
