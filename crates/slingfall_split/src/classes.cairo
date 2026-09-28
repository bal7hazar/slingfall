//! The classes of the layouts (`docs/research/07-split-game-step.md`). Every world class takes and
//! returns the world with the basic codec (`BasicWorldState`: `WorldState`'s felts) and the rules
//! state as felts (`crate::rules::Rules`' `Serde`), and runs `crate::chunk::run` with its slots:
//!
//! | class | step | rules | edits |
//! |---|---|---|---|
//! | `SlimCaller` | rapier's `SlimSplitStep` (the baseline: no game) | | |
//! | `LayoutA` | in process (`SlimSplitStages`) | in process | in process |
//! | `LayoutB` (+ `StepClass`) | world crossing per step | in process | in process |
//! | `LayoutC` (+ `RulesClass`) | in process | library call | in process |
//! | `LayoutD` (+ `RulesClass`, `EditClass`) | in process | library call | world crossing |

use rapier2d::world::World;
use crate::rules::Rules;

/// Runs a chunk on a world class whose rules run in process: the rules felts decoded and
/// encoded here.
fn in_process<impl St: crate::world::Stepper, impl Ed: crate::world::EditStage>(
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

/// rapier's `SlimSplitStep` (`rapier_sink`) at this crate's hashes: the caller class before any
/// game code.
#[starknet::contract]
pub mod SlimCaller {
    use rapier2d::prelude::BasicStepConfig;
    use rapier2d::world::WorldTrait;
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use rapier2d_classes::SlimSplitStages;
    use crate::hashes::GameClasses;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(self: @ContractState, state: BasicWorldState, steps: u32) -> BasicWorldState {
        let mut world = from_basic_state(state);
        let mut i = 0;
        while i != steps {
            let _ = world
                .step_with_force_events_with_stages::<
                    BasicStepConfig, SlimSplitStages<GameClasses>,
                >();
            i += 1;
        }
        into_basic_state(world)
    }
}

/// Layout (a): the game's tick in the class that holds the world.
#[starknet::contract]
pub mod LayoutA {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::world::{InProcessEdits, SlimStep};

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
            SlimStep<GameClasses>, InProcessEdits,
        >(from_basic_state(world), rules.span(), inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// Layout (b): the game class owns the loop, the rules and the edits; the world crosses to
/// `StepClass` at every step.
#[starknet::contract]
pub mod LayoutB {
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

/// Layout (c): the world class keeps the world for the chunk and the World edits; the rules run
/// in `RulesClass`, called once per tick (twice on a tick whose damage destroys).
#[starknet::contract]
pub mod LayoutC {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::{GameClasses, PinnedSplit};
    use crate::world::{InProcessEdits, LibraryCallRules, SlimStep};

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
        let mut rules = rules;
        let (world, stepped, over) = crate::chunk::run::<
            Array<felt252>, SlimStep<GameClasses>, LibraryCallRules<PinnedSplit>, InProcessEdits,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// Layout (d): (c) with the World edits in `EditClass` (the world crosses on the ticks that edit
/// it only).
#[starknet::contract]
pub mod LayoutD {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::{GameClasses, PinnedSplit};
    use crate::world::{CrossingEdits, LibraryCallRules, SlimStep};

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
        let mut rules = rules;
        let (world, stepped, over) = crate::chunk::run::<
            Array<felt252>,
            SlimStep<GameClasses>,
            LibraryCallRules<PinnedSplit>,
            CrossingEdits<PinnedSplit>,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// The rules of layouts (c) and (d) (`crate::rules`), on the rules state's felts.
#[starknet::contract]
pub mod RulesClass {
    use rapier2d::prelude::Handle;
    use slingfall_level::inputs::Shot;
    use crate::rules::{Hit, Launch, Rules, TickOut, View, check_turn};

    #[storage]
    struct Storage {}

    fn decode(rules: Array<felt252>) -> Rules {
        slingfall_game::play::decode(rules.span(), slingfall_game::errors::STATE)
    }

    fn encode(rules: Rules, out: TickOut) -> (Array<felt252>, TickOut) {
        let mut felts = array![];
        rules.serialize(ref felts);
        (felts, out)
    }

    #[external(v0)]
    fn begin(
        self: @ContractState, rules: Array<felt252>, inputs: Array<felt252>, shot: u8,
    ) -> (Shot, Option<Launch>, Array<Handle>) {
        let rules = decode(rules);
        let shot = check_turn(@rules, inputs.span(), shot);
        let (launch, watch) = crate::rules::begin(@rules, @shot);
        (shot, launch, watch)
    }

    #[external(v0)]
    fn tick(
        self: @ContractState,
        rules: Array<felt252>,
        shot: Shot,
        inserted: Option<Handle>,
        hits: Span<Hit>,
        views: Span<View>,
    ) -> (Array<felt252>, TickOut) {
        let mut rules = decode(rules);
        let out = crate::rules::tick(ref rules, @shot, inserted, hits, views);
        encode(rules, out)
    }

    #[external(v0)]
    fn calm(
        self: @ContractState, rules: Array<felt252>, shot: Shot, views: Span<View>,
    ) -> (Array<felt252>, TickOut) {
        let mut rules = decode(rules);
        let out = crate::rules::calm(ref rules, @shot, views);
        encode(rules, out)
    }
}

/// The World edits of layout (d): the world in and out with the basic codec.
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

    /// Layout (e): the tick's edits, then the next tick's pebble (`crate::lean::edit`).
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
