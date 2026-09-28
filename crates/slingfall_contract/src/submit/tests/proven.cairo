//! The proven tier (contract v3): `submit_chunk` on proof facts faked with snforge's
//! `start_cheat_proof_facts` (the whole of `tx_info.proof_facts`, so nothing is stubbed in the
//! contract), `finalize` over synthetic chains (state hashes are opaque to the contract), the
//! refusals of the brief, the grace of chains and virtual-OS programs, and the gas probes. The
//! helpers are shared with `upgrade`.

use core::poseidon::poseidon_hash_span;
use slingfall_level::hash::to_felts;
use slingfall_level::inputs::{Inputs, Shot};
use slingfall_level::level::fixtures::PILE10_HASH;
use slingfall_level::outputs::{Outputs, OutputsTrait};
use snforge_std::{
    EventSpyAssertionsTrait, spy_events, start_cheat_block_number, start_cheat_block_timestamp,
    start_cheat_proof_facts,
};
use crate::registry::Best;
use crate::simulate::MARKER;
use crate::submit::chunks::{Edge, MAX_EDGES, kind};
use crate::submit::fixtures::{
    BASE_BLOCK, PLAYER, VIRTUAL_OS_HASH, golden_claim, proof_facts, reference_inputs,
};
use crate::submit::nullifier;
use crate::verifier::{BLOCK_HASH_BUFFER, message_hash};
use super::super::{
    ISlingfallDispatcherTrait, ISlingfallProvenDispatcher, ISlingfallProvenDispatcherTrait,
    ISlingfallProvenSafeDispatcher, ISlingfallProvenSafeDispatcherTrait,
    ISlingfallSafeDispatcherTrait, Slingfall,
};
use super::{ADMIN, OTHER, PROGRAM, Setup, address, as_caller, panic_of, setup_stub, sign};

/// The chain contract of the tests (a `SplitChain` deployment) and its bundle.
pub const CHAIN: felt252 = 'split chain';
pub const BUNDLE: felt252 = 'bundle v1';
/// A third party that relays the chunks and the finalization.
pub const RELAY: felt252 = 'relay';

#[derive(Drop, Copy)]
pub struct Proven {
    pub setup: Setup,
    pub proven: ISlingfallProvenDispatcher,
    pub safe: ISlingfallProvenSafeDispatcher,
}

/// The proven-tier dispatchers of `setup`.
pub fn proven_of(setup: Setup) -> Proven {
    Proven {
        setup,
        proven: ISlingfallProvenDispatcher { contract_address: setup.address },
        safe: ISlingfallProvenSafeDispatcher { contract_address: setup.address },
    }
}

/// `setup`'s SNIP-36 tier configured by `ADMIN` (marker, `CHAIN` of `BUNDLE`, the virtual OS),
/// at the first block where facts of `BASE_BLOCK` are accepted; the caller left to `RELAY`.
pub fn configure_proven(setup: Setup) -> Proven {
    let p = proven_of(setup);
    as_caller(setup, ADMIN);
    p.proven.set_chunk_marker(MARKER);
    p.proven.pin_chain(address(CHAIN), BUNDLE, 0);
    p.proven.pin_virtual_os(VIRTUAL_OS_HASH, 0);
    start_cheat_block_number(setup.address, BASE_BLOCK + BLOCK_HASH_BUFFER);
    as_caller(setup, RELAY);
    p
}

/// `setup_stub()` (pile10 registered, the attestation) with the SNIP-36 tier.
fn setup_proven() -> Proven {
    configure_proven(setup_stub())
}

/// A chain's links, as `(kind, payload)`, and what `finalize` takes.
#[derive(Drop, Clone)]
pub struct ChainLinks {
    pub inputs: Array<felt252>,
    pub outputs: Array<felt252>,
    pub links: Array<(u8, Array<felt252>)>,
}

/// The state hash after `i` steps of a synthetic chain.
fn state(i: u32) -> felt252 {
    0x5000 + i.into()
}

/// The outputs `finalize` expects for `inputs` on pile10: the golden claim's result, bound to the
/// inputs' player and hash.
pub fn outputs_of(inputs: Span<felt252>) -> Outputs {
    Outputs {
        level_hash: PILE10_HASH,
        player: *inputs[0],
        inputs_hash: poseidon_hash_span(inputs),
        ..golden_claim(),
    }
}

/// `init` on pile10, one step per entry of `shots` (the shot it runs, `k = 20`), `outputs`.
pub fn chain_of(inputs: Array<felt252>, shots: Span<u8>) -> ChainLinks {
    let inputs_hash = poseidon_hash_span(inputs.span());
    let outputs = outputs_of(inputs.span()).to_felts();
    let mut links = array![(kind::INIT, array![PILE10_HASH, state(0)])];
    let mut i = 0;
    for shot in shots {
        links.append((kind::STEP, array![state(i), inputs_hash, (*shot).into(), 20, state(i + 1)]));
        i += 1;
    }
    let mut end = array![state(i), inputs_hash];
    end.append_span(outputs.span());
    links.append((kind::OUTPUTS, end));
    ChainLinks { inputs, outputs, links }
}

/// The reference shot (one shot, `PLAYER`) as a chain of `n` steps.
pub fn reference_chain(n: u32) -> ChainLinks {
    let mut shots = array![];
    for _ in 0..n {
        shots.append(0_u8);
    }
    chain_of(reference_inputs(), shots.span())
}

/// Facts of `BASE_BLOCK` holding these messages.
fn facts_with(messages: Array<felt252>) -> Array<felt252> {
    proof_facts(VIRTUAL_OS_HASH, BASE_BLOCK, messages.span())
}

fn chunk_hash(chain: felt252, payload: @Array<felt252>) -> felt252 {
    message_hash(chain, MARKER, payload.span())
}

/// One proof per link: its facts hold its message only.
pub fn submit_link(p: Proven, link: @(u8, Array<felt252>)) {
    let (kind, payload) = link;
    start_cheat_proof_facts(p.setup.address, facts_with(array![chunk_hash(CHAIN, payload)]).span());
    p.proven.submit_chunk(address(CHAIN), *kind, payload.clone());
}

pub fn submit_links(p: Proven, chain: @ChainLinks) {
    for link in chain.links.span() {
        submit_link(p, link);
    }
}

pub fn finalize(p: Proven, chain: @ChainLinks) {
    p.proven.finalize(address(CHAIN), PILE10_HASH, chain.inputs.clone(), chain.outputs.clone());
}

#[feature("safe_dispatcher")]
fn finalize_panic(p: Proven, chain: @ChainLinks) -> felt252 {
    panic_of(
        p.safe.finalize(address(CHAIN), PILE10_HASH, chain.inputs.clone(), chain.outputs.clone()),
    )
}

/// `submit_chunk` of `(kind, payload)` under `facts`: its panic.
#[feature("safe_dispatcher")]
fn chunk_panic(p: Proven, facts: Array<felt252>, kind: u8, payload: Array<felt252>) -> felt252 {
    start_cheat_proof_facts(p.setup.address, facts.span());
    panic_of(p.safe.submit_chunk(address(CHAIN), kind, payload))
}

/// The proven `Best` of the golden result at block `BASE_BLOCK + BLOCK_HASH_BUFFER`.
fn proven_best(inputs_hash: felt252) -> Best {
    Best {
        score: 1650,
        won: true,
        inputs_hash,
        block: BASE_BLOCK + BLOCK_HASH_BUFFER,
        timestamp: 0,
        settled: true,
        program_hash: BUNDLE,
    }
}

/// Five and seven chunks (research 07's layouts (e) and (b) on the owner's shot), relayed.
#[test]
fn test_finalize_records_a_proven_chain() {
    for n in array![5_u32, 7] {
        let p = setup_proven();
        let chain = reference_chain(n);
        let inputs_hash = poseidon_hash_span(chain.inputs.span());
        submit_links(p, @chain);
        assert_eq!(p.proven.chunk_start(address(CHAIN), PILE10_HASH), state(0));
        let edge = p.proven.chunk_edge(address(CHAIN), inputs_hash, state(0));
        assert_eq!(edge, Edge { shot: 0, k: 20, next: state(1) });
        let end = p.proven.chunk_end(address(CHAIN), inputs_hash, state(n));
        assert_eq!(end, poseidon_hash_span(chain.outputs.span()));
        let mut spy = spy_events();
        finalize(p, @chain);
        let game = p.setup.game;
        assert_eq!(game.attempt(PILE10_HASH, address(PLAYER), inputs_hash), nullifier::PROVEN);
        assert_eq!(game.best(address(PLAYER), PILE10_HASH), proven_best(inputs_hash));
        assert_eq!(game.best_settled(address(PLAYER), PILE10_HASH), proven_best(inputs_hash));
        assert_eq!(game.leaderboard(PILE10_HASH), array![(address(PLAYER), 1650)]);
        assert_eq!(game.leaderboard_provisional(PILE10_HASH), array![(address(PLAYER), 1650)]);
        let event = Slingfall::LevelValidated {
            player: address(PLAYER),
            level_hash: PILE10_HASH,
            inputs_hash,
            score: 1650,
            won: true,
            settled: true,
            program_hash: BUNDLE,
            proven: true,
        };
        spy.assert_emitted(@array![(p.setup.address, Slingfall::Event::LevelValidated(event))]);
    }
}

/// The proven tier ranks with the settled one: a better proven attempt replaces a settled record
/// and a worse one does not.
#[test]
fn test_proven_ranks_with_settled() {
    let p = setup_proven();
    // An attested attempt with a higher score, then this chain's attempt (1650) proven.
    as_caller(p.setup, PLAYER);
    let attested = Outputs { inputs_hash: 0x1, score: 9_000, ..golden_claim() };
    p.setup.game.submit(attested.to_felts(), sign(p.setup, attested));
    let chain = reference_chain(2);
    submit_links(p, @chain);
    finalize(p, @chain);
    let inputs_hash = poseidon_hash_span(chain.inputs.span());
    // `best` keeps the higher attested score; the settled board has the proven one.
    assert_eq!(p.setup.game.best(address(PLAYER), PILE10_HASH).score, 9_000);
    assert_eq!(p.setup.game.best_settled(address(PLAYER), PILE10_HASH), proven_best(inputs_hash));
    assert_eq!(p.setup.game.leaderboard(PILE10_HASH), array![(address(PLAYER), 1650)]);
}

/// Links come in any order, from anyone, several times; a different link under a taken key is
/// refused.
#[test]
#[feature("safe_dispatcher")]
fn test_submit_chunk_is_idempotent_and_order_free() {
    let p = setup_proven();
    let chain = reference_chain(3);
    let mut reversed = array![];
    let mut links = chain.links.span();
    while let Some(link) = links.pop_back() {
        reversed.append(link.clone());
    }
    for link in reversed.span() {
        submit_link(p, link);
    }
    as_caller(p.setup, OTHER);
    submit_links(p, @chain);
    // Another step from the same state (another `k`), another start, another end.
    let inputs_hash = poseidon_hash_span(chain.inputs.span());
    let conflicts = array![
        (kind::STEP, array![state(0), inputs_hash, 0, 30, 0x6000]),
        (kind::INIT, array![PILE10_HASH, 0x6000]),
    ];
    for (kind, payload) in conflicts {
        let facts = facts_with(array![chunk_hash(CHAIN, @payload)]);
        assert_eq!(chunk_panic(p, facts, kind, payload), 'chunk: conflict');
    }
    let mut end = array![state(3), inputs_hash];
    end.append_span(Outputs { score: 1, ..outputs_of(chain.inputs.span()) }.to_felts().span());
    let facts = facts_with(array![chunk_hash(CHAIN, @end)]);
    assert_eq!(chunk_panic(p, facts, kind::OUTPUTS, end), 'chunk: conflict');
    finalize(p, @chain);
}

/// One proof holding every message of the chain (a virtual transaction that multicalls the
/// chain's entry points): each link is submitted against the same facts.
#[test]
fn test_one_proof_many_chunks() {
    let p = setup_proven();
    let chain = reference_chain(2);
    let mut messages = array![];
    for link in chain.links.span() {
        let (_, payload) = link;
        messages.append(chunk_hash(CHAIN, payload));
    }
    start_cheat_proof_facts(p.setup.address, facts_with(messages).span());
    for link in chain.links.span() {
        let (kind, payload) = link;
        p.proven.submit_chunk(address(CHAIN), *kind, payload.clone());
    }
    finalize(p, @chain);
}

#[test]
#[feature("safe_dispatcher")]
fn test_submit_chunk_rejects_the_facts() {
    let p = setup_proven();
    let payload = array![PILE10_HASH, state(0)];
    let message = chunk_hash(CHAIN, @payload);
    // (facts, panic): wrong program, the message of another contract, of another marker, of
    // another payload, none, v2's provisional layout, a base block too young, no base block hash.
    let young = proof_facts(VIRTUAL_OS_HASH, BASE_BLOCK + 1, array![message].span());
    let no_hash = array![
        'PROOF2', 'VIRTUAL_SNOS', VIRTUAL_OS_HASH, 'VIRTUAL_SNOS0', BASE_BLOCK.into(), 0, 0xc0f, 1,
        message,
    ];
    let cases: Array<(Array<felt252>, felt252)> = array![
        (proof_facts(VIRTUAL_OS_HASH + 1, BASE_BLOCK, array![message].span()), 'chunk: program'),
        (facts_with(array![chunk_hash(OTHER, @payload)]), 'chunk: message'),
        (facts_with(array![message_hash(CHAIN, 'OTHER', payload.span())]), 'chunk: message'),
        (facts_with(array![chunk_hash(CHAIN, @array![PILE10_HASH, state(1)])]), 'chunk: message'),
        (facts_with(array![]), 'chunk: message'),
        (array![VIRTUAL_OS_HASH, message], 'chunk: facts'), (array![], 'chunk: facts'),
        (young, 'chunk: base block'), (no_hash, 'chunk: base block'),
    ];
    for (facts, expected) in cases {
        assert_eq!(chunk_panic(p, facts, kind::INIT, payload.clone()), expected);
    }
    // A valid proof of a malformed payload, and of an unknown kind.
    let bad = array![PILE10_HASH, 0];
    let facts_bad = facts_with(array![chunk_hash(CHAIN, @bad)]);
    assert_eq!(chunk_panic(p, facts_bad, kind::INIT, bad), 'chunk: payload');
    assert_eq!(chunk_panic(p, facts_with(array![message]), 3, payload.clone()), 'chunk: kind');
    // Nothing was stored.
    assert_eq!(p.proven.chunk_start(address(CHAIN), PILE10_HASH), 0);
}

/// An unpinned chain, then no marker: every chunk is refused.
#[test]
#[feature("safe_dispatcher")]
fn test_submit_chunk_needs_the_chain_and_the_marker() {
    let p = setup_proven();
    let payload = array![PILE10_HASH, state(0)];
    let facts = facts_with(array![chunk_hash(OTHER, @payload)]);
    start_cheat_proof_facts(p.setup.address, facts.span());
    let result = p.safe.submit_chunk(address(OTHER), kind::INIT, payload.clone());
    assert_eq!(panic_of(result), 'chunk: chain');
    as_caller(p.setup, ADMIN);
    p.proven.set_chunk_marker(0);
    let facts = facts_with(array![message_hash(CHAIN, 0, payload.span())]);
    assert_eq!(chunk_panic(p, facts, kind::INIT, payload), 'chunk: chain');
}

#[test]
#[feature("safe_dispatcher")]
fn test_finalize_rejects_broken_and_unfinished_chains() {
    let p = setup_proven();
    let chain = reference_chain(3);
    let inputs_hash = poseidon_hash_span(chain.inputs.span());
    // No `init`.
    assert_eq!(finalize_panic(p, @chain), 'finalize: link');
    // Every link but the second step (a broken link).
    let mut i = 0;
    for link in chain.links.span() {
        if i != 2 {
            submit_link(p, link);
        }
        i += 1;
    }
    assert_eq!(finalize_panic(p, @chain), 'finalize: link');
    // The step exists only for another attempt's inputs.
    let other = array![state(1), inputs_hash + 1, 0, 20, state(2)];
    submit_link(p, @(kind::STEP, other));
    assert_eq!(finalize_panic(p, @chain), 'finalize: link');
    // The missing step closes the chain.
    submit_link(p, chain.links.at(2));
    finalize(p, @chain);
}

/// Every link but `outputs`: the last state has no end.
#[test]
#[feature("safe_dispatcher")]
fn test_finalize_rejects_an_unfinished_chain() {
    let p = setup_proven();
    let chain = reference_chain(3);
    let mut i = 0;
    for link in chain.links.span() {
        if i != 4 {
            submit_link(p, link);
        }
        i += 1;
    }
    assert_eq!(finalize_panic(p, @chain), 'finalize: link');
}

#[test]
#[feature("safe_dispatcher")]
fn test_finalize_rejects_outputs_and_inputs() {
    let p = setup_proven();
    let chain = reference_chain(1);
    submit_links(p, @chain);
    let claim = outputs_of(chain.inputs.span());
    let other_player = Outputs { player: 'other', ..claim };
    let other_level = Outputs { level_hash: 0x1234, ..claim };
    let other_score = Outputs { score: 1, ..claim };
    // Outputs of another player, level or result than the chain's end.
    for outputs in array![other_player, other_level, other_score] {
        let result = p
            .safe
            .finalize(address(CHAIN), PILE10_HASH, chain.inputs.clone(), outputs.to_felts());
        assert_eq!(panic_of(result), 'finalize: outputs');
    }
    // Inputs that are not the outputs' (another player), or not an `Inputs`.
    let mut others = to_felts(
        @Inputs {
            player: 'other',
            shots: array![Shot { pull_x: -604, pull_y: -392, delay: 0, ability_tick: 0 }],
        },
    );
    let result = p.safe.finalize(address(CHAIN), PILE10_HASH, others, chain.outputs.clone());
    assert_eq!(panic_of(result), 'finalize: outputs');
    let mut trailing = chain.inputs.clone();
    trailing.append(0);
    let result = p.safe.finalize(address(CHAIN), PILE10_HASH, trailing, chain.outputs.clone());
    assert_eq!(panic_of(result), 'finalize: inputs');
    others = array![PLAYER, 5];
    let result = p.safe.finalize(address(CHAIN), PILE10_HASH, others, chain.outputs.clone());
    assert_eq!(panic_of(result), 'finalize: inputs');
}

/// Shots run in order, each a shot of the inputs.
#[test]
#[feature("safe_dispatcher")]
fn test_finalize_checks_the_shot_order() {
    let shot = Shot { pull_x: -604, pull_y: -392, delay: 0, ability_tick: 0 };
    let two = to_felts(@Inputs { player: PLAYER, shots: array![shot, shot] });
    // (steps' shots, panic): backwards, a third shot of two.
    let cases: Array<(Array<u8>, felt252)> = array![
        (array![0, 1, 0], 'finalize: shot'), (array![0, 2], 'finalize: shot'),
    ];
    for (shots, expected) in cases {
        let p = setup_proven();
        let chain = chain_of(two.clone(), shots.span());
        submit_links(p, @chain);
        assert_eq!(finalize_panic(p, @chain), expected);
    }
    // In order, one shot running over two chunks.
    let p = setup_proven();
    let chain = chain_of(two, array![0, 0, 1].span());
    submit_links(p, @chain);
    finalize(p, @chain);
}

#[test]
#[feature("safe_dispatcher")]
fn test_finalize_bounds_the_walk() {
    let p = setup_proven();
    let too_long = reference_chain(MAX_EDGES + 1);
    submit_links(p, @too_long);
    assert_eq!(finalize_panic(p, @too_long), 'finalize: length');
    let p = setup_proven();
    let longest = reference_chain(MAX_EDGES);
    submit_links(p, @longest);
    finalize(p, @longest);
}

/// The nullifier is shared: a proven attempt is final, an attested one is upgraded, a settled one
/// is not proven again.
#[test]
#[feature("safe_dispatcher")]
fn test_finalize_replay_and_upgrade() {
    let p = setup_proven();
    let chain = reference_chain(2);
    let claim = outputs_of(chain.inputs.span());
    // Attested first (by the player), then proven by a relay.
    as_caller(p.setup, PLAYER);
    p.setup.game.submit(claim.to_felts(), sign(p.setup, claim));
    as_caller(p.setup, RELAY);
    submit_links(p, @chain);
    finalize(p, @chain);
    let game = p.setup.game;
    assert_eq!(game.attempt(PILE10_HASH, address(PLAYER), claim.inputs_hash), nullifier::PROVEN);
    // The attested record is marked settled by its proof, and the settled board has it.
    let best = game.best(address(PLAYER), PILE10_HASH);
    assert_eq!((best.settled, best.program_hash, best.timestamp), (true, BUNDLE, 0));
    assert_eq!(game.leaderboard(PILE10_HASH), array![(address(PLAYER), 1650)]);
    // Replays: the same chain, the attested and the settled tiers.
    assert_eq!(finalize_panic(p, @chain), 'submit: nullifier');
    as_caller(p.setup, PLAYER);
    let result = p.setup.safe.submit(claim.to_felts(), sign(p.setup, claim));
    assert_eq!(panic_of(result), 'submit: nullifier');
    let result = p.setup.safe.submit_settled(claim.to_felts(), array![], PROGRAM);
    assert_eq!(panic_of(result), 'submit: nullifier');
}

/// A retired chain (bundle) finalizes during its grace and is refused after it; a revoked one at
/// once.
#[test]
#[feature("safe_dispatcher")]
fn test_retired_bundle_is_refused_after_its_grace() {
    let p = setup_proven();
    let chain = reference_chain(2);
    submit_links(p, @chain);
    start_cheat_block_timestamp(p.setup.address, 1_000);
    as_caller(p.setup, ADMIN);
    let mut spy = spy_events();
    p.proven.pin_chain(address(OTHER), 'bundle v2', 3_600);
    let event = Slingfall::ChainPinned {
        chain: address(OTHER),
        bundle_hash: 'bundle v2',
        previous: address(CHAIN),
        previous_valid_until: 4_600,
    };
    spy.assert_emitted(@array![(p.setup.address, Slingfall::Event::ChainPinned(event))]);
    assert_eq!(p.proven.current_chain(), address(OTHER));
    assert_eq!(p.proven.chain_valid_until(address(CHAIN)), 4_600);
    assert_eq!(p.proven.chain_bundle(address(OTHER)), 'bundle v2');
    as_caller(p.setup, RELAY);
    // In the grace: chunks and finalization of the old bundle still go through.
    let second = chain_of(to_felts(@Inputs { player: OTHER, shots: array![] }), array![].span());
    submit_link(p, second.links.at(1));
    start_cheat_block_timestamp(p.setup.address, 4_599);
    finalize(p, @chain);
    // After it: refused.
    start_cheat_block_timestamp(p.setup.address, 4_600);
    assert_eq!(finalize_panic(p, @second), 'finalize: chain');
    let payload = second.links.at(1).clone();
    let (kind, payload) = payload;
    let facts = facts_with(array![chunk_hash(CHAIN, @payload)]);
    assert_eq!(chunk_panic(p, facts, kind, payload), 'chunk: chain');
    // Revoked: at once, and no longer current.
    as_caller(p.setup, ADMIN);
    p.proven.revoke_chain(address(OTHER));
    assert_eq!(
        (p.proven.chain_valid_until(address(OTHER)), p.proven.current_chain()), (0, address(0)),
    );
}

/// The virtual-OS set: a new pin keeps the previous program for its grace.
#[test]
#[feature("safe_dispatcher")]
fn test_virtual_os_set_with_grace() {
    let p = setup_proven();
    let payload = array![PILE10_HASH, state(0)];
    let message = chunk_hash(CHAIN, @payload);
    start_cheat_block_timestamp(p.setup.address, 1_000);
    as_caller(p.setup, ADMIN);
    p.proven.pin_virtual_os('virtual os 2', 60);
    assert_eq!(p.proven.current_virtual_os(), 'virtual os 2');
    assert_eq!(p.proven.virtual_os_valid_until(VIRTUAL_OS_HASH), 1_060);
    as_caller(p.setup, RELAY);
    start_cheat_block_timestamp(p.setup.address, 1_060);
    let old = facts_with(array![message]);
    assert_eq!(chunk_panic(p, old, kind::INIT, payload.clone()), 'chunk: program');
    let new = proof_facts('virtual os 2', BASE_BLOCK, array![message].span());
    start_cheat_proof_facts(p.setup.address, new.span());
    p.proven.submit_chunk(address(CHAIN), kind::INIT, payload.clone());
    as_caller(p.setup, ADMIN);
    p.proven.revoke_virtual_os('virtual os 2');
    assert_eq!(p.proven.current_virtual_os(), 0);
    as_caller(p.setup, RELAY);
    assert_eq!(chunk_panic(p, new, kind::INIT, payload), 'chunk: program');
}

#[test]
#[feature("safe_dispatcher")]
fn test_proven_admin() {
    let p = setup_proven();
    let chain = address(CHAIN);
    as_caller(p.setup, OTHER);
    assert_eq!(panic_of(p.safe.set_chunk_marker(1)), 'admin: caller');
    assert_eq!(panic_of(p.safe.pin_chain(chain, BUNDLE, 0)), 'admin: caller');
    assert_eq!(panic_of(p.safe.revoke_chain(chain)), 'admin: caller');
    assert_eq!(panic_of(p.safe.pin_virtual_os(1, 0)), 'admin: caller');
    assert_eq!(panic_of(p.safe.revoke_virtual_os(VIRTUAL_OS_HASH)), 'admin: caller');
    as_caller(p.setup, ADMIN);
    assert_eq!(panic_of(p.safe.pin_chain(address(0), BUNDLE, 0)), 'chain: zero');
    assert_eq!(panic_of(p.safe.pin_chain(chain, 0, 0)), 'chain: zero');
    assert_eq!(panic_of(p.safe.pin_virtual_os(0, 0)), 'program: zero');
    assert_eq!(p.proven.chunk_marker(), MARKER);
    // Re-pinning the current chain keeps it current and forever valid.
    p.proven.pin_chain(chain, 'bundle v1b', 0);
    assert_eq!(
        (p.proven.current_chain(), p.proven.chain_valid_until(chain)),
        (chain, crate::submit::FOREVER),
    );
    assert_eq!(p.proven.chain_bundle(chain), 'bundle v1b');
}

/// An inactive level refuses finalization (the chunks are still stored).
#[test]
#[feature("safe_dispatcher")]
fn test_finalize_inactive_level() {
    let p = setup_proven();
    let chain = reference_chain(1);
    submit_links(p, @chain);
    as_caller(p.setup, ADMIN);
    p.setup.game.set_level_active(PILE10_HASH, false);
    assert_eq!(finalize_panic(p, @chain), 'submit: inactive');
}

// Gas probes (`docs/contract-v3.md` "Gas"): each over its `__setup`.

/// Setup of `steps_submit_chunk__*`: configured, the facts of the chunk cheated.
#[test]
fn steps_submit_chunk__setup() {
    let p = setup_proven();
    let chain = reference_chain(1);
    let (_, payload) = chain.links.at(1);
    start_cheat_proof_facts(p.setup.address, facts_with(array![chunk_hash(CHAIN, payload)]).span());
}

/// One `step_chunk` link: facts parsed, message found among 1, an `Edge` written (2 slots).
#[test]
fn steps_submit_chunk__step() {
    let p = setup_proven();
    let chain = reference_chain(1);
    let (kind, payload) = chain.links.at(1);
    start_cheat_proof_facts(p.setup.address, facts_with(array![chunk_hash(CHAIN, payload)]).span());
    p.proven.submit_chunk(address(CHAIN), *kind, payload.clone());
}

/// The `outputs` link: the outputs decoded and hashed, one slot written.
#[test]
fn steps_submit_chunk__outputs() {
    let p = setup_proven();
    let chain = reference_chain(1);
    let (kind, payload) = chain.links.at(2);
    start_cheat_proof_facts(p.setup.address, facts_with(array![chunk_hash(CHAIN, payload)]).span());
    p.proven.submit_chunk(address(CHAIN), *kind, payload.clone());
}

fn finalize_setup(n: u32) -> (Proven, ChainLinks) {
    let p = setup_proven();
    let chain = reference_chain(n);
    submit_links(p, @chain);
    (p, chain)
}

#[test]
fn steps_finalize__5_chunks_setup() {
    let _ = finalize_setup(5);
}

/// `finalize` over 5 steps: first record and board rows of the player (both tiers' boards).
#[test]
fn steps_finalize__5_chunks() {
    let (p, chain) = finalize_setup(5);
    finalize(p, @chain);
}

#[test]
fn steps_finalize__7_chunks_setup() {
    let _ = finalize_setup(7);
}

#[test]
fn steps_finalize__7_chunks() {
    let (p, chain) = finalize_setup(7);
    finalize(p, @chain);
}

#[test]
fn steps_finalize__64_chunks_setup() {
    let _ = finalize_setup(MAX_EDGES);
}

/// The longest walk: the per-edge cost is `(64 chunks - 7 chunks) / 57`.
#[test]
fn steps_finalize__64_chunks() {
    let (p, chain) = finalize_setup(MAX_EDGES);
    finalize(p, @chain);
}
