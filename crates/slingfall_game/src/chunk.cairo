//! Chunked build logic: the state of `init(level) -> state` and `step_chunk(state, inputs, k) ->
//! state'` on `rapier2d::WorldState` (`docs/DESIGN.md` D1, D8). Lots G4, G4b. The executables are
//! in `slingfall_replay::chunk`.
//!
//! The state is a [`ChunkState`]: a short header the client reads at fixed offsets, the level
//! (`step_chunk` has no level argument) and the rules' `GameState`. [`step_state`] restores the
//! game and runs `crate::play::step_shot`, the per-shot stepping of `play` itself, with a tick
//! budget: chaining chunks of any sizes gives `main`'s run bit for bit.

use slingfall_level::inputs::{Inputs, InputsTrait};
use slingfall_level::level::{Level, LevelTrait};
use slingfall_level::outputs::Outputs;
use slingfall_rules::world::{Game, GameState, GameTrait};
use crate::errors;
use crate::play::{Observer, ShotProgress, level_over, outputs, step_shot};

#[cfg(test)]
mod tests;

/// Layout version of [`ChunkState`] (its first felt).
pub const CHUNK_STATE_VERSION: u8 = 1;

/// The chunked replay's state. Felts: `[version, shots_used, over, launched, shot_ticks, tick,
/// score, level..., game...]`; the header (7 felts) mirrors the game for the client and is
/// rewritten from it at every save. `game` is `GameState` (its world a `rapier2d::WorldState`).
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct ChunkState {
    /// `CHUNK_STATE_VERSION`.
    pub version: u8,
    /// Shots finished: the shot in progress (or the next one) is this index.
    pub shots_used: u8,
    /// The level is over: no shot in progress, and won or `level.shots` shots used (a shot that
    /// wins goes on until its end). The inputs may end earlier.
    pub over: bool,
    /// Progress of shot `shots_used`: launched, and ticks stepped (delay included).
    pub progress: ShotProgress,
    /// Ticks stepped since the start of the level (the last frame's tick).
    pub tick: u32,
    /// Score so far.
    pub score: u32,
    pub level: Level,
    pub game: GameState,
}

/// Saves `game` with its header.
pub fn save(ref game: Game, level: Level, progress: ShotProgress) -> ChunkState {
    ChunkState {
        version: CHUNK_STATE_VERSION,
        shots_used: game.shots_used,
        over: progress.ticks == 0 && level_over(@game, @level),
        progress,
        tick: game.tick,
        score: game.score,
        game: game.to_state(),
        level,
    }
}

/// The state before the first tick: the level validated and built (settle step included).
pub fn init_state(level: Level) -> ChunkState {
    level.validate();
    let mut game = GameTrait::new(@level);
    save(ref game, level, Default::default())
}

/// Restores `state`, steps at most `k` ticks of shot `shot` (launching it when its delay is
/// done), saves. Returns the new state and the ticks stepped.
///
/// # Panics
/// `errors::STATE` for a state of another version; `errors::SHOT` unless `shot` is the shot in
/// progress (`state.shots_used`), is in `inputs` and the level is not over (`ChunkState.over`).
pub fn step_state<O, +Observer<O>, +Drop<O>>(
    state: ChunkState, inputs: @Inputs, shot: u8, k: u32, ref obs: O,
) -> (ChunkState, u32) {
    let ChunkState {
        version, shots_used: _, over: _, mut progress, tick: _, score: _, level, game,
    } = state;
    if version != CHUNK_STATE_VERSION {
        core::panic_with_felt252(errors::STATE);
    }
    inputs.validate(@level);
    let mut game = GameTrait::from_state(game);
    if shot != game.shots_used
        || shot.into() >= inputs.shots.len()
        || (progress.ticks == 0 && level_over(@game, @level)) {
        core::panic_with_felt252(errors::SHOT);
    }
    let (stepped, _) = step_shot(
        ref game, @level, inputs.shots[shot.into()], ref progress, k, ref obs,
    );
    (save(ref game, level, progress), stepped)
}

/// The outputs of a finished chunked replay (tests, `docs/DESIGN.md` D4): restores the game.
pub fn state_outputs(state: ChunkState, inputs: @Inputs) -> Outputs {
    let ChunkState { level, game, .. } = state;
    let mut game = GameTrait::from_state(game);
    outputs(ref game, @level, inputs)
}
