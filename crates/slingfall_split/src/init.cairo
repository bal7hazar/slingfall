//! `init(level)` on declared classes: `slingfall_rules::world::GameTrait::new` in two parts, the
//! world built from the level ([`build`], no step) and main's settle step ([`settle`]: one
//! `dt = 0` step, then every dynamic body back to sleep), the settle step with `SlimSplitStages`.
//! Main's `GameTrait::new` steps in process, which a declared class cannot compile.

use rapier2d::prelude::{
    BasicStepConfig, CONTACT_FORCE_EVENTS, ColliderBuilder, ColliderBuilderTrait, Fixed,
    IntegrationParameters, RigidBodyBuilderTrait, Vec2, WorldTrait,
};
use rapier2d::world::World;
use rapier2d_classes::{ClassHashes, SlimSplitStages};
use slingfall_game::play::ShotProgress;
use slingfall_level::level::{KIND_CORE, KIND_STATIC, Level, LevelTrait, ShapeDef};
use slingfall_rules::calm::CalmTrait;
use slingfall_rules::world::{Entity, SOLVER_ITERATIONS, TICK_DT_RAW, errors};
use crate::rules::{Op, Rules, params};

/// `GameTrait::new` up to the settle step: the level validated, one body and one collider per
/// `BodyDef` in level order, and the rules state (`tick` 0, no shot).
///
/// # Panics
/// As `GameTrait::new` and `LevelTrait::validate`.
pub fn build(level: @Level) -> (World, Rules) {
    level.validate();
    let mut integration: IntegrationParameters = Default::default();
    integration.dt = Fixed { raw: TICK_DT_RAW };
    integration.num_solver_iterations = SOLVER_ITERATIONS;
    let mut world = WorldTrait::new(Vec2 { x: Fixed { raw: 0 }, y: *level.gravity_y }, integration);
    let materials = level.materials.span();
    let mut entities: Array<Entity> = array![];
    let mut cores_left: u8 = 0;
    let mut index: usize = 0;
    for def in level.bodies.span() {
        let kind = *def.kind;
        let material = *materials[(*def.material).into()];
        let mut collider = shape(def.shape)
            .density(material.density)
            .friction(material.friction)
            .restitution(material.restitution)
            .contact_force_event_threshold(material.force_threshold)
            .user_data(index.into());
        let body = if kind == KIND_STATIC {
            RigidBodyBuilderTrait::fixed().position(*def.pose).build()
        } else {
            collider = collider.active_events(CONTACT_FORCE_EVENTS);
            RigidBodyBuilderTrait::dynamic().position(*def.pose).sleeping(true).build()
        };
        let (body, collider) = world.insert(body, collider.build());
        if body.index != index || collider.index != index {
            core::panic_with_felt252(errors::HANDLE_ORDER);
        }
        entities
            .append(
                Entity {
                    body, collider, kind, material: *def.material, hp: material.hp, alive: true,
                },
            );
        if kind == KIND_CORE {
            cores_left += 1;
        }
        index += 1;
    }
    let rules = Rules {
        params: params(level),
        level_hash: level.hash(),
        entities,
        cores_left,
        score: 0,
        shots_used: 0,
        tick: 0,
        shot_tick: 0,
        pebble: None,
        pebble_contact: false,
        pebble_contact_tick: 0,
        calm: CalmTrait::new(),
        progress: Default::<ShotProgress>::default(),
    };
    (world, rules)
}

/// Main's settle step with `SlimSplitStages<H>`: `dt = 0`, one step without force events, `dt`
/// restored. `sleep_all` follows (the sleeps of [`settle_sleeps`], `EditClass::sleep_all`: the
/// World edits do not fit next to the step).
pub fn settle<impl H: ClassHashes>(world: World) -> World {
    let mut world = world;
    let dt = world.integration_parameters.dt;
    world.integration_parameters.dt = Fixed { raw: 0 };
    let _ = world.step_with_stages::<BasicStepConfig, SlimSplitStages<H>>();
    world.integration_parameters.dt = dt;
    world
}

/// The sleeps of `sleep_all` right after [`build`]: every dynamic entity.
pub fn settle_sleeps(rules: @Rules) -> Array<Op> {
    let mut ops = array![];
    for entity in rules.entities.span() {
        if *entity.kind != KIND_STATIC {
            ops.append(Op::Sleep(*entity.body));
        }
    }
    ops
}

/// The world of `build` alone (a size fixture).
pub fn build_world(level: @Level) -> World {
    let (world, _) = build(level);
    world
}

/// `slingfall_rules::world::shape` (private there).
fn shape(def: @ShapeDef) -> ColliderBuilder {
    match def {
        ShapeDef::Ball(radius) => ColliderBuilderTrait::ball(*radius),
        ShapeDef::Cuboid((hx, hy)) => ColliderBuilderTrait::cuboid(*hx, *hy),
        ShapeDef::Polygon(points) => ColliderBuilderTrait::convex_polygon(points.span())
            .expect(errors::POLYGON),
        ShapeDef::HalfSpace(normal) => ColliderBuilderTrait::halfspace(*normal),
    }
}
