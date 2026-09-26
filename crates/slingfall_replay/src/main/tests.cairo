use slingfall_game::errors;
use slingfall_game::fixtures::{
    PLAYER, REFERENCE_INPUTS_HASH, reference_inputs, reference_outputs, shot,
};
use slingfall_game::play::decode;
use slingfall_level::hash::to_felts;
use slingfall_level::inputs::{Inputs, InputsTrait};
use slingfall_level::level::fixtures::{one_block_felts, pile10, pile10_felts};
use slingfall_level::level::{Level, LevelTrait};
use slingfall_level::outputs::{Outputs, OutputsTrait};
use slingfall_rules::world::GameTrait;
use slingfall_testing::opaque;
use super::main;

fn run_main(level: Array<felt252>, inputs: @Inputs) -> Array<felt252> {
    main(opaque(level), opaque(to_felts(inputs)))
}

/// No shots: the settled level, zero ticks, not won; `final_state_hash` of the stored poses.
#[test]
fn test_main_without_shots() {
    let inputs = Inputs { player: PLAYER, shots: array![] };
    let felts = run_main(one_block_felts(), @inputs);
    let outputs = OutputsTrait::from_felts(felts.span());
    let level: Level = decode(one_block_felts().span(), errors::LEVEL);
    let mut game = GameTrait::new(@level);
    assert_eq!(
        outputs,
        Outputs {
            version: 1,
            level_hash: level.hash(),
            seed: 0,
            player: PLAYER,
            inputs_hash: inputs.hash(),
            score: 0,
            won: false,
            shots_used: 0,
            ticks_run: 0,
            final_state_hash: game.final_state_hash(),
        },
    );
}

#[test]
#[should_panic(expected: ('replay: level',))]
fn test_main_rejects_an_empty_level() {
    run_main(array![], @reference_inputs());
}

#[test]
#[should_panic(expected: ('replay: level',))]
fn test_main_rejects_a_truncated_level() {
    let mut level = pile10_felts();
    let _ = level.pop_front();
    run_main(level, @reference_inputs());
}

#[test]
#[should_panic(expected: ('replay: level',))]
fn test_main_rejects_trailing_level_felts() {
    let mut level = pile10_felts();
    level.append(0);
    run_main(level, @reference_inputs());
}

#[test]
#[should_panic(expected: ('replay: inputs',))]
fn test_main_rejects_trailing_inputs_felts() {
    let mut inputs = to_felts(@reference_inputs());
    inputs.append(0);
    main(pile10_felts(), inputs);
}

#[test]
#[should_panic(expected: ('replay: inputs',))]
fn test_main_rejects_truncated_inputs() {
    let mut inputs = to_felts(@reference_inputs());
    let _ = inputs.pop_front();
    main(pile10_felts(), inputs);
}

/// The level is validated (`level: *` messages): here `shots = 0`.
#[test]
#[should_panic(expected: ('level: shots',))]
fn test_main_validates_the_level() {
    let mut level = pile10();
    level.shots = 0;
    run_main(to_felts(@level), @reference_inputs());
}

/// The inputs are validated against the level (`inputs: *` messages): pile10 has 3 shots.
#[test]
#[should_panic(expected: ('inputs: shots',))]
fn test_main_validates_the_inputs() {
    let s = shot(1, 1, 0);
    run_main(pile10_felts(), @Inputs { player: PLAYER, shots: array![s, s, s, s] });
}

#[test]
#[should_panic(expected: ('inputs: pull',))]
fn test_main_validates_the_pull() {
    run_main(pile10_felts(), @Inputs { player: PLAYER, shots: array![shot(1025, 0, 0)] });
}

/// A level felt cut anywhere never decodes into a level: `replay: level`.
#[test]
#[fuzzer(runs: 16)]
#[should_panic(expected: ('replay: level',))]
fn fuzz_main_rejects_any_truncation(cut: u8) {
    let felts = pile10_felts();
    let keep = cut.into() % felts.len();
    let mut level: Array<felt252> = array![];
    level.append_span(felts.span().slice(0, keep));
    run_main(level, @reference_inputs());
}

/// Step probe and golden: the proof build on the reference shot (`main`, with argument decoding
/// and validation).
#[test]
fn steps_main__pile10_reference() {
    let felts = run_main(pile10_felts(), @reference_inputs());
    assert_eq!(felts, reference_outputs());
    assert_eq!(reference_inputs().hash(), REFERENCE_INPUTS_HASH);
}
