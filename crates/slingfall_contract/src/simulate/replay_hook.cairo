//! The contract's replay (lot G4): the level logic of `slingfall_replay::main::play` with the
//! noop observer, written against the rules the contract already depends on.
//!
//! `play` itself lives in the nested `slingfall_replay` package (an executable, outside the
//! workspace), which this crate cannot depend on without a manifest change (orchestrator-owned):
//! until the shared library split lands, this is the same loop through
//! `GameTrait::play_shot` (which `play` matches step for step: `slingfall_replay`'s
//! `steps_rules__pile10_reference` probe), and the test below pins it to `main`'s golden outputs.

use slingfall_level::inputs::{Inputs, InputsTrait};
use slingfall_level::level::Level;
use slingfall_level::outputs::Outputs;
use slingfall_rules::score;
use slingfall_rules::world::GameTrait;
use super::SimulateHook;

/// `simulate`'s replay: build the world, play the shots in order, stop after the shot that wins
/// the level; the D4 outputs. `level` and `inputs` are already validated (`super::run`).
pub impl ReplaySimulateHook of SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs {
        let mut game = GameTrait::new(level);
        for shot in inputs.shots.span() {
            if score::won(@game) {
                break;
            }
            let _ = game.play_shot(level, shot);
        }
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
}

#[cfg(test)]
mod tests {
    use slingfall_level::hash::to_felts;
    use slingfall_level::inputs::{Inputs, Shot};
    use slingfall_level::outputs::OutputsTrait;
    use crate::submit::fixtures::{PILE10_HASH, PLAYER, pile10_felts};
    use super::ReplaySimulateHook;
    use super::super::run;

    /// `slingfall_replay`'s `main` on pile10 with the reference shot (-600, -392), player
    /// `'player'` (`crates/slingfall_replay/src/main/tests.cairo`, `reference_outputs`).
    #[test]
    fn test_simulate_pile10_reference_matches_replay_main() {
        let inputs = Inputs {
            player: PLAYER,
            shots: array![Shot { pull_x: -600, pull_y: -392, delay: 0, ability_tick: 0 }],
        };
        let outputs = run::<ReplaySimulateHook>(pile10_felts().span(), to_felts(@inputs).span());
        let expected: Array<felt252> = array![
            1, PILE10_HASH, 0, PLAYER,
            0x31b10e77b97a88153b1e9d781ecddece54061fe1cf88e6a3660eee99fda4f3b, 5350, 1, 1, 191,
            0x2ff3945fee21a4cc7f9447a645a65108dd2a7e697f0c06e75ef0475bbef13e9,
        ];
        assert_eq!(outputs.to_felts(), expected);
    }
}
