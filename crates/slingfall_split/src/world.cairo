//! The world side of a tick: what the class holding the world does around the rules
//! (`crate::rules`), and the three slots a layout fills ([`Stepper`], [`RulesStage`],
//! [`EditStage`]), each in process or across a library call.

use rapier2d::prelude::{
    BasicStepConfig, BodyPose, CONTACT_FORCE_EVENTS, ColliderBuilderTrait, ContactForceEvent, Fixed,
    Handle, Pose2, RigidBodyBuilderTrait, RigidBodySetTrait, RigidBodyTrait, Rot2, WorldTrait,
};
use rapier2d::world::World;
use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
use rapier2d_classes::{ClassHashes, SlimSplitStages};
use slingfall_rules::sling::{
    PEBBLE_DENSITY, PEBBLE_FRICTION, PEBBLE_RADIUS, PEBBLE_RESTITUTION, PEBBLE_USER_DATA,
};
use starknet::SyscallResultTrait;
use starknet::syscalls::library_call_syscall;
use crate::hashes::SplitHashes;
use crate::rules::{Hit, Launch, Motion, Op, Rules, TickOut, View};

/// Panic messages of the spike (`felt252`, stable).
pub mod errors {
    /// A class returned felts that do not decode as its result.
    pub const DECODE: felt252 = 'split: decode';
}

/// The views of `watch` after a step: `None` for a sleeping body, else its translation and
/// velocities (field reads, no copy of the body).
pub fn views(ref world: World, watch: Span<Handle>) -> Array<View> {
    let mut out = array![];
    for handle in watch {
        let handle = *handle;
        if world.is_sleeping(handle).unwrap() {
            out.append(None);
        } else {
            let pose: Pose2 = world.bodies.get_field::<Pose2, BodyPose>(handle).unwrap();
            out
                .append(
                    Some(
                        Motion {
                            translation: pose.translation,
                            linvel: world.linvel(handle).unwrap(),
                            angvel: world.angvel(handle).unwrap(),
                        },
                    ),
                );
        }
    }
    out
}

/// The rules' reading of the step's contact-force events.
pub fn hits(events: Span<ContactForceEvent>) -> Array<Hit> {
    let mut out = array![];
    for event in events {
        out
            .append(
                Hit {
                    collider1: *event.collider1,
                    collider2: *event.collider2,
                    magnitude: *event.total_force_magnitude,
                },
            );
    }
    out
}

/// Applies `ops` in order: `World::remove_body`, or `sleep_all`'s edit of one body.
pub fn apply_ops(ref world: World, ops: Span<Op>) {
    for op in ops {
        match *op {
            Op::Remove(handle) => { let _ = world.remove_body(handle); },
            Op::Sleep(handle) => {
                if !world.is_sleeping(handle).unwrap() {
                    let mut body = world.body(handle).unwrap();
                    body.sleep();
                    let _ = world.set_body(handle, body);
                }
            },
        }
    }
}

/// `sling::launch`'s insertion: the pebble body and collider; its handle.
pub fn insert_pebble(ref world: World, launch: Launch) -> Handle {
    let pose = Pose2 {
        translation: launch.translation,
        rotation: Rot2 { re: Fixed { raw: 0x100000000 }, im: Fixed { raw: 0 } },
    };
    let body = RigidBodyBuilderTrait::dynamic().position(pose).linvel(launch.linvel).build();
    let collider = ColliderBuilderTrait::ball(PEBBLE_RADIUS)
        .density(PEBBLE_DENSITY)
        .friction(PEBBLE_FRICTION)
        .restitution(PEBBLE_RESTITUTION)
        .user_data(PEBBLE_USER_DATA)
        .contact_force_event_threshold(Fixed { raw: 0 })
        .active_events(CONTACT_FORCE_EVENTS)
        .build();
    let (handle, _) = world.insert(body, collider);
    handle
}

/// One engine step with its force events.
pub trait Stepper {
    fn step(world: World) -> (World, Array<ContactForceEvent>);
}

/// The step in this class: `SlimSplitStages<H>`, the stage classes library-called.
pub impl SlimStep<impl H: ClassHashes> of Stepper {
    fn step(world: World) -> (World, Array<ContactForceEvent>) {
        let mut world = world;
        let (_, events) = world
            .step_with_force_events_with_stages::<BasicStepConfig, SlimSplitStages<H>>();
        (world, events)
    }
}

/// The step with the force events in `ForceEventsClass` (`crate::stages::SlimForceStages`).
pub impl ForceStep<impl H: ClassHashes> of Stepper {
    fn step(world: World) -> (World, Array<ContactForceEvent>) {
        let mut world = world;
        let (_, events) = world
            .step_with_force_events_with_stages::<
                BasicStepConfig, crate::stages::SlimForceStages<H>,
            >();
        (world, events)
    }
}

/// Layout (b): the world crosses to `crate::classes::StepClass` at every step (basic codec both
/// ways), which steps it with `SlimSplitStages` and returns it with the force events.
pub impl CrossingStep<impl G: SplitHashes> of Stepper {
    fn step(world: World) -> (World, Array<ContactForceEvent>) {
        let mut calldata = array![];
        into_basic_state(world).serialize(ref calldata);
        let mut ret = library_call_syscall(G::step(), selector!("step"), calldata.span())
            .unwrap_syscall();
        let (state, events): (BasicWorldState, Array<ContactForceEvent>) = Serde::deserialize(
            ref ret,
        )
            .expect(errors::DECODE);
        (from_basic_state(state), events)
    }
}

/// The rules of a tick, on a state of type `R` (`Rules` in process, its felts across a call).
pub trait RulesStage<R> {
    /// `crate::rules::begin`, after `check_turn`: the shot, the launch before the first step, the
    /// bodies to watch.
    fn begin(
        ref rules: R, inputs: Span<felt252>, shot: u8,
    ) -> (slingfall_level::inputs::Shot, Option<Launch>, Array<Handle>);
    fn tick(
        ref rules: R,
        shot: slingfall_level::inputs::Shot,
        inserted: Option<Handle>,
        events: Span<ContactForceEvent>,
        views: Span<View>,
    ) -> TickOut;
    fn calm(ref rules: R, shot: slingfall_level::inputs::Shot, views: Span<View>) -> TickOut;
}

/// The rules in this class.
pub impl InProcessRules of RulesStage<Rules> {
    fn begin(
        ref rules: Rules, inputs: Span<felt252>, shot: u8,
    ) -> (slingfall_level::inputs::Shot, Option<Launch>, Array<Handle>) {
        let shot = crate::rules::check_turn(@rules, inputs, shot);
        let (launch, watch) = crate::rules::begin(@rules, @shot);
        (shot, launch, watch)
    }

    fn tick(
        ref rules: Rules,
        shot: slingfall_level::inputs::Shot,
        inserted: Option<Handle>,
        events: Span<ContactForceEvent>,
        views: Span<View>,
    ) -> TickOut {
        crate::rules::tick(ref rules, @shot, inserted, hits(events).span(), views)
    }

    fn calm(ref rules: Rules, shot: slingfall_level::inputs::Shot, views: Span<View>) -> TickOut {
        crate::rules::calm(ref rules, @shot, views)
    }
}

/// The rules in `crate::classes::RulesClass`, the state as opaque felts: this class compiles
/// neither `Rules` nor its `Serde`.
pub impl LibraryCallRules<impl G: SplitHashes> of RulesStage<Array<felt252>> {
    fn begin(
        ref rules: Array<felt252>, inputs: Span<felt252>, shot: u8,
    ) -> (slingfall_level::inputs::Shot, Option<Launch>, Array<Handle>) {
        let mut calldata = array![];
        rules.serialize(ref calldata);
        inputs.serialize(ref calldata);
        shot.serialize(ref calldata);
        let mut ret = library_call_syscall(G::rules(), selector!("begin"), calldata.span())
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

fn call<impl G: SplitHashes>(
    ref rules: Array<felt252>, selector: felt252, calldata: Array<felt252>,
) -> TickOut {
    let mut ret = library_call_syscall(G::rules(), selector, calldata.span()).unwrap_syscall();
    let (next, out): (Array<felt252>, TickOut) = Serde::deserialize(ref ret).expect(errors::DECODE);
    rules = next;
    out
}

/// The world edits the rules ask for.
pub trait EditStage {
    fn apply(world: World, ops: Span<Op>) -> World;
    fn insert(world: World, launch: Launch) -> (World, Handle);
}

/// The edits in this class (`World::remove_body`, `set_body`, `insert` and the builders).
pub impl InProcessEdits of EditStage {
    fn apply(world: World, ops: Span<Op>) -> World {
        let mut world = world;
        apply_ops(ref world, ops);
        world
    }

    fn insert(world: World, launch: Launch) -> (World, Handle) {
        let mut world = world;
        let handle = insert_pebble(ref world, launch);
        (world, handle)
    }
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
