//! Stand-in executable for the VM worker (lot G1c) until the replay executable of lot G4 exists.
//! Copy of the spike `pm/spikes/wasm-vm/ball_drop` (itself `rapier-cairo/examples/ball_drop`
//! plus the G1 trace print and the G1b chunked modes, docs/research/04), on registry `rapier2d`.
//! When `trace != 0`, prints `tick <i> y <raw>` after every physics step (the streaming probe).

use rapier2d::prelude::*;
use rapier_core::collider::events::COLLISION_EVENTS;
use rapier_dynamics2d::collider::Collider;
use rapier_dynamics2d::joint::ImpulseJoint;
use rapier_dynamics2d::narrow_phase::ContactPair;
use rapier_math::pose2::Pose2;
use rapier_math::rot2::Rot2;

pub const BALL_DROP: u8 = 0;
pub const BOX_STACK3: u8 = 1;
pub const PENDULUM: u8 = 2;

pub mod errors {
    pub const UNKNOWN_SCENE: felt252 = 'ball_drop: unknown scene';
}

const GRAVITY_Y: i64 = -42133629174;
const DT: i64 = 71582788;
const TEN: i64 = 42949672960;
const HALF_RAW: i64 = 2147483648;
const ONE_RAW: i64 = 4294967296;

fn f(raw: i64) -> Fixed {
    Fixed { raw }
}

fn at(x: i64, y: i64) -> Pose2 {
    Pose2 { translation: Vec2 { x: f(x), y: f(y) }, rotation: Rot2 { re: f(ONE_RAW), im: f(0) } }
}

fn empty_world() -> World {
    let params = IntegrationParameters { dt: f(DT), ..Default::default() };
    WorldTrait::new(Vec2 { x: f(0), y: f(GRAVITY_Y) }, params)
}

fn ball_drop(ref world: World) -> Array<Handle> {
    let ground = ColliderBuilderTrait::halfspace(Vec2 { x: f(0), y: f(ONE_RAW) }).build();
    let _ = world.insert_collider(ground, None);
    let ball = ColliderBuilderTrait::ball(f(HALF_RAW)).active_events(COLLISION_EVENTS).build();
    let (body, _) = world.insert(RigidBodyTrait::dynamic(at(0, 2 * ONE_RAW)), ball);
    array![body]
}

fn box_stack3(ref world: World) -> Array<Handle> {
    let ground = ColliderBuilderTrait::cuboid(f(TEN), f(HALF_RAW)).build();
    let _ = world.insert(RigidBodyTrait::fixed(at(0, -HALF_RAW)), ground);
    let mut handles = array![];
    for y in array![2190433321_i64, 6528350290, 10866267259].span() {
        let collider = ColliderBuilderTrait::cuboid(f(HALF_RAW), f(HALF_RAW))
            .active_events(COLLISION_EVENTS)
            .build();
        let (body, _) = world.insert(RigidBodyTrait::dynamic(at(0, *y)), collider);
        handles.append(body);
    }
    handles
}

fn pendulum(ref world: World) -> Array<Handle> {
    let pivot = world.insert_body(RigidBodyTrait::fixed(at(0, 0)));
    let bob = ColliderBuilderTrait::ball(f(ONE_RAW / 4)).active_events(COLLISION_EVENTS).build();
    let (body, _) = world.insert(RigidBodyTrait::dynamic(at(ONE_RAW, 0)), bob);
    let joint = RevoluteJointBuilderTrait::new()
        .local_anchor1(Vec2 { x: f(0), y: f(0) })
        .local_anchor2(Vec2 { x: f(-ONE_RAW), y: f(0) })
        .build();
    let _ = world.insert_impulse_joint(pivot, body, joint);
    array![body]
}

/// A level-like proxy: a fixed ground box, three columns of four unit boxes (12 blocks) and a
/// ball of radius 1/2 fired at them at (12, 3) m/s. The ball is body 0.
pub const PILE12: u8 = 3;

fn pile12(ref world: World) -> Array<Handle> {
    let ground = ColliderBuilderTrait::cuboid(f(4 * TEN), f(HALF_RAW)).build();
    let _ = world.insert(RigidBodyTrait::fixed(at(0, -HALF_RAW)), ground);
    let mut handles = array![];
    let ball = ColliderBuilderTrait::ball(f(HALF_RAW)).active_events(COLLISION_EVENTS).build();
    let mut rb = RigidBodyTrait::dynamic(at(-6 * ONE_RAW, ONE_RAW));
    rb.set_linvel(Vec2 { x: f(12 * ONE_RAW), y: f(3 * ONE_RAW) });
    let (b, _) = world.insert(rb, ball);
    handles.append(b);
    for x in array![2 * ONE_RAW, 4 * ONE_RAW, 6 * ONE_RAW].span() {
        for y in array![2190433321_i64, 6528350290, 10866267259, 15204184228].span() {
            let collider = ColliderBuilderTrait::cuboid(f(HALF_RAW), f(HALF_RAW))
                .active_events(COLLISION_EVENTS)
                .build();
            let (body, _) = world.insert(RigidBodyTrait::dynamic(at(*x, *y)), collider);
            handles.append(body);
        }
    }
    handles
}

fn build(scene: u8, ref world: World) -> Array<Handle> {
    assert(scene <= PILE12, errors::UNKNOWN_SCENE);
    if scene == BALL_DROP {
        ball_drop(ref world)
    } else if scene == BOX_STACK3 {
        box_stack3(ref world)
    } else if scene == PENDULUM {
        pendulum(ref world)
    } else {
        pile12(ref world)
    }
}

pub fn simulate(scene: u8, steps: u32, trace: bool) -> Array<felt252> {
    let mut world = empty_world();
    let bodies = build(scene, ref world);
    let mut events: u32 = 0;
    let mut i = 0;
    while i != steps {
        events += world.step().len();
        i += 1;
        if trace {
            let y = world.body(*bodies.at(0)).unwrap().position().translation.y.raw;
            println!("tick {} y {}", i, y);
        }
    }
    let mut out = array![events.into(), bodies.len().into()];
    for handle in bodies.span() {
        let body = world.body(*handle).unwrap();
        let pose = body.position();
        let linvel = body.linvel();
        out.append(pose.translation.x.raw.into());
        out.append(pose.translation.y.raw.into());
        out.append(pose.rotation.re.raw.into());
        out.append(pose.rotation.im.raw.into());
        out.append(linvel.x.raw.into());
        out.append(linvel.y.raw.into());
        out.append(body.vels.angvel.raw.into());
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Chunked execution (spike G1b). The persistent world is serialised with `Serde` from what
// `World` exposes publicly, and rebuilt by replaying inserts then overwriting every value
// (`set`), so that the handles come out identical. This holds while no body, collider or joint
// was ever removed: the arenas' generation and free list are private (docs/research/04, E1).
// ---------------------------------------------------------------------------------------------

/// Layout version of [`ChunkState`]; bumped when the layout changes.
pub const STATE_VERSION: felt252 = 'g1b-state-1';

pub mod state_errors {
    pub const VERSION: felt252 = 'g1b: bad state version';
    pub const HANDLE: felt252 = 'g1b: handle mismatch';
    pub const TRAILING: felt252 = 'g1b: trailing state felts';
}

/// Everything a chunk needs to continue a shot: the game counters and the persistent world.
#[derive(Drop, Serde)]
pub struct ChunkState {
    pub version: felt252,
    pub tick: u32,
    pub events: u32,
    /// Handles of the observed bodies (body 0 is the projectile).
    pub observed: Array<Handle>,
    pub gravity: Vec2,
    pub integration_parameters: IntegrationParameters,
    pub bodies: Array<(Handle, RigidBody)>,
    pub colliders: Array<(Handle, Collider)>,
    pub joints: Array<(Handle, ImpulseJoint)>,
    pub pairs: Array<ContactPair>,
}

pub fn save(ref world: World, tick: u32, events: u32, observed: Array<Handle>) -> ChunkState {
    ChunkState {
        version: STATE_VERSION,
        tick,
        events,
        observed,
        gravity: world.gravity,
        integration_parameters: world.integration_parameters,
        bodies: world.bodies.iter(),
        colliders: world.colliders.iter(),
        joints: world.impulse_joints.to_array(),
        pairs: world.narrow_phase.pairs.clone(),
    }
}

/// Rebuilds the world of `state` (the returned world steps exactly as the saved one).
pub fn restore(state: @ChunkState) -> World {
    assert(*state.version == STATE_VERSION, state_errors::VERSION);
    let mut world = WorldTrait::new(*state.gravity, *state.integration_parameters);
    // Bodies first (the collider inserts below would otherwise append to their collider lists),
    // then colliders standalone, then the full values, links and change flags included.
    for (handle, body) in state.bodies.span() {
        let h = world.bodies.insert(*body);
        assert(h == *handle, state_errors::HANDLE);
    }
    for (handle, collider) in state.colliders.span() {
        let h = world.colliders.insert(*collider);
        assert(h == *handle, state_errors::HANDLE);
    }
    for (handle, body) in state.bodies.span() {
        let _ = world.bodies.set(*handle, *body);
    }
    for (handle, collider) in state.colliders.span() {
        let _ = world.colliders.set(*handle, *collider);
    }
    for (handle, joint) in state.joints.span() {
        let j = *joint;
        let h = world.impulse_joints.insert(j.body1, j.body2, j.data);
        assert(h == *handle, state_errors::HANDLE);
        let _ = world.impulse_joints.set(h, j);
    }
    world.narrow_phase.pairs = state.pairs.clone();
    world
}

fn steps_traced(ref world: World, observed: Span<Handle>, from: u32, k: u32, trace: bool) -> u32 {
    let mut events: u32 = 0;
    let mut i = 0;
    while i != k {
        events += world.step().len();
        i += 1;
        if trace {
            let y = world.body(*observed.at(0)).unwrap().position().translation.y.raw;
            println!("tick {} y {}", from + i, y);
        }
    }
    events
}

fn serialize(state: @ChunkState) -> Array<felt252> {
    let mut out = array![];
    state.serialize(ref out);
    out
}

pub const MODE_SIMULATE: u8 = 0;
pub const MODE_INIT: u8 = 1;
pub const MODE_CHUNK: u8 = 2;
pub const MODE_RUN_SAVE: u8 = 3;

/// `mode 0`: G1's `simulate(scene, steps, trace)`. `mode 1`: `init(scene) -> state`.
/// `mode 2`: `step_chunk(state, steps, trace) -> state'`. `mode 3`: build the scene and step
/// `steps` ticks in one uninterrupted world, then save: the reference for bit-exactness.
/// `state` is ignored by modes 0, 1 and 3 (pass an empty array).
#[executable]
fn main(mode: u8, scene: u8, steps: u32, trace: u8, state: Array<felt252>) -> Array<felt252> {
    if mode == MODE_SIMULATE {
        return simulate(scene, steps, trace != 0);
    }
    if mode == MODE_CHUNK {
        let mut felts = state.span();
        let saved: ChunkState = Serde::deserialize(ref felts).unwrap();
        assert(felts.len() == 0, state_errors::TRAILING);
        let mut world = restore(@saved);
        let events = steps_traced(ref world, saved.observed.span(), saved.tick, steps, trace != 0);
        let next = save(ref world, saved.tick + steps, saved.events + events, saved.observed);
        return serialize(@next);
    }
    let mut world = empty_world();
    let observed = build(scene, ref world);
    let mut events = 0;
    let mut tick = 0;
    if mode == MODE_RUN_SAVE {
        events = steps_traced(ref world, observed.span(), 0, steps, trace != 0);
        tick = steps;
    }
    serialize(@save(ref world, tick, events, observed))
}
