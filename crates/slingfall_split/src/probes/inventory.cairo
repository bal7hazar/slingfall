//! Size fixtures (`tools/classsize/classsize.py split`): the caller class `SlimCaller` plus one
//! piece of the game each (`Plus*`: the piece's cost in the class that holds the world is the
//! delta), and the game's stages alone in a class (`Stage*`). Never deployed; the sizes do not
//! depend on the class hashes.

use rapier2d::prelude::{ContactForceEvent, Handle};
use rapier2d::world::World;
use slingfall_level::inputs::Shot;
use crate::rules::{Launch, Op, TickOut, View};
use crate::world::{EditStage, RulesStage};

/// No rules: the loop steps `k` times. Its answers depend on the state's length, so that the
/// compiler cannot drop the edit and launch paths of the loop (a constant answer would).
pub impl NoRules of RulesStage<Array<felt252>> {
    fn begin(
        ref rules: Array<felt252>, inputs: Span<felt252>, shot: u8,
    ) -> (Shot, Option<Launch>, Array<Handle>) {
        (Shot { pull_x: 0, pull_y: 0, delay: 0, ability_tick: 0 }, opaque_launch(@rules), array![])
    }

    fn tick(
        ref rules: Array<felt252>,
        shot: Shot,
        inserted: Option<Handle>,
        events: Span<ContactForceEvent>,
        views: Span<View>,
    ) -> TickOut {
        opaque_out(@rules)
    }

    fn calm(ref rules: Array<felt252>, shot: Shot, views: Span<View>) -> TickOut {
        opaque_out(@rules)
    }
}

fn opaque_handle(rules: @Array<felt252>) -> Handle {
    Handle { index: rules.len(), generation: 0 }
}

fn opaque_launch(rules: @Array<felt252>) -> Option<Launch> {
    if rules.len() == 1 {
        let zero = rapier2d::prelude::Vec2 {
            x: rapier2d::prelude::Fixed { raw: 0 }, y: rapier2d::prelude::Fixed { raw: 0 },
        };
        Some(Launch { translation: zero, linvel: zero })
    } else {
        None
    }
}

fn opaque_out(rules: @Array<felt252>) -> TickOut {
    let ops = if rules.len() == 2 {
        array![Op::Remove(opaque_handle(rules)), Op::Sleep(opaque_handle(rules))]
    } else {
        array![]
    };
    TickOut {
        ops,
        calm_pending: rules.len() == 3,
        watch: array![opaque_handle(rules)],
        launch: opaque_launch(rules),
        over: rules.len() == 4,
    }
}

/// No edits.
pub impl NoEdits of EditStage {
    fn apply(world: World, ops: Span<Op>) -> World {
        world
    }

    fn insert(world: World, launch: Launch) -> (World, Handle) {
        (world, Handle { index: 0, generation: 0 })
    }
}

/// `SlimCaller` with the chunk loop and the views, no rules, no edits.
#[starknet::contract]
pub mod PlusLoop {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::world::SlimStep;
    use super::{NoEdits, NoRules};

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
            Array<felt252>, SlimStep<GameClasses>, NoRules, NoEdits,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// [`PlusLoop`] with the rules library-called (`LibraryCallRules`).
#[starknet::contract]
pub mod PlusRulesCall {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::probes::hashes::PinnedProbes;
    use crate::probes::world::LibraryCallRules;
    use crate::world::SlimStep;
    use super::NoEdits;

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
            Array<felt252>, SlimStep<GameClasses>, LibraryCallRules<PinnedProbes>, NoEdits,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// [`PlusLoop`] with the edits across a world crossing (`CrossingEdits`).
#[starknet::contract]
pub mod PlusEditCrossing {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::{GameClasses, PinnedSplit};
    use crate::probes::world::CrossingEdits;
    use crate::world::SlimStep;
    use super::NoRules;

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
            Array<felt252>, SlimStep<GameClasses>, NoRules, CrossingEdits<PinnedSplit>,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// [`PlusLoop`] with the edits in process (`InProcessEdits`: `remove_body`, `sleep`, `insert`).
#[starknet::contract]
pub mod PlusEdits {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::world::{InProcessEdits, SlimStep};
    use super::NoRules;

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
            Array<felt252>, SlimStep<GameClasses>, NoRules, InProcessEdits,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// `SlimCaller` plus one World edit or read after the steps, each alone.
#[starknet::contract]
pub mod PlusInsert {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::rules::Launch;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(
        self: @ContractState, state: BasicWorldState, steps: u32, launch: Launch,
    ) -> BasicWorldState {
        let mut world = super::slim_steps(from_basic_state(state), steps);
        let _ = crate::world::insert_pebble(ref world, launch);
        into_basic_state(world)
    }
}

#[starknet::contract]
pub mod PlusRemove {
    use rapier2d::prelude::{Handle, WorldTrait};
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(
        self: @ContractState, state: BasicWorldState, steps: u32, handle: Handle,
    ) -> BasicWorldState {
        let mut world = super::slim_steps(from_basic_state(state), steps);
        let _ = world.remove_body(handle);
        into_basic_state(world)
    }
}

#[starknet::contract]
pub mod PlusSleep {
    use rapier2d::prelude::Handle;
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::rules::Op;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(
        self: @ContractState, state: BasicWorldState, steps: u32, handle: Handle,
    ) -> BasicWorldState {
        let mut world = super::slim_steps(from_basic_state(state), steps);
        crate::world::apply_ops(ref world, array![Op::Sleep(handle)].span());
        into_basic_state(world)
    }
}

#[starknet::contract]
pub mod PlusViews {
    use rapier2d::prelude::Handle;
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::rules::View;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(
        self: @ContractState, state: BasicWorldState, steps: u32, watch: Span<Handle>,
    ) -> (BasicWorldState, Array<View>) {
        let mut world = super::slim_steps(from_basic_state(state), steps);
        let views = crate::world::views(ref world, watch);
        (into_basic_state(world), views)
    }
}

/// [`PlusViews`] reading each watched body whole (`World::body`, as main's calm rule).
#[starknet::contract]
pub mod PlusViewsBody {
    use rapier2d::prelude::{Handle, RigidBodyTrait, WorldTrait};
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::rules::{Motion, View};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(
        self: @ContractState, state: BasicWorldState, steps: u32, watch: Span<Handle>,
    ) -> (BasicWorldState, Array<View>) {
        let mut world = super::slim_steps(from_basic_state(state), steps);
        let mut views = array![];
        for handle in watch {
            let body = world.body(*handle).unwrap();
            views
                .append(
                    if body.is_sleeping() {
                        None
                    } else {
                        Some(
                            Motion {
                                translation: body.translation(),
                                linvel: body.linvel(),
                                angvel: body.angvel(),
                            },
                        )
                    },
                );
        }
        (into_basic_state(world), views)
    }
}

/// [`PlusViews`] reading the bodies through `RigidBodySetTrait::iter` (a copy of every body).
#[starknet::contract]
pub mod PlusViewsIter {
    use rapier2d::prelude::{Handle, RigidBodySetTrait, RigidBodyTrait};
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::rules::{Motion, View};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(
        self: @ContractState, state: BasicWorldState, steps: u32, watch: Span<Handle>,
    ) -> (BasicWorldState, Array<View>) {
        let mut world = super::slim_steps(from_basic_state(state), steps);
        let mut views = array![];
        let mut watch = watch;
        for (handle, body) in world.bodies.iter() {
            if let Some(next) = watch.get(0) {
                if *next.unbox() == handle {
                    let _ = watch.pop_front();
                    views
                        .append(
                            if body.is_sleeping() {
                                None
                            } else {
                                Some(
                                    Motion {
                                        translation: body.translation(),
                                        linvel: body.linvel(),
                                        angvel: body.angvel(),
                                    },
                                )
                            },
                        );
                }
            }
        }
        (into_basic_state(world), views)
    }
}

/// `SlimCaller` with `rapier2d_classes::LibraryCallForceEvents` (CS6's lever 3: the force events
/// collected in `ForceEventsClass`).
#[starknet::contract]
pub mod MinusForceEvents {
    use rapier2d::prelude::BasicStepConfig;
    use rapier2d::world::WorldTrait;
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::probes::stages::SlimForceStages;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(self: @ContractState, state: BasicWorldState, steps: u32) -> BasicWorldState {
        let mut world = from_basic_state(state);
        let mut i = 0;
        while i != steps {
            let _ = world
                .step_with_force_events_with_stages::<
                    BasicStepConfig, SlimForceStages<GameClasses>,
                >();
            i += 1;
        }
        into_basic_state(world)
    }
}

/// `SlimCaller` with the tick-hook emulation (`crate::probes::stages::HookStages`): the plumbing a
/// `TickHook` stage slot would compile into the caller, without applying the removals.
#[starknet::contract]
pub mod PlusHook {
    use rapier2d::prelude::BasicStepConfig;
    use rapier2d::world::WorldTrait;
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::probes::hashes::PinnedProbes;
    use crate::probes::stages::HookStages;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(self: @ContractState, state: BasicWorldState, steps: u32) -> BasicWorldState {
        let mut world = from_basic_state(state);
        let mut i = 0;
        while i != steps {
            let _ = world
                .step_with_force_events_with_stages::<
                    BasicStepConfig, HookStages<GameClasses, PinnedProbes>,
                >();
            i += 1;
        }
        into_basic_state(world)
    }
}

/// `SlimCaller` plus the binding of a SNIP-36 chunk: Poseidon of the state felts in and out
/// (`slingfall_game::chunk::hash_felts`) and the L2 to L1 message.
#[starknet::contract]
pub mod PlusBinding {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use slingfall_game::chunk::hash_felts;
    use starknet::SyscallResultTrait;
    use starknet::syscalls::send_message_to_l1_syscall;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn step_state(self: @ContractState, state: Span<felt252>, steps: u32) {
        let state_in = hash_felts(state);
        let mut span = state;
        let world: BasicWorldState = Serde::deserialize(ref span).unwrap();
        let world = super::slim_steps(from_basic_state(world), steps);
        let mut felts = array![];
        into_basic_state(world).serialize(ref felts);
        let payload = array![state_in, hash_felts(felts.span())];
        send_message_to_l1_syscall('SLINGFALL', payload.span()).unwrap_syscall();
    }
}

/// The rules in process on views and hits, no World edit (the game's rules in the caller).
#[starknet::contract]
pub mod PlusRules {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;
    use crate::world::{InProcessRules, SlimStep};
    use super::NoEdits;

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
        let mut decoded: crate::rules::Rules = slingfall_game::play::decode(
            rules.span(), slingfall_game::errors::STATE,
        );
        let (world, stepped, over) = crate::chunk::run::<
            crate::rules::Rules, SlimStep<GameClasses>, InProcessRules, NoEdits,
        >(from_basic_state(world), ref decoded, inputs.span(), shot, k);
        let mut felts = array![];
        decoded.serialize(ref felts);
        (into_basic_state(world), felts, stepped, over)
    }
}

/// The game's stages alone (no world class around them).
///
/// * `StageBuild`: the world of a level (`GameTrait::new` without the settle step: validate,
///   builders, `insert`), saved with the basic codec;
/// * `StageDamage`: the damage rule and its removal bookkeeping on the rules state (D6, D7);
/// * `StageCalm`: the calm, out-of-bounds, tick-cap and end-of-shot rules (D5, D7);
/// * `StageChunkCodec`: main's `ChunkState` (full `WorldState` codec) decoded, encoded and hashed;
/// * `StageSplitCodec`: this spike's state (basic codec and `Rules`) decoded, encoded and hashed.
#[starknet::contract]
pub mod StageBuild {
    use rapier2d::world::basic_state::{BasicWorldState, into_basic_state};
    use slingfall_level::level::Level;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn build(self: @ContractState, level: Level) -> BasicWorldState {
        into_basic_state(crate::init::build_world(@level))
    }
}

#[starknet::contract]
pub mod StageDamage {
    use crate::rules::{Hit, Rules};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn damage(self: @ContractState, rules: Rules, hits: Span<Hit>) -> (Rules, bool) {
        let mut rules = rules;
        let destroyed = crate::rules::damage_only(ref rules, hits);
        (rules, destroyed)
    }
}

#[starknet::contract]
pub mod StageCalm {
    use slingfall_level::inputs::Shot;
    use crate::rules::{Rules, TickOut, View};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn calm(self: @ContractState, rules: Rules, shot: Shot, views: Span<View>) -> (Rules, TickOut) {
        let mut rules = rules;
        let out = crate::rules::calm(ref rules, @shot, views);
        (rules, out)
    }
}

#[starknet::contract]
pub mod StageChunkCodec {
    use slingfall_game::chunk::{ChunkState, hash_felts};

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn trip(self: @ContractState, state: Span<felt252>) -> (felt252, felt252) {
        let mut span = state;
        let decoded: ChunkState = Serde::deserialize(ref span).unwrap();
        let mut felts = array![];
        decoded.serialize(ref felts);
        (hash_felts(state), hash_felts(felts.span()))
    }
}

#[starknet::contract]
pub mod StageSplitCodec {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use slingfall_game::chunk::hash_felts;
    use crate::rules::Rules;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn trip(self: @ContractState, state: Span<felt252>) -> (felt252, felt252) {
        let mut span = state;
        let world: BasicWorldState = Serde::deserialize(ref span).unwrap();
        let rules: Rules = Serde::deserialize(ref span).unwrap();
        let mut felts = array![];
        into_basic_state(from_basic_state(world)).serialize(ref felts);
        rules.serialize(ref felts);
        (hash_felts(state), hash_felts(felts.span()))
    }
}

fn slim_steps(world: World, steps: u32) -> World {
    let mut world = world;
    let mut i = 0;
    while i != steps {
        let (next, _) = crate::world::SlimStep::<crate::hashes::GameClasses>::step(world);
        world = next;
        i += 1;
    }
    world
}
