//! `outputs(state, inputs)`: the `docs/DESIGN.md` D4 outputs of a finished chunked replay, the
//! felts a proof of the same level and inputs carries (`level_hash`, `inputs_hash` and
//! `final_state_hash` are Poseidon hashes computed by the replay's own code). The client runs it
//! once after the last `step_chunk` (lot G6b); `main` over the whole level would need one VM run
//! of every tick, more than a wasm32 memory holds on a three-shot level.

use slingfall_level::inputs::Inputs;
use slingfall_replay::chunk::{ChunkState, state_outputs};
use slingfall_replay::main::{decode, errors};

/// Arguments: the `ChunkState` felts (length-prefixed, as `step_chunk` returns them) and the
/// `Inputs` felts (length-prefixed). Returns the 10 felts of `Outputs`.
///
/// # Panics
/// `errors::STATE`, `errors::INPUTS`.
#[executable]
fn outputs(state: Array<felt252>, inputs: Array<felt252>) -> Array<felt252> {
    let state: ChunkState = decode(state.span(), errors::STATE);
    let inputs: Inputs = decode(inputs.span(), errors::INPUTS);
    let mut felts: Array<felt252> = array![];
    state_outputs(state, @inputs).serialize(ref felts);
    felts
}
