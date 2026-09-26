//! The `simulate` hooks of the fixtures, one layer each. Every hook returns `Outputs` built from
//! the work it did (`slingfall_game::play::outputs`), so that nothing is dropped as unused.

use rapier2d::prelude::{
    CONTACT_FORCE_EVENTS, ColliderBuilder, ColliderBuilderTrait, Fixed, IntegrationParameters,
    RigidBodyBuilderTrait, Vec2, WorldTrait,
};
use slingfall_contract::simulate::SimulateHook;
use slingfall_game::play::outputs;
use slingfall_level::inputs::{Inputs, InputsTrait};
use slingfall_level::level::{KIND_CORE, KIND_STATIC, Level, LevelTrait, ShapeDef};
use slingfall_level::outputs::Outputs;
use slingfall_rules::calm::CalmTrait;
use slingfall_rules::sling;
use slingfall_rules::world::{Entity, Game, GameTrait};

/// `slingfall_rules::world::GameTrait::new` without its `settle` step: the rapier world and the
/// entities of the level (the rules crate's private `shape` is repeated here).
fn build(level: @Level) -> Game {
    let params: IntegrationParameters = Default::default();
    let mut world = WorldTrait::new(Vec2 { x: Fixed { raw: 0 }, y: *level.gravity_y }, params);
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
    Game {
        world,
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
    }
}

fn shape(def: @ShapeDef) -> ColliderBuilder {
    match def {
        ShapeDef::Ball(radius) => ColliderBuilderTrait::ball(*radius),
        ShapeDef::Cuboid((hx, hy)) => ColliderBuilderTrait::cuboid(*hx, *hy),
        ShapeDef::Polygon(points) => ColliderBuilderTrait::convex_polygon(points.span())
            .expect('sizes: polygon'),
        ShapeDef::HalfSpace(normal) => ColliderBuilderTrait::halfspace(*normal),
    }
}

/// (c) `play`'s validation and the world of the level, no step.
pub impl WorldHook of SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs {
        level.validate();
        inputs.validate(level);
        let mut game = build(level);
        outputs(ref game, level, inputs)
    }
}

/// (c2) `GameTrait::new`: the world plus its `settle`, one `World::step` with `dt = 0`.
pub impl GameNewHook of SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs {
        level.validate();
        inputs.validate(level);
        let mut game = GameTrait::new(level);
        outputs(ref game, level, inputs)
    }
}

/// (d) `GameTrait::new` and one `World::step_with_force_events` (the tick's step).
pub impl OneStepHook of SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs {
        level.validate();
        inputs.validate(level);
        let mut game = GameTrait::new(level);
        let (collisions, forces) = game.world.step_with_force_events();
        game.score = collisions.len() + forces.len();
        outputs(ref game, level, inputs)
    }
}

/// (d2) `GameTrait::new`, the first shot's launch and one `GameTrait::tick` (step, damage,
/// removals, calm, win).
pub impl OneTickHook of SimulateHook {
    fn simulate(level: @Level, inputs: @Inputs) -> Outputs {
        level.validate();
        inputs.validate(level);
        let mut game = GameTrait::new(level);
        sling::launch(ref game, level, inputs.shots[0]);
        let report = game.tick(level);
        game.score = report.destroyed.len();
        outputs(ref game, level, inputs)
    }
}
