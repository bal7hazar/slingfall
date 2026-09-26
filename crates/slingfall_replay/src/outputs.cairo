//! `outputs(state, inputs)`: the `docs/DESIGN.md` D4 outputs of a finished chunked replay, the
//! felts a proof of the same level and inputs carries (`level_hash`, `inputs_hash` and
//! `final_state_hash` are Poseidon hashes computed by the replay's own code). The client runs it
//! once after the last `step_chunk` (lots G6b, G4c); `main` over the whole level would need one VM
//! run of every tick, more than a wasm32 memory holds on a three-shot level.

use slingfall_game::chunk::{ChunkState, state_outputs};
use slingfall_game::errors;
use slingfall_game::play::decode;
use slingfall_level::inputs::Inputs;
use slingfall_level::outputs::OutputsTrait;

#[cfg(test)]
mod tests;

/// Arguments: the `ChunkState` felts (length-prefixed, as `step_chunk` returns them) and the
/// `Inputs` felts (length-prefixed). Returns the 10 felts of `Outputs`.
///
/// # Panics
/// `errors::STATE`, `errors::INPUTS`. The inputs are hashed, not replayed: their values were
/// validated by the `step_chunk` calls that produced the state.
#[executable]
pub fn outputs(state: Array<felt252>, inputs: Array<felt252>) -> Array<felt252> {
    let state: ChunkState = decode(state.span(), errors::STATE);
    let inputs: Inputs = decode(inputs.span(), errors::INPUTS);
    state_outputs(state, @inputs).to_felts()
}
