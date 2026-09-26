use core::poseidon::poseidon_hash_span;
use slingfall_level::hash::{serde_hash, to_felts};
use slingfall_level::inputs::Inputs;
use slingfall_level::level::fixtures::{PILE10_HASH, pile10, pile10_felts};
use slingfall_testing::opaque;
use crate::fixtures::{PLAYER, REFERENCE_INPUTS_HASH, reference_inputs, shot};
use crate::play::NoopObserver;
use super::{
    CHUNK_STATE_VERSION, INIT_HEADER_LEN, OUTPUTS_HEADER_LEN, STEP_HEADER_LEN, hash_felts,
    init_header, init_state, outputs_header, step_header, step_state,
};

/// Golden: `poseidon_hash_span` of the 3 001 `ChunkState` felts of `init_state(pile10())`, no
/// length prefix, recomputed in Python (`tools/levelc/poseidon.py` on the felts `init` returns
/// after its header, `scarb execute`; lot P1b).
const PILE10_INIT_STATE_HASH: felt252 =
    0x30f69f404f602598bbd9c6c5154347898f17caf810bbb5aec7f6c0e17f708fc;

/// `init_state`: version 1, nothing played, the level not over.
#[test]
fn test_init_state_header() {
    let state = init_state(pile10());
    assert_eq!(state.version, CHUNK_STATE_VERSION);
    assert_eq!((state.shots_used, state.over, state.tick, state.score), (0, false, 0, 0));
    assert_eq!((state.progress.launched, state.progress.ticks), (false, 0));
}

/// A budget of 0 is a pure round trip: the state comes back unchanged.
#[test]
fn test_step_state_k0_is_identity() {
    let mut obs: NoopObserver = Default::default();
    let (next, stepped) = step_state(init_state(pile10()), @reference_inputs(), 0, 0, ref obs);
    assert_eq!(stepped, 0);
    assert_eq!(next, init_state(pile10()));
}

#[test]
#[should_panic(expected: ('replay: shot',))]
fn test_step_state_rejects_a_shot_not_in_progress() {
    let inputs = Inputs { player: PLAYER, shots: array![shot(-600, -392, 0), shot(1, 1, 0)] };
    let mut obs: NoopObserver = Default::default();
    step_state(init_state(pile10()), @inputs, 1, 1, ref obs);
}

/// A state's hash is `serde_hash` of the `ChunkState`: its `Serde` felts, no length prefix; the
/// Python recomputation agrees.
#[test]
fn test_state_hash_is_serde_hash() {
    let state = init_state(pile10());
    let felts = to_felts(@state);
    assert_eq!(felts.len(), 3001);
    assert_eq!(serde_hash(@state), poseidon_hash_span(felts.span()));
    assert_eq!(serde_hash(@state), PILE10_INIT_STATE_HASH);
}

/// The binding headers and their lengths (`docs/proving.md` "Chunk binding").
#[test]
fn test_binding_headers() {
    let state = to_felts(@init_state(pile10()));
    let inputs = to_felts(@reference_inputs());
    let init = init_header(pile10_felts().span());
    assert_eq!(init, array![PILE10_HASH]);
    assert_eq!(init.len(), INIT_HEADER_LEN);
    let step = step_header(state.span(), inputs.span(), 2, 16);
    assert_eq!(step, array![PILE10_INIT_STATE_HASH, REFERENCE_INPUTS_HASH, 2, 16]);
    assert_eq!(step.len(), STEP_HEADER_LEN);
    let outputs = outputs_header(state.span(), inputs.span());
    assert_eq!(outputs, array![PILE10_INIT_STATE_HASH, REFERENCE_INPUTS_HASH]);
    assert_eq!(outputs.len(), OUTPUTS_HEADER_LEN);
}

/// Step probe, the reference of the next one: pile10's initial state as felts.
#[test]
fn steps_state_felts__pile10_init() {
    opaque(to_felts(@init_state(opaque(pile10()))));
}

/// Step probe: the same, then `step_header` on it (lot P1b; minus the previous probe: the cost
/// of `STATE_IN_HASH` over 3 001 felts and `INPUTS_HASH`).
#[test]
fn steps_step_header__pile10_init() {
    let state = to_felts(@init_state(opaque(pile10())));
    opaque(step_header(opaque(state).span(), to_felts(@reference_inputs()).span(), 0, 16));
}

/// `hash_felts` is `poseidon_hash_span` on every length mod 8 and both parities (the padding),
/// and on the empty span.
#[test]
fn test_hash_felts_is_poseidon_hash_span() {
    let mut felts: Array<felt252> = array![];
    let mut i: felt252 = 0;
    while felts.len() != 40 {
        assert_eq!(hash_felts(felts.span()), poseidon_hash_span(felts.span()));
        felts.append(i * 0x1234567 - 5);
        i += 1;
    }
    let state = to_felts(@init_state(pile10()));
    assert_eq!(hash_felts(state.span()), PILE10_INIT_STATE_HASH);
}

/// Step probe: `hash_felts` over pile10's initial state (3 001 felts), minus
/// `steps_state_felts__pile10_init`.
#[test]
fn steps_hash_felts__pile10_init() {
    let state = to_felts(@init_state(opaque(pile10())));
    opaque(hash_felts(opaque(state).span()));
}

/// Hash candidates on the same 3 001 felts (`AGENTS.md` §2.5), same reference probe.
mod alternatives {
    use core::poseidon::{hades_permutation, poseidon_hash_span};
    use slingfall_level::hash::to_felts;
    use slingfall_level::level::fixtures::pile10;
    use slingfall_testing::opaque;
    use super::super::{hash_felts, init_state};

    /// `hash_felts` with 8 felts per iteration.
    fn hash_felts_8(felts: Span<felt252>) -> felt252 {
        let mut felts = felts;
        let (mut s0, mut s1, mut s2) = (0, 0, 0);
        while let Some(block) = felts.multi_pop_front::<8>() {
            let [a0, a1, a2, a3, a4, a5, a6, a7] = (*block).unbox();
            let (t0, t1, t2) = hades_permutation(s0 + a0, s1 + a1, s2);
            let (t0, t1, t2) = hades_permutation(t0 + a2, t1 + a3, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a4, t1 + a5, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a6, t1 + a7, t2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
        }
        let (h, _, _) = loop {
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
        };
        h
    }

    fn hash_felts_pop8(felts: Span<felt252>) -> felt252 {
        let mut felts = felts;
        let (mut s0, mut s1, mut s2) = (0, 0, 0);
        let (h, _, _) = loop {
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
        };
        h
    }

    /// 16 felts per iteration with `multi_pop_front`: the fastest (19.1k), but its
    /// `TestLessThanOrEqualAddress` hint fails in the client's cairo-vm.
    fn hash_felts_multi_pop16(felts: Span<felt252>) -> felt252 {
        let mut felts = felts;
        let (mut s0, mut s1, mut s2) = (0, 0, 0);
        while let Some(block) = felts.multi_pop_front::<16>() {
            let [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15] = (*block)
                .unbox();
            let (t0, t1, t2) = hades_permutation(s0 + a0, s1 + a1, s2);
            let (t0, t1, t2) = hades_permutation(t0 + a2, t1 + a3, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a4, t1 + a5, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a6, t1 + a7, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a8, t1 + a9, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a10, t1 + a11, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a12, t1 + a13, t2);
            let (t0, t1, t2) = hades_permutation(t0 + a14, t1 + a15, t2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
        }
        let (h, _, _) = loop {
            let Some(x) = felts.pop_front() else {
                break hades_permutation(s0 + 1, s1, s2);
            };
            let Some(y) = felts.pop_front() else {
                break hades_permutation(s0 + *x, s1 + 1, s2);
            };
            let (t0, t1, t2) = hades_permutation(s0 + *x, s1 + *y, s2);
            s0 = t0;
            s1 = t1;
            s2 = t2;
        };
        h
    }

    #[test]
    fn test_alt_hash_felts_pop8_multi_pop16() {
        let state = to_felts(@init_state(pile10()));
        assert_eq!(hash_felts_pop8(state.span()), hash_felts(state.span()));
        assert_eq!(hash_felts_multi_pop16(state.span()), hash_felts(state.span()));
        let mut felts: Array<felt252> = array![];
        while felts.len() != 40 {
            assert_eq!(hash_felts_pop8(felts.span()), poseidon_hash_span(felts.span()));
            assert_eq!(hash_felts_multi_pop16(felts.span()), poseidon_hash_span(felts.span()));
            felts.append(felts.len().into() * 7 + 1);
        }
    }

    #[test]
    fn steps_alt_hash_felts_pop8__pile10_init() {
        let state = to_felts(@init_state(opaque(pile10())));
        opaque(hash_felts_pop8(opaque(state).span()));
    }

    #[test]
    fn steps_alt_hash_felts_multi_pop16__pile10_init() {
        let state = to_felts(@init_state(opaque(pile10())));
        opaque(hash_felts_multi_pop16(opaque(state).span()));
    }

    #[test]
    fn test_alt_hash_felts_8() {
        let state = to_felts(@init_state(pile10()));
        assert_eq!(hash_felts_8(state.span()), hash_felts(state.span()));
    }

    /// 8 felts per iteration.
    #[test]
    fn steps_alt_hash_felts_8__pile10_init() {
        let state = to_felts(@init_state(opaque(pile10())));
        opaque(hash_felts_8(opaque(state).span()));
    }

    /// The corelib sponge, one permutation per loop iteration.
    #[test]
    fn steps_alt_poseidon_hash_span__pile10_init() {
        let state = to_felts(@init_state(opaque(pile10())));
        opaque(poseidon_hash_span(opaque(state).span()));
    }
}
