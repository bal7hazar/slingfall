//! The contract's replay (lots G4, G4b): `slingfall_game::play::play` with the noop observer, the
//! proof build's own level logic (the `main` executable of `slingfall_replay` calls the same
//! function).

use slingfall_game::play::{NoopObserver, play};
use slingfall_level::inputs::Inputs;
use slingfall_level::level::Level;
use slingfall_level::outputs::Outputs;
use super::SimulateHook;

/// `simulate`'s replay: validate, build the world, play the shots in order, stop after the shot
/// that wins the level; the D4 outputs. `level` and `inputs` are already validated by
/// `super::run`; `play` validates them again (a few thousand steps against ~32M for a shot).
pub impl ReplaySimulateHook of SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs {
        let mut obs: NoopObserver = Default::default();
        play(level, inputs, ref obs)
    }
}

#[cfg(test)]
mod tests {
    use slingfall_level::hash::to_felts;
    use slingfall_level::inputs::{Inputs, Shot};
    use slingfall_level::level::fixtures::{PILE10_HASH, pile10_felts};
    use slingfall_level::outputs::OutputsTrait;
    use crate::submit::fixtures::PLAYER;
    use super::ReplaySimulateHook;
    use super::super::run;

    /// `slingfall_replay`'s `main` on pile10 with the reference shot (-604, -392), player
    /// `'player'` (`slingfall_game::fixtures::reference_outputs`).
    #[test]
    fn test_simulate_pile10_reference_matches_replay_main() {
        let inputs = Inputs {
            player: PLAYER,
            shots: array![Shot { pull_x: -604, pull_y: -392, delay: 0, ability_tick: 0 }],
        };
        let outputs = run::<ReplaySimulateHook>(pile10_felts().span(), to_felts(@inputs).span());
        let expected: Array<felt252> = array![
            1, PILE10_HASH, 0, PLAYER,
            0x5c242b3f403a2cc4fbf7e6f51d9ceab41baeabb21691fed72ec2cdce0d51d8f, 5200, 1, 1, 107,
            0x135df25e65cc5905398c07fc0fb89cb47ee2360a8704793595e82dd6cfbb255,
        ];
        assert_eq!(outputs.to_felts(), expected);
    }
}
