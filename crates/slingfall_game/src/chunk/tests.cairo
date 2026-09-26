use slingfall_level::inputs::Inputs;
use slingfall_level::level::fixtures::pile10;
use crate::fixtures::{PLAYER, reference_inputs, shot};
use crate::play::NoopObserver;
use super::{CHUNK_STATE_VERSION, init_state, step_state};

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
