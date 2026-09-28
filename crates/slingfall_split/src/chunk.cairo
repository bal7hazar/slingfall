//! The chunk loop every layout shares: `slingfall_game::play::step_shot` with the three slots of
//! `crate::world` filled by the layout. At most `k` ticks of shot `shot`; stops at the end of the
//! shot. A layout is an instantiation: (a) all in process, (b) the step across a crossing, (c) the
//! rules across a call, (d) the rules across a call and the edits across a crossing.

use rapier2d::world::World;
use crate::world::{EditStage, RulesStage, Stepper, views};

/// Runs at most `k` ticks of shot `shot` of `inputs` (its felts): the ticks stepped and whether
/// the shot ended.
pub fn run<R, impl St: Stepper, impl Ru: RulesStage<R>, impl Ed: EditStage, +Drop<R>>(
    world: World, ref rules: R, inputs: Span<felt252>, shot: u8, k: u32,
) -> (World, u32, bool) {
    let mut world = world;
    let (shot, mut launch, mut watch) = Ru::begin(ref rules, inputs, shot);
    let mut stepped = 0;
    let mut over = false;
    while stepped != k {
        let mut inserted = None;
        if let Some(pebble) = launch {
            let (next, handle) = Ed::insert(world, pebble);
            world = next;
            inserted = Some(handle);
            watch.append(handle);
        }
        let (next, events) = St::step(world);
        world = next;
        let seen = views(ref world, watch.span());
        let mut out = Ru::tick(ref rules, shot, inserted, events.span(), seen.span());
        if out.calm_pending {
            world = Ed::apply(world, out.ops.span());
            let seen = views(ref world, out.watch.span());
            out = Ru::calm(ref rules, shot, seen.span());
        }
        world = Ed::apply(world, out.ops.span());
        stepped += 1;
        if out.over {
            over = true;
            break;
        }
        launch = out.launch;
        watch = out.watch;
    }
    (world, stepped, over)
}
