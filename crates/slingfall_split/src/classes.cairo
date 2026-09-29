//! The classes of the fallback layout (b) (`docs/research/07-split-game-step.md`). A world class
//! takes and returns the world and the rules state, and runs a chunk of at most `k` ticks of a
//! shot:
//!
//! | class | layout | step | rules | edits |
//! |---|---|---|---|---|
//! | `crate::lean::WorldClass` (+ `crate::lean::RulesClass`, rapier's `WorldEditClass`) | (e), the
//! game's | in process (`SlimSplitStages`) | library call | world crossing |
//! | `FallbackGame` (+ `StepClass`) | (b), passes 73,728 everywhere | world crossing per step | in
//! process | in process |
//!
//! The measured alternatives (a), (c), (d), (f) are `crate::probes` (feature `probes`).

use rapier2d::world::World;
use crate::rules::Rules;

/// Runs a chunk on a world class whose rules run in process: the rules felts decoded and
/// encoded here.
pub fn in_process<impl St: crate::world::Stepper, impl Ed: crate::world::EditStage>(
    world: World, rules: Span<felt252>, inputs: Span<felt252>, shot: u8, k: u32,
) -> (World, Array<felt252>, u32, bool) {
    let mut rules: Rules = slingfall_game::play::decode(rules, slingfall_game::errors::STATE);
    let (world, stepped, over) = crate::chunk::run::<
        Rules, St, crate::world::InProcessRules, Ed,
    >(world, ref rules, inputs, shot, k);
    let mut felts = array![];
    rules.serialize(ref felts);
    (world, felts, stepped, over)
}

/// Layout (b), the fallback game class: it owns the loop, the rules and the edits; the world
/// crosses to `StepClass` at every step.
#[starknet::contract]
pub mod FallbackGame {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::PinnedSplit;
    use crate::world::{CrossingStep, InProcessEdits};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_chunk(
        self: @ContractState,
        world: BasicWorldState,
        rules: Array<felt252>,
        inputs: Array<felt252>,
        shot: u8,
        k: u32,
    ) -> (BasicWorldState, Array<felt252>, u32, bool) {
        let (world, rules, stepped, over) = super::in_process::<
            CrossingStep<PinnedSplit>, InProcessEdits,
        >(from_basic_state(world), rules.span(), inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// Layout (b)'s step class: rapier's slim caller stepping once and returning the force events.
#[starknet::contract]
pub mod StepClass {
    use rapier2d::prelude::{BasicStepConfig, ContactForceEvent};
    use rapier2d::world::WorldTrait;
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use rapier2d_classes::SlimSplitStages;
    use crate::hashes::GameClasses;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step(
        self: @ContractState, world: BasicWorldState,
    ) -> (BasicWorldState, Array<ContactForceEvent>) {
        let mut world = from_basic_state(world);
        let (_, events) = world
            .step_with_force_events_with_stages::<BasicStepConfig, SlimSplitStages<GameClasses>>();
        (into_basic_state(world), events)
    }
}
