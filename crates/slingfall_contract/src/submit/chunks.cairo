//! The SNIP-36 tier's links (`docs/contract-v3.md`): the three message payloads of a chain
//! contract (research 07 §4, `slingfall_split::chain`, known here only by their felts), parsed
//! into what `submit_chunk` stores, and the stored step (`Edge`).
//!
//! | kind | payload | stored |
//! |---|---|---|
//! | `INIT` | `[LEVEL_HASH, STATE_OUT_HASH]` | `start[(chain, LEVEL_HASH)] = STATE_OUT_HASH` |
//! | `STEP` | `[STATE_IN_HASH, INPUTS_HASH, shot, k, STATE_OUT_HASH]` | `edge[(chain, INPUTS_HASH,
//! STATE_IN_HASH)] = Edge { shot, k, next: STATE_OUT_HASH }` |
//! | `OUTPUTS` | `[STATE_IN_HASH, INPUTS_HASH] ++ outputs` (10 felts) | `end[(chain, INPUTS_HASH,
//! STATE_IN_HASH)] = poseidon(outputs)` |

use core::poseidon::poseidon_hash_span;
use slingfall_level::outputs::OutputsTrait;
use super::errors;

/// The kinds of `submit_chunk`, in the chain's order.
pub mod kind {
    pub const INIT: u8 = 0;
    pub const STEP: u8 = 1;
    pub const OUTPUTS: u8 = 2;
}

/// The most steps `finalize` walks. The owner's shot is 5 (layout e) to 7 (layout b) chunks
/// (research 07 §4); a level has at most `SHOTS_MAX` shots. Gas per step: `docs/contract-v3.md`.
pub const MAX_EDGES: u32 = 64;

/// One `step_chunk` of an attempt: `shot` ran for at most `k` ticks and led to the state `next`.
/// All zero when there is none (`next == 0`).
#[derive(Copy, Drop, Serde, PartialEq, Debug, Default)]
pub struct Edge {
    pub shot: u8,
    pub k: u32,
    pub next: felt252,
}

/// `Edge` in storage: `next`, then `shot << 32 | k`.
#[derive(Copy, Drop, starknet::Store)]
pub struct PackedEdge {
    next: felt252,
    meta: u64,
}

const TWO_32: u64 = 0x100000000;

pub impl EdgeStorePacking of starknet::storage_access::StorePacking<Edge, PackedEdge> {
    fn pack(value: Edge) -> PackedEdge {
        PackedEdge { next: value.next, meta: value.shot.into() * TWO_32 + value.k.into() }
    }

    fn unpack(value: PackedEdge) -> Edge {
        let (shot, k) = DivRem::div_rem(value.meta, TWO_32.try_into().unwrap());
        Edge { shot: shot.try_into().unwrap(), k: k.try_into().unwrap(), next: value.next }
    }
}

/// A parsed payload.
#[derive(Copy, Drop, PartialEq, Debug)]
pub enum Chunk {
    Init: (felt252, felt252),
    /// `(inputs_hash, state_in_hash, edge)`.
    Step: (felt252, felt252, Edge),
    /// `(inputs_hash, state_in_hash, poseidon(outputs))`.
    Outputs: (felt252, felt252, felt252),
}

/// The link a payload of `kind` states.
///
/// # Panics
/// `errors::CHUNK_KIND` for an unknown kind; `errors::CHUNK_PAYLOAD` unless the payload has the
/// kind's length, non-zero state hashes, and: for `STEP`, a `u8` shot, a `u32` `k >= 1` and a new
/// state (`k = 0` is the no-op the chain allows, a loop here); for `OUTPUTS`, outputs that decode
/// (`outputs: *`) and carry the payload's `INPUTS_HASH`.
pub fn parse(kind: u8, payload: Span<felt252>) -> Chunk {
    if kind == kind::INIT {
        assert(payload.len() == 2, errors::CHUNK_PAYLOAD);
        let (level_hash, state) = (*payload[0], *payload[1]);
        assert(state != 0, errors::CHUNK_PAYLOAD);
        return Chunk::Init((level_hash, state));
    }
    if kind == kind::STEP {
        assert(payload.len() == 5, errors::CHUNK_PAYLOAD);
        let (state_in, inputs_hash, next) = (*payload[0], *payload[1], *payload[4]);
        let shot: Option<u8> = (*payload[2]).try_into();
        let k: Option<u32> = (*payload[3]).try_into();
        let (Some(shot), Some(k)) = (shot, k) else {
            core::panic_with_felt252(errors::CHUNK_PAYLOAD)
        };
        assert(k != 0 && state_in != 0 && next != 0 && next != state_in, errors::CHUNK_PAYLOAD);
        return Chunk::Step((inputs_hash, state_in, Edge { shot, k, next }));
    }
    assert(kind == kind::OUTPUTS, errors::CHUNK_KIND);
    assert(payload.len() == 12, errors::CHUNK_PAYLOAD);
    let (state_in, inputs_hash) = (*payload[0], *payload[1]);
    let outputs = payload.slice(2, 10);
    let claim = OutputsTrait::from_felts(outputs);
    assert(state_in != 0 && claim.inputs_hash == inputs_hash, errors::CHUNK_PAYLOAD);
    Chunk::Outputs((inputs_hash, state_in, poseidon_hash_span(outputs)))
}

#[cfg(test)]
mod tests {
    use slingfall_level::outputs::OutputsTrait;
    use slingfall_testing::opaque;
    use crate::submit::fixtures::golden_claim;
    use super::{Chunk, Edge, EdgeStorePacking, kind, parse};

    fn outputs_payload(state_in: felt252, inputs_hash: felt252) -> Array<felt252> {
        let mut payload = array![state_in, inputs_hash];
        payload.append_span(golden_claim().to_felts().span());
        payload
    }

    #[test]
    fn test_edge_packing_round_trips() {
        let edges = array![
            Edge { shot: 0, k: 1, next: 1 }, Edge { shot: 255, k: 0xffffffff, next: -1 },
            Edge { shot: 3, k: 20, next: 0x1234 }, Default::default(),
        ];
        for edge in edges {
            assert_eq!(EdgeStorePacking::unpack(EdgeStorePacking::pack(edge)), edge);
        }
    }

    #[test]
    fn test_parse_the_three_kinds() {
        assert_eq!(parse(kind::INIT, array![0x1e, 0x50].span()), Chunk::Init((0x1e, 0x50)));
        let step = parse(kind::STEP, array![0x50, 0xabc, 2, 20, 0x51].span());
        assert_eq!(step, Chunk::Step((0xabc, 0x50, Edge { shot: 2, k: 20, next: 0x51 })));
        let payload = outputs_payload(0x51, 0xabc);
        let hash = core::poseidon::poseidon_hash_span(golden_claim().to_felts().span());
        assert_eq!(parse(kind::OUTPUTS, payload.span()), Chunk::Outputs((0xabc, 0x51, hash)));
    }

    #[test]
    #[should_panic(expected: 'chunk: kind')]
    fn test_parse_unknown_kind() {
        parse(3, array![0x1e, 0x50].span());
    }

    #[test]
    #[should_panic(expected: 'chunk: payload')]
    fn test_parse_init_zero_state() {
        parse(kind::INIT, array![0x1e, 0].span());
    }

    #[test]
    #[should_panic(expected: 'chunk: payload')]
    fn test_parse_init_length() {
        parse(kind::INIT, array![0x1e, 0x50, 0].span());
    }

    #[test]
    #[should_panic(expected: 'chunk: payload')]
    fn test_parse_step_k_zero() {
        parse(kind::STEP, array![0x50, 0xabc, 0, 0, 0x51].span());
    }

    #[test]
    #[should_panic(expected: 'chunk: payload')]
    fn test_parse_step_same_state() {
        parse(kind::STEP, array![0x50, 0xabc, 0, 10, 0x50].span());
    }

    #[test]
    #[should_panic(expected: 'chunk: payload')]
    fn test_parse_step_shot_not_u8() {
        parse(kind::STEP, array![0x50, 0xabc, 256, 10, 0x51].span());
    }

    #[test]
    #[should_panic(expected: 'chunk: payload')]
    fn test_parse_outputs_of_other_inputs() {
        parse(kind::OUTPUTS, outputs_payload(0x51, 0xabd).span());
    }

    #[test]
    #[should_panic(expected: 'chunk: payload')]
    fn test_parse_outputs_length() {
        let mut payload = outputs_payload(0x51, 0xabc);
        let _ = payload.pop_front();
        parse(kind::OUTPUTS, payload.span());
    }

    /// Outputs that do not decode (`won` not a bool).
    #[test]
    #[should_panic(expected: 'outputs: field')]
    fn test_parse_outputs_malformed() {
        let mut payload = array![0x51, 0xabc];
        let mut felts = golden_claim().to_felts().span();
        for i in 0..10_u32 {
            let felt = *felts.pop_front().unwrap();
            payload.append(if i == 6 {
                2
            } else {
                felt
            });
        }
        parse(kind::OUTPUTS, payload.span());
    }

    #[test]
    fn steps_chunk_parse__outputs() {
        let payload = opaque(outputs_payload(0x51, 0xabc));
        opaque(parse(kind::OUTPUTS, payload.span()));
    }
}
