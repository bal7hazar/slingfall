//! Proof build: `main(level, inputs) -> outputs` at 60 Hz, no prints (`docs/DESIGN.md` D1).
//! Lot G4.
//!
//! [`play`] is the level logic shared by the three builds: validate, build the world, play each
//! shot (delay, launch, ticks until the shot is over, pebble removal), stop when the level is won
//! or the shots are exhausted, and return the D4 [`Outputs`]. An [`Observer`] sees the level, every
//! tick and the end of every shot; [`NoopObserver`] is the proof build's (empty, inlined: the step
//! counts of `main` and of the rules alone agree, see the README). The per-shot stepping is
//! [`step_shot`], which the chunked build (`crate::chunk`) runs with a tick budget: both builds go
//! through the same code, so a chained run is the uninterrupted one bit for bit.

use slingfall_level::inputs::{Inputs, InputsTrait, Shot};
use slingfall_level::level::{Level, LevelTrait};
use slingfall_level::outputs::{Outputs, OutputsTrait};
use slingfall_rules::world::{Game, GameTrait, TickReport};
use slingfall_rules::{score, sling};

#[cfg(test)]
pub mod fixtures;
#[cfg(test)]
pub mod tests;

/// Panic messages of the replay executables (`felt252` short strings, stable API, `AGENTS.md` §7).
pub mod errors {
    /// The `level` argument is not exactly the felts of one `Level`.
    pub const LEVEL: felt252 = 'replay: level';
    /// The `inputs` argument is not exactly the felts of one `Inputs`.
    pub const INPUTS: felt252 = 'replay: inputs';
    /// The `state` argument of `step_chunk` is not exactly one `ChunkState` of this version.
    pub const STATE: felt252 = 'replay: state';
    /// `step_chunk`'s `shot` is not the shot in progress, is past the inputs, or the level is over.
    pub const SHOT: felt252 = 'replay: shot';
}

/// Watches a replay. Every method is called by the shared level logic ([`play`], [`step_shot`]);
/// the proof build's [`NoopObserver`] does nothing, the trace build's
/// `crate::trace::TraceObserver` prints trace format v1.
pub trait Observer<O> {
    /// Once, before the world is built (the level is already validated).
    fn on_level(ref self: O, level: @Level);
    /// After every tick (delay ticks included), with what the tick did.
    fn on_tick(ref self: O, ref game: Game, report: @TickReport);
    /// After the end of shot `shot` (0-based): the pebble is removed, the shot counted and, when
    /// the level is won, the unused shots scored.
    fn on_shot_end(ref self: O, ref game: Game, shot: u8);
}

/// The proof build's observer: nothing.
#[derive(Copy, Drop, Default)]
pub struct NoopObserver {}

pub impl NoopObserverImpl of Observer<NoopObserver> {
    #[inline(always)]
    fn on_level(ref self: NoopObserver, level: @Level) {}

    #[inline(always)]
    fn on_tick(ref self: NoopObserver, ref game: Game, report: @TickReport) {}

    #[inline(always)]
    fn on_shot_end(ref self: NoopObserver, ref game: Game, shot: u8) {}
}

/// Where the shot in progress is. Part of the chunked state (`crate::chunk::ChunkState`).
#[derive(Copy, Drop, Serde, PartialEq, Debug, Default)]
pub struct ShotProgress {
    /// The pebble was launched (the `delay` ticks are done).
    pub launched: bool,
    /// Ticks of this shot stepped so far, the delay included.
    pub ticks: u32,
}

/// Steps the shot in progress by at most `budget` ticks, exactly as `GameTrait::play_shot`: the
/// `shot.delay` ticks without a pebble, the launch (right before the next tick), ticks until the
/// shot is over, then `GameTrait::end_shot`. Returns the ticks stepped and whether the shot ended;
/// on the end, `progress` is reset for the next shot. The caller checks that the level is not over.
pub fn step_shot<O, +Observer<O>, +Drop<O>>(
    ref game: Game, level: @Level, shot: @Shot, ref progress: ShotProgress, budget: u32, ref obs: O,
) -> (u32, bool) {
    let delay: u32 = (*shot.delay).into();
    let mut stepped: u32 = 0;
    let mut over = false;
    while stepped != budget {
        if !progress.launched && progress.ticks == delay {
            sling::launch(ref game, level, shot);
            progress.launched = true;
        }
        let report = game.tick(level);
        progress.ticks += 1;
        stepped += 1;
        obs.on_tick(ref game, @report);
        // Delay ticks never end a shot (`play_shot` ignores their reports).
        if progress.launched && report.shot_over {
            let index = game.shots_used;
            game.end_shot(level, !report.capped);
            obs.on_shot_end(ref game, index);
            progress = Default::default();
            over = true;
            break;
        }
    }
    (stepped, over)
}

/// The level is over: won, or every shot of the level used.
pub fn level_over(game: @Game, level: @Level) -> bool {
    score::won(game) || *game.shots_used >= *level.shots
}

/// Plays `inputs` on `level` and returns the D4 outputs. Validates both (`LevelTrait::validate`,
/// `InputsTrait::validate`); plays the shots in order and stops after the shot that wins the level
/// (the remaining shots are not played). `shots_used` counts the shots played, `ticks_run` every
/// tick stepped (delays included).
pub fn play<O, +Observer<O>, +Drop<O>>(level: @Level, inputs: @Inputs, ref obs: O) -> Outputs {
    level.validate();
    inputs.validate(level);
    obs.on_level(level);
    let mut game = GameTrait::new(level);
    for shot in inputs.shots.span() {
        if score::won(@game) {
            break;
        }
        let mut progress: ShotProgress = Default::default();
        let _ = step_shot(ref game, level, shot, ref progress, 0xffffffff, ref obs);
    }
    outputs(ref game, level, inputs)
}

/// The D4 outputs of `game` (its identity fields from `level` and `inputs`).
pub fn outputs(ref game: Game, level: @Level, inputs: @Inputs) -> Outputs {
    Outputs {
        version: *level.version,
        level_hash: game.level_hash,
        seed: *level.seed,
        player: *inputs.player,
        inputs_hash: inputs.hash(),
        score: game.score,
        won: score::won(@game),
        shots_used: game.shots_used,
        ticks_run: game.tick,
        final_state_hash: game.final_state_hash(),
    }
}

/// Deserialises exactly one `T` from `felts`, else panics with `error`.
pub fn decode<T, +Serde<T>, +Drop<T>>(felts: Span<felt252>, error: felt252) -> T {
    let mut felts = felts;
    let value: Option<T> = Serde::deserialize(ref felts);
    let Some(value) = value else {
        core::panic_with_felt252(error)
    };
    if !felts.is_empty() {
        core::panic_with_felt252(error);
    }
    value
}

/// Proof build. Arguments: `level` = the `Serde` felts of one `Level`, `inputs` = those of one
/// `Inputs` (both length-prefixed arrays on the command line). Returns the 10 felts of `Outputs`.
///
/// # Panics
/// `errors::LEVEL` / `errors::INPUTS` for felts that are not exactly one value; the level crate's
/// `level: *` / `inputs: *` messages for values that break its rules.
#[executable]
pub fn main(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252> {
    let level: Level = decode(level.span(), errors::LEVEL);
    let inputs: Inputs = decode(inputs.span(), errors::INPUTS);
    let mut obs: NoopObserver = Default::default();
    play(@level, @inputs, ref obs).to_felts()
}
