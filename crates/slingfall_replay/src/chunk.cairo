//! Chunked build executables: `init(level) -> state` and `step_chunk(state, inputs, shot, k, trace)
//! -> state'` (`docs/DESIGN.md` D1, D8). Lot G4. The state and its stepping are
//! `slingfall_game::chunk` (`ChunkState`, `init_state`, `step_state`): chaining chunks of any
//! sizes gives `main`'s run bit for bit.
//!
//! Each returns a binding header, then the new state (lot P1b, `docs/proving.md` "Chunk
//! binding"): the arguments of an executable are private in its proof, the header commits to them.

use slingfall_game::chunk::{ChunkState, init_header, init_state, step_header, step_state};
use slingfall_game::errors;
use slingfall_game::play::{NoopObserver, Observer, decode};
use slingfall_level::inputs::Inputs;
use slingfall_level::level::Level;
use crate::trace::TraceObserverTrait;

#[cfg(test)]
pub mod tests;

/// `init(level)`. Argument: the `Serde` felts of one `Level` (length-prefixed). Returns
/// `[LEVEL_HASH] ++ state`: `LEVEL_HASH` = `poseidon(level felts)` (the D4 `level_hash`), then the
/// `ChunkState` felts. Prints the level header of the trace lines (`crate::trace`), so that the
/// client gets the level from the same run.
///
/// # Panics
/// `errors::LEVEL`, and the level crate's `level: *` messages.
#[executable]
pub fn init(level: Array<felt252>) -> Array<felt252> {
    let mut felts = init_header(level.span());
    let level: Level = decode(level.span(), errors::LEVEL);
    let mut obs = TraceObserverTrait::new();
    obs.on_level(@level);
    init_state(level).serialize(ref felts);
    felts
}

/// `step_chunk(state, inputs, shot, k, trace)`. Arguments: the `ChunkState` felts (as returned
/// by `init` or the previous `step_chunk`, length-prefixed), the `Inputs` felts (length-prefixed),
/// the 0-based shot index, the tick budget `k`, and `trace` (non-zero: print the trace lines of
/// the ticks, `crate::trace`). Returns `[STATE_IN_HASH, INPUTS_HASH, shot, k] ++ state'`: the
/// `poseidon` hashes of the `state` and `inputs` felts (no length prefix), the two scalar
/// arguments, then the new `ChunkState` felts; the shot is over when their `shots_used` (second
/// felt) is `shot + 1`.
///
/// # Panics
/// `errors::STATE`, `errors::INPUTS`, `errors::SHOT`, and the level crate's `inputs: *` messages.
#[executable]
pub fn step_chunk(
    state: Array<felt252>, inputs: Array<felt252>, shot: u8, k: u32, trace: u8,
) -> Array<felt252> {
    let mut felts = step_header(state.span(), inputs.span(), shot, k);
    let state: ChunkState = decode(state.span(), errors::STATE);
    let inputs: Inputs = decode(inputs.span(), errors::INPUTS);
    let (state, _) = if trace != 0 {
        let mut obs = TraceObserverTrait::resume(
            @state.level, state.game.entities.span(), state.game.score,
        );
        step_state(state, @inputs, shot, k, ref obs)
    } else {
        let mut obs: NoopObserver = Default::default();
        step_state(state, @inputs, shot, k, ref obs)
    };
    state.serialize(ref felts);
    felts
}
