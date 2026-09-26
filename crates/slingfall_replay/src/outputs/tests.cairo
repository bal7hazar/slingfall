use slingfall_game::fixtures::{PLAYER, reference_inputs, reference_outputs};
use slingfall_level::hash::to_felts;
use slingfall_level::inputs::Inputs;
use slingfall_level::level::fixtures::pile10_felts;
use slingfall_testing::opaque;
use crate::chunk::{init, step_chunk};
use super::outputs;

/// `init`, then `step_chunk` with budget `k` until the first shot is over: the state `outputs`
/// runs on.
fn played(inputs: @Inputs, k: u32) -> Array<felt252> {
    let inputs_felts = to_felts(inputs);
    let mut state = init(pile10_felts());
    while *state[1] == 0 {
        state = step_chunk(state, inputs_felts.clone(), 0, k, 0);
    }
    state
}

/// Golden: pile10, reference shot [-600, -392, 0], chunks of 60 ticks: `main`'s 10 felts.
#[test]
fn test_outputs_pile10_reference() {
    let inputs = reference_inputs();
    assert_eq!(outputs(played(@inputs, 60), to_felts(@inputs)), reference_outputs());
}

/// The chunk size does not change the outputs.
#[test]
fn test_outputs_do_not_depend_on_the_chunk_size() {
    let inputs = reference_inputs();
    assert_eq!(outputs(played(@inputs, 7), to_felts(@inputs)), reference_outputs());
}

#[test]
#[should_panic(expected: ('replay: state',))]
fn test_outputs_rejects_an_empty_state() {
    outputs(array![], to_felts(@reference_inputs()));
}

#[test]
#[should_panic(expected: ('replay: state',))]
fn test_outputs_rejects_trailing_state_felts() {
    let mut state = init(pile10_felts());
    state.append(0);
    outputs(state, to_felts(@reference_inputs()));
}

#[test]
#[should_panic(expected: ('replay: inputs',))]
fn test_outputs_rejects_bad_inputs() {
    outputs(init(pile10_felts()), array![PLAYER]);
}

/// Step probe: `outputs` on the state of `init` (decode, restore, hashes, serialise; the probe
/// includes `init`'s own steps, whose probe is `steps_init__pile10`; the `scarb execute` figure of
/// the finished state is in the lot report).
#[test]
fn steps_outputs__pile10_init_state() {
    let state = init(pile10_felts());
    opaque(outputs(opaque(state), opaque(to_felts(@reference_inputs()))));
}
