//! Lot S1: the jitter probe of the simulation settings (`docs/briefs/s1-substeps.md`). Every
//! dynamic body of a level is woken up and the world is stepped 300 ticks with rapier alone (no
//! calm rule, no damage): what the probe counts is what the game would meet on a pile at rest that
//! something woke up. The numbers are printed (`snforge test jitter`), the assertions are the
//! stability rules the settings must keep (no wake-up after the pile slept, no body drifting more
//! than `DRIFT_MAX_MM`). The force events are reported, not asserted: pile10 and cores3 carry a
//! static load over a timber threshold at every setting (`test_awake_pile10_load_damage_*`).

use rapier2d::prelude::{RigidBodyTrait, WorldTrait};
use slingfall_level::level::{KIND_STATIC, Level};
use crate::world::fixtures::{cores3, one_block, pile10};
use crate::world::levels::{bridge, tower, twin};
use crate::world::{Game, GameTrait};

const TICKS: u32 = 300;
/// Largest drift of a woken body over the probe, millimetres.
const DRIFT_MAX_MM: i64 = 20;

/// `|raw|` metres, in whole millimetres (floored).
fn mm(raw: i64) -> i64 {
    let abs = if raw < 0 {
        -raw
    } else {
        raw
    };
    abs * 1000 / 0x100000000
}

/// What the probe found: contact-force events over a threshold (each one a damage line in the
/// game), wake-ups (a body awake again after every body slept), the tick every body is asleep
/// from (0: never), the largest drift of a body from its start over the probe and at its end.
fn probe(name: ByteArray, level: Level) {
    let mut game: Game = GameTrait::new(@level);
    let mut start: Array<(i64, i64)> = array![];
    for entity in game.entities.span() {
        let mut body = game.world.body(*entity.body).unwrap();
        start.append((body.translation().x.raw, body.translation().y.raw));
        if *entity.kind != KIND_STATIC {
            body.wake_up(true);
            let _ = game.world.set_body(*entity.body, body);
        }
    }
    let mut events: usize = 0;
    let mut wakeups: u32 = 0;
    let mut asleep_from: u32 = 0;
    let mut peak = 0;
    let mut last = 0;
    let mut tick = 0;
    while tick != TICKS {
        let (_, forces) = game.world.step_with_force_events();
        events += forces.len();
        tick += 1;
        let mut all_asleep = true;
        let mut awake: u32 = 0;
        let mut drift = 0;
        for (k, entity) in game.entities.span().into_iter().enumerate() {
            if *entity.kind == KIND_STATIC {
                continue;
            }
            let body = game.world.body(*entity.body).unwrap();
            if !body.is_sleeping() {
                all_asleep = false;
                awake += 1;
            }
            let (x0, y0) = *start[k];
            let dx = mm(body.translation().x.raw - x0);
            let dy = mm(body.translation().y.raw - y0);
            let d = if dx > dy {
                dx
            } else {
                dy
            };
            if d > drift {
                drift = d;
            }
        }
        if awake > 0 && asleep_from != 0 {
            wakeups += 1;
        }
        if all_asleep && asleep_from == 0 {
            asleep_from = tick;
        }
        if drift > peak {
            peak = drift;
        }
        last = drift;
    }
    println!(
        "jitter {}: {} force events over threshold, {} wake-ups, all asleep from tick {}, drift peak {} mm, at the end {} mm",
        name,
        events,
        wakeups,
        asleep_from,
        peak,
        last,
    );
    assert!(wakeups == 0, "woke up again");
    assert!(peak <= DRIFT_MAX_MM, "drift over the limit");
}

#[test]
fn jitter_pile10() {
    probe("pile10", pile10());
}

#[test]
fn jitter_cores3() {
    probe("cores3", cores3());
}

#[test]
fn jitter_one_block() {
    probe("one_block", one_block());
}

#[test]
fn jitter_tower() {
    probe("tower", tower());
}

#[test]
fn jitter_bridge() {
    probe("bridge", bridge());
}

#[test]
fn jitter_twin() {
    probe("twin", twin());
}
