use slingfall_level::hash::to_felts;
use slingfall_level::inputs::Inputs;
use slingfall_level::level::Level;
use slingfall_level::level::fixtures::{ONE_BLOCK_HASH, one_block, one_block_felts, pile10};
use slingfall_level::outputs::OutputsTrait;
use slingfall_rules::world::GameTrait;
use slingfall_testing::opaque;
use crate::errors;
use crate::fixtures::{
    PLAYER, REFERENCE_FINAL_STATE_HASH, reference_inputs, reference_outputs, shot,
};
use super::{NoopObserver, ShotProgress, decode, level_over, play, step_shot};

#[test]
fn test_decode_reads_exactly_one_value() {
    let level = one_block();
    let decoded: Level = decode(to_felts(@level).span(), errors::LEVEL);
    assert_eq!(decoded, level);
}

#[test]
#[should_panic(expected: ('replay: level',))]
fn test_decode_rejects_trailing_felts() {
    let mut felts = one_block_felts();
    felts.append(0);
    let _: Level = decode(felts.span(), errors::LEVEL);
}

#[test]
#[should_panic(expected: ('replay: inputs',))]
fn test_decode_rejects_truncated_felts() {
    let _: Inputs = decode(array![PLAYER].span(), errors::INPUTS);
}

/// No shots: the settled level, zero ticks, not won.
#[test]
fn test_play_without_shots() {
    let level = one_block();
    let inputs = Inputs { player: PLAYER, shots: array![] };
    let mut obs: NoopObserver = Default::default();
    let result = play(@level, @inputs, ref obs);
    assert_eq!(result.level_hash, ONE_BLOCK_HASH);
    assert_eq!((result.won, result.shots_used, result.ticks_run), (false, 0, 0));
    let mut game = GameTrait::new(@level);
    assert_eq!(result.final_state_hash, game.final_state_hash());
    assert!(!level_over(@game, @level));
}

#[test]
#[should_panic(expected: ('level: shots',))]
fn test_play_validates_the_level() {
    let mut level = one_block();
    level.shots = 0;
    let mut obs: NoopObserver = Default::default();
    play(@level, @reference_inputs(), ref obs);
}

#[test]
#[should_panic(expected: ('inputs: pull',))]
fn test_play_validates_the_inputs() {
    let inputs = Inputs { player: PLAYER, shots: array![shot(1025, 0, 0)] };
    let mut obs: NoopObserver = Default::default();
    play(@one_block(), @inputs, ref obs);
}

/// `step_shot` stops after its tick budget and resumes from `progress`: a delay of 3 cut by
/// budgets of 2 (two delay ticks; then one delay tick, the launch and one flight tick).
#[test]
fn test_step_shot_budget_is_resumable() {
    let level = one_block();
    let delayed = shot(-600, -200, 3);
    let mut game = GameTrait::new(@level);
    let mut progress: ShotProgress = Default::default();
    let mut obs: NoopObserver = Default::default();
    let (stepped, over) = step_shot(ref game, @level, @delayed, ref progress, 2, ref obs);
    assert_eq!((stepped, over, progress.launched, progress.ticks), (2, false, false, 2));
    let (stepped, over) = step_shot(ref game, @level, @delayed, ref progress, 2, ref obs);
    assert_eq!((stepped, over, progress.launched, progress.ticks), (2, false, true, 4));
    assert_eq!(game.tick, 4);
}

/// Step probe: `play` with the noop observer on the reference shot of pile10 (no decoding): the
/// proof build's logic, the contract's hook.
#[test]
fn steps_play_noop__pile10_reference() {
    let level = opaque(pile10());
    let inputs = opaque(reference_inputs());
    let mut obs: NoopObserver = Default::default();
    let outputs = play(@level, @inputs, ref obs);
    assert_eq!(outputs.to_felts(), reference_outputs());
}

/// Step probe: the rules alone on the reference shot (`GameTrait::new` + `play_shot` + the output
/// hash), the baseline of `play`'s overhead.
#[test]
fn steps_rules__pile10_reference() {
    let level = opaque(pile10());
    let inputs = opaque(reference_inputs());
    let mut game = GameTrait::new(@level);
    let report = game.play_shot(@level, inputs.shots[0]);
    // `play` is `play_shot` shot after shot: the golden outputs' fields.
    assert!(report.won);
    assert_eq!((game.score, game.shots_used, game.tick), (5350, 1, 191));
    assert_eq!(game.final_state_hash(), REFERENCE_FINAL_STATE_HASH);
}
