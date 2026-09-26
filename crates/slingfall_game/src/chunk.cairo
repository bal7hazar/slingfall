//! Chunked build logic: the state of `init(level) -> state` and `step_chunk(state, inputs, k) ->
//! state'` on `rapier2d::WorldState` (`docs/DESIGN.md` D1, D8). Lots G4, G4b. The executables are
//! in `slingfall_replay::chunk`.
//!
//! The state is a [`ChunkState`]: a short header the client reads at fixed offsets, the level
//! (`step_chunk` has no level argument) and the rules' `GameState`. [`step_state`] restores the
//! game and runs `crate::play::step_shot`, the per-shot stepping of `play` itself, with a tick
//! budget: chaining chunks of any sizes gives `main`'s run bit for bit.
//!
//! Chunk binding (lot P1b, `docs/proving.md`): an executable's arguments are private in its proof,
//! so each chunked executable's public output starts with a header that commits to them
//! ([`init_header`], [`step_header`], [`outputs_header`]). A hash of an argument is
//! `poseidon_hash_span` ([`hash_felts`]) of its `Serde` felts, **without** the array's length
//! prefix: for a state, exactly the felts that `init` / `step_chunk` output after their header, and
//! the same function as `slingfall_level::hash::serde_hash` on the decoded value (`level_hash`,
//! `inputs_hash`).

use core::poseidon::hades_permutation;
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

/// Felts of `init`'s header: `[LEVEL_HASH]`.
pub const INIT_HEADER_LEN: u32 = 1;
/// Felts of `step_chunk`'s header: `[STATE_IN_HASH, INPUTS_HASH, shot, k]`.
pub const STEP_HEADER_LEN: u32 = 4;
/// Felts of `outputs`' header: `[STATE_IN_HASH, INPUTS_HASH]`.
pub const OUTPUTS_HEADER_LEN: u32 = 2;

/// `core::poseidon::poseidon_hash_span(felts)`, bit for bit (the same sponge: absorb two felts
/// per permutation, then pad with 1), with 16 felts absorbed per loop iteration: on pile10's
/// 3 001-felt state, 19.1k steps against the corelib's 43.5k (snforge probes
/// `chunk::tests::steps_*hash*`, the losers in `chunk::tests::alternatives`).
pub fn hash_felts(felts: Span<felt252>) -> felt252 {
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

/// `init(level)`'s header: `[poseidon(level felts)]`, the D4 `level_hash` of the level.
pub fn init_header(level: Span<felt252>) -> Array<felt252> {
    array![hash_felts(level)]
}

/// `step_chunk(state, inputs, shot, k)`'s header: `[poseidon(state felts), poseidon(inputs
/// felts), shot, k]`.
pub fn step_header(
    state: Span<felt252>, inputs: Span<felt252>, shot: u8, k: u32,
) -> Array<felt252> {
    array![hash_felts(state), hash_felts(inputs), shot.into(), k.into()]
}

/// `outputs(state, inputs)`'s header: `[poseidon(state felts), poseidon(inputs felts)]`.
pub fn outputs_header(state: Span<felt252>, inputs: Span<felt252>) -> Array<felt252> {
    array![hash_felts(state), hash_felts(inputs)]
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
