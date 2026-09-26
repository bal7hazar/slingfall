use core::poseidon::poseidon_hash_span;
use slingfall_game::chunk::{
    CHUNK_STATE_VERSION, ChunkState, INIT_HEADER_LEN, STEP_HEADER_LEN, init_state, state_outputs,
};
use slingfall_game::errors;
use slingfall_game::fixtures::{
    PLAYER, REFERENCE_INPUTS_HASH, reference_inputs, reference_outputs, shot,
};
use slingfall_game::play::decode;
use slingfall_level::hash::{serde_hash, to_felts};
use slingfall_level::inputs::Inputs;
use slingfall_level::level::fixtures::{PILE10_HASH, one_block_felts, pile10, pile10_felts};
use slingfall_level::outputs::OutputsTrait;
use slingfall_testing::opaque;
use crate::main::main;
use super::{init, step_chunk};

/// The felts after an executable's `n`-felt binding header.
pub fn payload(felts: Array<felt252>, n: u32) -> Array<felt252> {
    let mut out: Array<felt252> = array![];
    out.append_span(felts.span().slice(n, felts.len() - n));
    out
}

/// `init`'s state (its output without the header).
pub fn init_payload(level: Array<felt252>) -> Array<felt252> {
    payload(init(level), INIT_HEADER_LEN)
}

/// `step_chunk`'s new state (its output without the header).
pub fn step_payload(
    state: Array<felt252>, inputs: Array<felt252>, shot: u8, k: u32,
) -> Array<felt252> {
    payload(step_chunk(state, inputs, shot, k, 0), STEP_HEADER_LEN)
}

/// `init`, then `step_chunk` with budget `k` for every shot of `inputs` until the level is over or
/// the inputs end; the outputs of the final state. Checks the state header and the binding header
/// (lot P1b) after every chunk.
fn chain(level: Array<felt252>, inputs: @Inputs, k: u32) -> Array<felt252> {
    let inputs_felts = to_felts(inputs);
    let inputs_hash = poseidon_hash_span(inputs_felts.span());
    let mut state = init_payload(level);
    let mut shot: u8 = 0;
    let mut chunks: u32 = 0;
    while shot.into() != inputs.shots.len() && *state[2] == 0 {
        let before: u32 = (*state[5]).try_into().unwrap();
        let state_in_hash = poseidon_hash_span(state.span());
        let out = step_chunk(state, inputs_felts.clone(), shot, k, 0);
        assert_eq!(
            out.span().slice(0, STEP_HEADER_LEN),
            array![state_in_hash, inputs_hash, shot.into(), k.into()].span(),
        );
        state = payload(out, STEP_HEADER_LEN);
        chunks += 1;
        let after: u32 = (*state[5]).try_into().unwrap();
        // `tick` advances by at most `k` (exactly `k` unless the shot ended).
        assert!(after > before && after - before <= k);
        let shots_used: u8 = (*state[1]).try_into().unwrap();
        if shots_used == shot + 1 {
            shot += 1;
        } else {
            assert_eq!(after - before, k);
            assert_eq!(shots_used, shot);
        }
    }
    assert!(chunks > 0);
    let state: ChunkState = decode(state.span(), errors::STATE);
    state_outputs(state, inputs).to_felts()
}

#[test]
fn test_chain_k1_matches_main() {
    assert_eq!(chain(pile10_felts(), @reference_inputs(), 1), reference_outputs());
}

#[test]
fn test_chain_k7_matches_main() {
    assert_eq!(chain(pile10_felts(), @reference_inputs(), 7), reference_outputs());
}

#[test]
fn test_chain_k60_matches_main() {
    assert_eq!(chain(pile10_felts(), @reference_inputs(), 60), reference_outputs());
}

/// A delay that chunks of 3 cut through (two chunks of delay ticks, then one delay tick, the
/// launch and two flight ticks in the third), on the one-block level: chained ≡ `main`.
#[test]
fn test_chain_with_a_delay_matches_main() {
    let inputs = Inputs { player: PLAYER, shots: array![shot(-600, -200, 7)] };
    let expected = main(one_block_felts(), to_felts(@inputs));
    assert_eq!(chain(one_block_felts(), @inputs, 3), expected);
}

/// `init`'s output: `[LEVEL_HASH]` (pile10's golden `level_hash`), then the state: version 1,
/// nothing played; the rest of the array is exactly one `ChunkState`, `init_state`'s.
#[test]
fn test_init_header() {
    let out = init(pile10_felts());
    assert_eq!(*out[0], PILE10_HASH);
    let state = payload(out, INIT_HEADER_LEN);
    assert_eq!(
        state.span().slice(0, 7), array![CHUNK_STATE_VERSION.into(), 0, 0, 0, 0, 0, 0].span(),
    );
    let decoded: ChunkState = decode(state.span(), errors::STATE);
    assert_eq!(decoded.game.tick, 0);
    assert_eq!(decoded.game.shots_used, 0);
    assert_eq!(decoded, init_state(pile10()));
}

/// `step_chunk`'s header on the reference shot: `STATE_IN_HASH` is `serde_hash` of the decoded
/// input state (its golden Python value: `slingfall_game::chunk::tests`); `INPUTS_HASH` is the
/// golden `inputs_hash`; then shot and k.
#[test]
fn test_step_chunk_header() {
    let state = init_payload(pile10_felts());
    let out = step_chunk(state.clone(), to_felts(@reference_inputs()), 0, 5, 0);
    assert_eq!(*out[0], serde_hash(@init_state(pile10())));
    assert_eq!(out.span().slice(1, 3), array![REFERENCE_INPUTS_HASH, 0, 5].span());
    let next: ChunkState = decode(payload(out, STEP_HEADER_LEN).span(), errors::STATE);
    assert_eq!(next.tick, 5);
}

/// `k = 0` returns the state unchanged (a pure round trip) after its header.
#[test]
fn test_step_chunk_k0_is_identity() {
    let state = init_payload(pile10_felts());
    let next = step_payload(state.clone(), to_felts(@reference_inputs()), 0, 0);
    assert_eq!(next, state);
}

#[test]
#[should_panic(expected: ('replay: shot',))]
fn test_step_chunk_rejects_a_shot_not_in_progress() {
    let inputs = Inputs { player: PLAYER, shots: array![shot(-600, -392, 0), shot(1, 1, 0)] };
    step_chunk(init_payload(pile10_felts()), to_felts(@inputs), 1, 1, 0);
}

#[test]
#[should_panic(expected: ('replay: shot',))]
fn test_step_chunk_rejects_a_shot_past_the_inputs() {
    let inputs = Inputs { player: PLAYER, shots: array![] };
    step_chunk(init_payload(pile10_felts()), to_felts(@inputs), 0, 1, 0);
}

#[test]
#[should_panic(expected: ('replay: state',))]
fn test_step_chunk_rejects_another_version() {
    let mut state = init_payload(pile10_felts());
    let _ = state.pop_front();
    let mut other = array![2];
    other.append_span(state.span());
    step_chunk(other, to_felts(@reference_inputs()), 0, 1, 0);
}

#[test]
#[should_panic(expected: ('replay: state',))]
fn test_step_chunk_rejects_trailing_state_felts() {
    let mut state = init_payload(pile10_felts());
    state.append(0);
    step_chunk(state, to_felts(@reference_inputs()), 0, 1, 0);
}

#[test]
#[should_panic(expected: ('replay: inputs',))]
fn test_step_chunk_rejects_bad_inputs() {
    step_chunk(init_payload(pile10_felts()), array![PLAYER], 0, 1, 0);
}

#[test]
#[should_panic(expected: ('inputs: delay',))]
fn test_step_chunk_validates_the_inputs() {
    let inputs = Inputs { player: PLAYER, shots: array![shot(0, 0, 61)] };
    step_chunk(init_payload(pile10_felts()), to_felts(@inputs), 0, 1, 0);
}

#[test]
#[should_panic(expected: ('replay: level',))]
fn test_init_rejects_a_truncated_level() {
    let mut level = pile10_felts();
    let _ = level.pop_front();
    init(level);
}

/// Step probe: `init` on pile10 (decode, validate, build with the settle step, save, serialise,
/// the level header lines).
#[test]
fn steps_init__pile10() {
    opaque(init(opaque(pile10_felts())));
}

/// Step probe: the chunk round trip alone (`k = 0`): decode the state and inputs, restore the
/// world, save it, serialise.
#[test]
fn steps_step_chunk__pile10_round_trip() {
    let state = init_payload(pile10_felts());
    opaque(step_chunk(opaque(state), opaque(to_felts(@reference_inputs())), 0, 0, 0));
}

/// Step probe: the first chunk of the reference shot (`k = 1`: launch and one flight tick).
#[test]
fn steps_step_chunk__pile10_first_tick() {
    let state = init_payload(pile10_felts());
    opaque(step_chunk(opaque(state), opaque(to_felts(@reference_inputs())), 0, 1, 0));
}

/// Step probe: the same chunk with the trace lines.
#[test]
fn steps_step_chunk__pile10_first_tick_trace() {
    let state = init_payload(pile10_felts());
    opaque(step_chunk(opaque(state), opaque(to_felts(@reference_inputs())), 0, 1, 1));
}
