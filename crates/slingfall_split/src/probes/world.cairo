//! The world-side slots of the measured alternatives (layouts (a), (c), (d), (f)): the step with
//! the force events in `ForceEventsClass`, the rules across a library call, the edits across a
//! crossing.

use rapier2d::prelude::{BasicStepConfig, ContactForceEvent, Handle, WorldTrait};
use rapier2d::world::World;
use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
use rapier2d_classes::ClassHashes;
use starknet::SyscallResultTrait;
use starknet::syscalls::library_call_syscall;
use crate::hashes::SplitHashes;
use crate::probes::hashes::ProbeHashes;
use crate::rules::{Launch, Op, TickOut, View};
use crate::world::{EditStage, RulesStage, Stepper, errors};

/// The step with the force events in `ForceEventsClass` (`crate::probes::stages::SlimForceStages`).
pub impl ForceStep<impl H: ClassHashes> of Stepper {
    fn step(world: World) -> (World, Array<ContactForceEvent>) {
        let mut world = world;
        let (_, events) = world
            .step_with_force_events_with_stages::<
                BasicStepConfig, crate::probes::stages::SlimForceStages<H>,
            >();
        (world, events)
    }
}


/// The rules in `crate::probes::layouts::TypedRulesClass`, the state as opaque felts: this class
/// compiles neither `Rules` nor its `Serde`.
pub impl LibraryCallRules<impl G: ProbeHashes> of RulesStage<Array<felt252>> {
    fn begin(
        ref rules: Array<felt252>, inputs: Span<felt252>, shot: u8,
    ) -> (slingfall_level::inputs::Shot, Option<Launch>, Array<Handle>) {
        let mut calldata = array![];
        rules.serialize(ref calldata);
        inputs.serialize(ref calldata);
        shot.serialize(ref calldata);
        let mut ret = library_call_syscall(G::typed_rules(), selector!("begin"), calldata.span())
            .unwrap_syscall();
        Serde::deserialize(ref ret).expect(errors::DECODE)
    }

    fn tick(
        ref rules: Array<felt252>,
        shot: slingfall_level::inputs::Shot,
        inserted: Option<Handle>,
        events: Span<ContactForceEvent>,
        views: Span<View>,
    ) -> TickOut {
        let mut calldata = array![];
        rules.serialize(ref calldata);
        shot.serialize(ref calldata);
        inserted.serialize(ref calldata);
        // The events as `Span<Hit>`, without building the array.
        calldata.append(events.len().into());
        for event in events {
            event.collider1.serialize(ref calldata);
            event.collider2.serialize(ref calldata);
            event.total_force_magnitude.serialize(ref calldata);
        }
        views.serialize(ref calldata);
        call::<G>(ref rules, selector!("tick"), calldata)
    }

    fn calm(
        ref rules: Array<felt252>, shot: slingfall_level::inputs::Shot, views: Span<View>,
    ) -> TickOut {
        let mut calldata = array![];
        rules.serialize(ref calldata);
        shot.serialize(ref calldata);
        views.serialize(ref calldata);
        call::<G>(ref rules, selector!("calm"), calldata)
    }
}

fn call<impl G: ProbeHashes>(
    ref rules: Array<felt252>, selector: felt252, calldata: Array<felt252>,
) -> TickOut {
    let mut ret = library_call_syscall(G::typed_rules(), selector, calldata.span())
        .unwrap_syscall();
    let (next, out): (Array<felt252>, TickOut) = Serde::deserialize(ref ret).expect(errors::DECODE);
    rules = next;
    out
}

/// The edits in `crate::classes::EditClass`: on the ticks that edit the world (a removal, a
/// sleep, a launch), the world crosses there and back with the basic codec, which this class
/// already compiles for its own calldata. No edit, no crossing.
pub impl CrossingEdits<impl G: SplitHashes> of EditStage {
    fn apply(world: World, ops: Span<Op>) -> World {
        if ops.is_empty() {
            return world;
        }
        let mut calldata = array![];
        into_basic_state(world).serialize(ref calldata);
        ops.serialize(ref calldata);
        let mut ret = library_call_syscall(G::edit(), selector!("apply"), calldata.span())
            .unwrap_syscall();
        let state: BasicWorldState = Serde::deserialize(ref ret).expect(errors::DECODE);
        from_basic_state(state)
    }

    fn insert(world: World, launch: Launch) -> (World, Handle) {
        let mut calldata = array![];
        into_basic_state(world).serialize(ref calldata);
        launch.serialize(ref calldata);
        let mut ret = library_call_syscall(G::edit(), selector!("insert"), calldata.span())
            .unwrap_syscall();
        let (state, handle): (BasicWorldState, Handle) = Serde::deserialize(ref ret)
            .expect(errors::DECODE);
        (from_basic_state(state), handle)
    }
}
