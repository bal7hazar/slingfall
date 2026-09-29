//! The measured alternatives of the S36a spike (`docs/research/07-split-game-step.md`, "Layouts"):
//! rapier's slim caller as the baseline, layouts (a), (c), (d) and (f). Not built by default
//! (feature `probes`).

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
        let (world, rules, stepped, over) = crate::classes::in_process::<
            SlimStep<GameClasses>, InProcessEdits,
        >(from_basic_state(world), rules.span(), inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// Layout (c): the world class keeps the world for the chunk and the World edits; the rules run
/// in `TypedRulesClass`, called once per tick (twice on a tick whose damage destroys).
#[starknet::contract]
pub mod LayoutC {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::probes::hashes::PinnedProbes;
    use crate::probes::world::LibraryCallRules;
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
        let mut rules = rules;
        let (world, stepped, over) = crate::chunk::run::<
            Array<felt252>, SlimStep<GameClasses>, LibraryCallRules<PinnedProbes>, InProcessEdits,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// Layout (d): (c) with the World edits in `EditClass` (the world crosses on the ticks that edit
/// it only).
#[starknet::contract]
pub mod LayoutD {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::probes::hashes::PinnedProbes;
    use crate::probes::world::{CrossingEdits, LibraryCallRules};
    use crate::world::SlimStep;

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
            LibraryCallRules<PinnedProbes>,
            CrossingEdits<PinnedProbes>,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// The rules of layouts (c) and (d) (`crate::rules`), on the rules state's felts.
#[starknet::contract]
pub mod TypedRulesClass {
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


/// Layout (f): layout (e) with the force events collected in `ForceEventsClass`
/// (`crate::probes::stages::SlimForceStages`, rapier-cairo's lever 3).
#[starknet::contract]
pub mod LayoutF {
    use crate::hashes::{GameClasses, PinnedSplit};
    use crate::probes::world::ForceStep;

    #[storage]
    struct Storage {}

    /// As `crate::lean::WorldClass::step_chunk`.
    #[external(v0)]
    fn step_chunk(
        self: @ContractState, state: Span<felt252>, inputs: Array<felt252>, shot: u8, k: u32,
    ) -> Array<felt252> {
        let mut state = state;
        let world = crate::lean::load(ref state);
        let mut rules: Array<felt252> = Serde::deserialize(ref state)
            .expect(crate::world::errors::DECODE);
        let (world, stepped, over) = crate::lean::run::<
            ForceStep<GameClasses>, PinnedSplit,
        >(world, ref rules, inputs.span(), shot, k);
        let mut out = array![];
        crate::lean::save(world, ref out);
        rules.serialize(ref out);
        out.append(stepped.into());
        out.append(over.into());
        out
    }
}

/// The game's own World edits of layout (d), the world in and out with the basic codec (the edit
/// class of layout (e) until lot B6, which moved it to rapier's `WorldEditClass`).
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

    #[external(v0)]
    fn insert(
        self: @ContractState, world: BasicWorldState, launch: Launch,
    ) -> (BasicWorldState, Handle) {
        let mut world = from_basic_state(world);
        let handle = insert_pebble(ref world, launch);
        (into_basic_state(world), handle)
    }
}
