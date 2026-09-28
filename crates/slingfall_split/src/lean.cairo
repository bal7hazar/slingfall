//! Layout (e): layout (d) with the least code in the class that holds the world. The rules and
//! the edits are the same (`crate::rules`, `crate::world::apply_ops`), the protocol is leaner:
//!
//! * one rules call site: every call (`begin`, `tick`, `calm`) sends the same calldata
//!   (`rules ++ inputs ++ [shot, more] ++ inserted ++ hits ++ views`) and gets the same answer
//!   (`rules' ++ edit ++ watch ++ [status]`);
//! * the edit request is opaque here: forwarded verbatim to `EditClass::edit`, which applies the
//!   removals and sleeps of the tick, then inserts the next tick's pebble (one crossing for both;
//!   `more` tells the rules whether a next tick follows in this chunk, so that a launch never
//!   outlives its chunk);
//! * the views and the hits are written straight into the calldata.
//!
//! The world class compiles no `Rules`, `TickOut`, `Op` or `Launch` code.

use rapier2d::prelude::{BodyPose, ContactForceEvent, Handle, Pose2, RigidBodySetTrait, WorldTrait};
use rapier2d::world::World;
use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
use starknet::SyscallResultTrait;
use starknet::syscalls::library_call_syscall;
use crate::hashes::SplitHashes;
use crate::rules::{Launch, Op, Rules, TickOut};
use crate::world::{Stepper, errors};

/// The answer's `status`: the tick goes on.
pub const GO_ON: felt252 = 0;
/// The damage destroyed something: apply the edit, view `watch`, call `calm`.
pub const CALM: felt252 = 1;
/// The shot is over.
pub const OVER: felt252 = 2;

/// A chunk of layout (e): at most `k` ticks of shot `shot`.
pub fn run<impl St: Stepper, impl G: SplitHashes>(
    world: World, ref rules: Array<felt252>, inputs: Span<felt252>, shot: u8, k: u32,
) -> (World, u32, bool) {
    let mut world = world;
    let mut stepped = 0;
    let mut inserted: Array<Handle> = array![];
    let mut watch: Array<Handle> = array![];
    let mut events: Array<ContactForceEvent> = array![];
    let mut selector = selector!("begin");
    let mut over = false;
    loop {
        let mut calldata = array![];
        rules.serialize(ref calldata);
        inputs.serialize(ref calldata);
        calldata.append(shot.into());
        calldata.append((stepped != k).into());
        inserted.serialize(ref calldata);
        calldata.append(events.len().into());
        for event in events.span() {
            event.collider1.serialize(ref calldata);
            event.collider2.serialize(ref calldata);
            event.total_force_magnitude.serialize(ref calldata);
        }
        write_views(ref world, watch.span(), ref calldata);
        let mut ret = library_call_syscall(G::lean_rules(), selector, calldata.span())
            .unwrap_syscall();
        let (
            next, edit, next_watch, status,
        ): (Array<felt252>, Array<felt252>, Array<Handle>, felt252) =
            Serde::deserialize(
            ref ret,
        )
            .expect(errors::DECODE);
        rules = next;
        watch = next_watch;
        inserted = array![];
        events = array![];
        if !edit.is_empty() {
            let mut calldata = array![];
            into_basic_state(world).serialize(ref calldata);
            calldata.append_span(edit.span());
            let mut ret = library_call_syscall(G::edit(), selector!("edit"), calldata.span())
                .unwrap_syscall();
            let (state, added): (BasicWorldState, Array<Handle>) = Serde::deserialize(ref ret)
                .expect(errors::DECODE);
            world = from_basic_state(state);
            inserted = added;
        }
        if status == CALM {
            selector = selector!("calm");
            continue;
        }
        if status == OVER || stepped == k {
            over = status == OVER;
            break;
        }
        let (next, stepped_events) = St::step(world);
        world = next;
        events = stepped_events;
        watch.append_span(inserted.span());
        stepped += 1;
        selector = selector!("tick");
    }
    (world, stepped, over)
}

/// The views of `watch` as `Span<View>`'s felts (`Option<Motion>`: `[0, x, y, vx, vy, w]` for
/// an awake body, `[1]` for a sleeping one).
fn write_views(ref world: World, watch: Span<Handle>, ref out: Array<felt252>) {
    out.append(watch.len().into());
    for handle in watch {
        let handle = *handle;
        if world.is_sleeping(handle).unwrap() {
            out.append(1);
        } else {
            out.append(0);
            let pose: Pose2 = world.bodies.get_field::<Pose2, BodyPose>(handle).unwrap();
            pose.translation.serialize(ref out);
            world.linvel(handle).unwrap().serialize(ref out);
            world.angvel(handle).unwrap().serialize(ref out);
        }
    }
}

/// The rules class's answer: the state's felts, the edit request (the tick's ops, then the
/// launch when a next tick follows in the chunk; empty when there is nothing to edit), the bodies
/// to view and the status.
pub fn answer(
    rules: Rules, out: TickOut, more: bool,
) -> (Array<felt252>, Array<felt252>, Array<Handle>, felt252) {
    let mut felts = array![];
    rules.serialize(ref felts);
    let launch = if more {
        out.launch
    } else {
        None
    };
    let mut edit = array![];
    if !out.ops.is_empty() || launch.is_some() {
        out.ops.serialize(ref edit);
        launch.serialize(ref edit);
    }
    let status = if out.calm_pending {
        CALM
    } else if out.over {
        OVER
    } else {
        GO_ON
    };
    (felts, edit, out.watch, status)
}

/// `EditClass::edit`: `ops` in order, then the pebble of `launch`; the handles inserted.
pub fn edit(world: World, ops: Span<Op>, launch: Option<Launch>) -> (World, Array<Handle>) {
    let mut world = world;
    crate::world::apply_ops(ref world, ops);
    let mut added = array![];
    if let Some(launch) = launch {
        added.append(crate::world::insert_pebble(ref world, launch));
    }
    (world, added)
}

/// Layout (e)'s world class.
#[starknet::contract]
pub mod LayoutE {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::{GameClasses, PinnedSplit};
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
        let (world, stepped, over) = super::run::<
            SlimStep<GameClasses>, PinnedSplit,
        >(from_basic_state(world), ref rules, inputs.span(), shot, k);
        (into_basic_state(world), rules, stepped, over)
    }
}

/// Layout (e)'s rules class: `crate::rules` behind the lean protocol.
#[starknet::contract]
pub mod LeanRulesClass {
    use rapier2d::prelude::Handle;
    use slingfall_level::inputs::{Inputs, Shot};
    use crate::rules::{Hit, Rules, View, check_turn};
    use super::answer;

    #[storage]
    struct Storage {}

    fn decode(rules: Array<felt252>) -> Rules {
        slingfall_game::play::decode(rules.span(), slingfall_game::errors::STATE)
    }

    /// The shot of the chunk (the inputs were validated by `begin`).
    fn turn(inputs: Array<felt252>, shot: u8) -> Shot {
        let inputs: Inputs = slingfall_game::play::decode(
            inputs.span(), slingfall_game::errors::INPUTS,
        );
        *inputs.shots[shot.into()]
    }

    #[external(v0)]
    fn begin(
        self: @ContractState,
        rules: Array<felt252>,
        inputs: Array<felt252>,
        shot: u8,
        more: bool,
        inserted: Array<Handle>,
        hits: Span<Hit>,
        views: Span<View>,
    ) -> (Array<felt252>, Array<felt252>, Array<Handle>, felt252) {
        let rules = decode(rules);
        let shot = check_turn(@rules, inputs.span(), shot);
        let (launch, watch) = crate::rules::begin(@rules, @shot);
        let out = crate::rules::TickOut {
            ops: array![], calm_pending: false, watch, launch, over: false,
        };
        answer(rules, out, more)
    }

    #[external(v0)]
    fn tick(
        self: @ContractState,
        rules: Array<felt252>,
        inputs: Array<felt252>,
        shot: u8,
        more: bool,
        inserted: Array<Handle>,
        hits: Span<Hit>,
        views: Span<View>,
    ) -> (Array<felt252>, Array<felt252>, Array<Handle>, felt252) {
        let mut rules = decode(rules);
        let shot = turn(inputs, shot);
        let inserted = match inserted.get(0) {
            Some(handle) => Some(*handle.unbox()),
            None => None,
        };
        let out = crate::rules::tick(ref rules, @shot, inserted, hits, views);
        answer(rules, out, more)
    }

    #[external(v0)]
    fn calm(
        self: @ContractState,
        rules: Array<felt252>,
        inputs: Array<felt252>,
        shot: u8,
        more: bool,
        inserted: Array<Handle>,
        hits: Span<Hit>,
        views: Span<View>,
    ) -> (Array<felt252>, Array<felt252>, Array<Handle>, felt252) {
        let mut rules = decode(rules);
        let shot = turn(inputs, shot);
        let out = crate::rules::calm(ref rules, @shot, views);
        answer(rules, out, more)
    }
}
