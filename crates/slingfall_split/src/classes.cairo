//! The classes of the fallback layout (b) and the edit class of both layouts
//! (`docs/research/07-split-game-step.md`). A world class takes and returns the world and the rules
//! state, and runs a chunk of at most `k` ticks of a shot:
//!
//! | class | layout | step | rules | edits |
//! |---|---|---|---|---|
//! | `crate::lean::WorldClass` (+ `crate::lean::RulesClass`, `EditClass`) | (e), the game's | in
//! process (`SlimSplitStages`) | library call | world crossing |
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

/// The World edits: the world in and out with the basic codec. `edit` is layout (e)'s; `apply` and
/// `insert` are layout (d)'s (`crate::probes`).
#[starknet::contract]
pub mod EditClass {
    use rapier2d::prelude::Handle;
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::rules::{Launch, Op};
    use crate::world::{apply_ops, insert_pebble};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn apply(self: @ContractState, world: BasicWorldState, ops: Span<Op>) -> BasicWorldState {
        let mut world = from_basic_state(world);
        apply_ops(ref world, ops);
        into_basic_state(world)
    }

    /// `init`'s `sleep_all` after the settle step: every dynamic entity of the rules state.
    #[external(v0)]
    fn sleep_all(
        self: @ContractState, world: BasicWorldState, rules: Array<felt252>,
    ) -> (BasicWorldState, Array<felt252>) {
        let decoded: crate::rules::Rules = slingfall_game::play::decode(
            rules.span(), slingfall_game::errors::STATE,
        );
        let mut world = from_basic_state(world);
        apply_ops(ref world, crate::init::settle_sleeps(@decoded).span());
        (into_basic_state(world), rules)
    }

    /// Layout (e), the game's: the tick's edits, then the next tick's pebble (`crate::lean::edit`).
    #[external(v0)]
    fn edit(
        self: @ContractState, world: BasicWorldState, ops: Span<Op>, launch: Option<Launch>,
    ) -> (BasicWorldState, Array<Handle>) {
        let (world, added) = crate::lean::edit(from_basic_state(world), ops, launch);
        (into_basic_state(world), added)
    }

    #[external(v0)]
    fn insert(
        self: @ContractState, world: BasicWorldState, launch: Launch,
    ) -> (BasicWorldState, Handle) {
        let mut world = from_basic_state(world);
        let handle = insert_pebble(ref world, launch);
        (into_basic_state(world), handle)
    }
}
