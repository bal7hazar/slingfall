//! `simulate(level_hash, inputs)`: the level logic run in the SNIP-36 virtual OS, emitting the
//! outputs as an L2 to L1 message (`docs/DESIGN.md` D9). The replay itself is behind
//! `SimulateHook`; `ActiveHook` is `slingfall_game::play::play` (lot G4b).

use slingfall_level::inputs::{Inputs, InputsTrait};
use slingfall_level::level::{Level, LevelTrait};
use slingfall_level::outputs::Outputs;
use crate::submit::errors;

pub mod class;
pub mod replay_hook;

/// `to_address` of the message `simulate` sends: the message never reaches L1, it is a proof fact
/// `submit` looks for (`verifier::Snip36Verifier`).
pub const MARKER: felt252 = 'SLINGFALL';

/// A replay: the `Outputs` (`docs/DESIGN.md` D4) of `inputs` played on `level`. Both are already
/// validated (`LevelTrait::validate` at registration, `InputsTrait::validate` in `run`).
pub trait SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs;
}

/// Placeholder until lot G4: echoes the identity fields of the level and inputs (`version`,
/// `level_hash`, `seed`, `player`, `inputs_hash`, `shots_used` = the number of shots) with no
/// physics (`score`, `ticks_run`, `final_state_hash` zero, not won).
pub impl StubSimulateHook of SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs {
        Outputs {
            version: *level.version,
            level_hash: level.hash(),
            seed: *level.seed,
            player: *inputs.player,
            inputs_hash: inputs.hash(),
            score: 0,
            won: false,
            shots_used: inputs.shots.len().try_into().unwrap(),
            ticks_run: 0,
            final_state_hash: 0,
        }
    }
}

/// The hook the contract's `simulate` calls: the replay (`slingfall_game::play::play`).
pub impl ActiveHook = replay_hook::ReplaySimulateHook;

/// Deserialises the stored `level` felts and the `inputs` felts, validates the inputs against the
/// level and runs the hook. Panics with `errors::SIMULATE_INPUTS` when the inputs felts are not
/// exactly one `Inputs`, and with the level crate's `inputs: *` messages when they break the
/// level's limits.
pub fn run<impl Hook: SimulateHook>(level: Span<felt252>, inputs: Span<felt252>) -> Outputs {
    let mut level = level;
    let level: Level = Serde::deserialize(ref level).expect(errors::SIMULATE_LEVEL);
    let mut inputs = inputs;
    let decoded: Option<Inputs> = Serde::deserialize(ref inputs);
    let Some(decoded) = decoded else {
        core::panic_with_felt252(errors::SIMULATE_INPUTS)
    };
    if !inputs.is_empty() {
        core::panic_with_felt252(errors::SIMULATE_INPUTS);
    }
    decoded.validate(@level);
    Hook::simulate(@level, @decoded)
}

#[cfg(test)]
mod tests {
    use slingfall_level::hash::to_felts;
    use slingfall_level::inputs::{Inputs, InputsTrait, Shot};
    use slingfall_level::level::fixtures::{PILE10_HASH, pile10_felts};
    use slingfall_testing::opaque;
    use super::{StubSimulateHook, run};

    fn inputs(shots: Array<Shot>) -> Array<felt252> {
        to_felts(@Inputs { player: 'player', shots })
    }

    fn shot(pull_x: i16, pull_y: i16) -> Shot {
        Shot { pull_x, pull_y, delay: 0, ability_tick: 0 }
    }

    #[test]
    fn test_stub_echoes_the_identity_fields() {
        let felts = inputs(array![shot(-100, 50), shot(3, 4)]);
        let outputs = run::<StubSimulateHook>(pile10_felts().span(), felts.span());
        let mut span = felts.span();
        let decoded: Inputs = Serde::deserialize(ref span).unwrap();
        assert_eq!(outputs.version, 1);
        assert_eq!(outputs.level_hash, PILE10_HASH);
        assert_eq!(outputs.player, 'player');
        assert_eq!(outputs.inputs_hash, decoded.hash());
        assert_eq!(outputs.shots_used, 2);
        assert_eq!((outputs.score, outputs.won, outputs.ticks_run), (0, false, 0));
    }

    #[test]
    #[should_panic(expected: ('simulate: inputs',))]
    fn test_run_rejects_truncated_inputs() {
        let mut felts = inputs(array![shot(1, 1)]);
        let _ = felts.pop_front();
        run::<StubSimulateHook>(pile10_felts().span(), felts.span());
    }

    #[test]
    #[should_panic(expected: ('simulate: inputs',))]
    fn test_run_rejects_trailing_felts() {
        let mut felts = inputs(array![shot(1, 1)]);
        felts.append(0);
        run::<StubSimulateHook>(pile10_felts().span(), felts.span());
    }

    #[test]
    #[should_panic(expected: ('inputs: shots',))]
    fn test_run_validates_inputs_against_the_level() {
        // pile10 has 3 shots.
        let felts = inputs(array![shot(1, 1), shot(1, 1), shot(1, 1), shot(1, 1)]);
        run::<StubSimulateHook>(pile10_felts().span(), felts.span());
    }

    #[test]
    fn steps_simulate_run__pile10_stub() {
        let level = opaque(pile10_felts());
        let felts = opaque(inputs(array![shot(-100, 50), shot(3, 4), shot(0, -7)]));
        opaque(run::<StubSimulateHook>(level.span(), felts.span()));
    }
}
