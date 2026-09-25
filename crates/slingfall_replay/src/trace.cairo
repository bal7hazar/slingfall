//! Trace build: `main_trace`, the observer printing per-tick poses and game events for the
//! client (`docs/DESIGN.md` D1). Lot G4.
//!
//! [`TraceObserver`] prints **trace lines v1**, one `println!` per line, space-separated tokens,
//! every number in decimal (raw Q32.32 values as signed `i64`, as the client's `RawFixed`):
//!
//! ```text
//! trace 1
//! level <gravity_y> <launch_scale> <pull_radius> <shots> <min_x> <min_y> <max_x> <max_y>
//! <anchor_x> <anchor_y> <bodies>
//! material <index> <score>                                   (one per level material)
//! body <handle> <kind> <material> <x> <y> <re> <im> <shape>  (one per level body)
//!     <shape> = ball <r> | cuboid <hx> <hy> | polygon <n> <x> <y>... | halfspace <nx> <ny>
//! frame <tick> (<handle> <x> <y> <re> <im> <asleep>)*        (every tick)
//! damage <tick> <handle> <hp>
//! destroyed <tick> <handle>
//! score <tick> <points> <total>
//! shot_end <tick> <shot>
//! ```
//!
//! `kind` is 0 static, 1 block, 2 core; `asleep` is 0 or 1. A level body's handle is its index in
//! `level.bodies`; the pebble of shot `s` (0-based) has handle `bodies + s`, so a handle in no
//! `body` line is a pebble (rapier may reuse a freed slot for the pebble: its engine handle is
//! never printed). A frame lists the live dynamic bodies of the tick, ascending, the pebble last;
//! static bodies never appear. Per tick the events come first (damage ascending, then each
//! destroyed body in the rules' order with its score), then the frame; at the end of a shot, the
//! unused-shot bonus (a `score` line) then `shot_end`, both at the shot's last tick.
//! `tools/tracec/tracec.py` turns these lines into trace format v1 JSON (`client/README.md`).

use rapier2d::prelude::{Pose2, RigidBodyTrait, Vec2, WorldTrait};
use slingfall_level::inputs::Inputs;
use slingfall_level::level::{KIND_STATIC, Level, ShapeDef};
use slingfall_level::outputs::OutputsTrait;
use slingfall_rules::world::{Entity, Game, TickReport};
use crate::main::{Observer, decode, errors, play};

#[cfg(test)]
mod tests;

/// Version of the trace lines (the first line, `trace <version>`).
pub const TRACE_LINES_VERSION: u8 = 1;

/// The trace build's observer. Keeps the last printed `hp` of every level body and the score, so
/// that it prints what changed, and the last printed pose of every level body with its text: a
/// sleeping body does not move, and formatting its four values again would be most of the
/// trace's cost (README, "Steps").
#[derive(Drop)]
pub struct TraceObserver {
    /// Last `hp` of each level body.
    hp: Array<u32>,
    /// D7 score of each level body (its material's), for the `score` line of its destruction.
    points: Array<u32>,
    /// Last printed total.
    score: u32,
    /// Per level body, its last frame entry; empty before the first frame (and for a static or
    /// removed body).
    poses: Array<CachedPose>,
}

/// A body's pose in a frame and its text ` <handle> <x> <y> <re> <im>`.
#[derive(Drop)]
struct CachedPose {
    pose: Pose2,
    text: ByteArray,
}

#[generate_trait]
pub impl TraceObserverImpl of TraceObserverTrait {
    /// An observer for a whole replay: [`Observer::on_level`] fills it.
    fn new() -> TraceObserver {
        TraceObserver { hp: array![], points: array![], score: 0, poses: array![] }
    }

    /// An observer resuming a game restored mid-level (chunked build): no header is printed.
    fn resume(level: @Level, entities: Span<Entity>, score: u32) -> TraceObserver {
        let mut hp: Array<u32> = array![];
        for entity in entities {
            hp.append(*entity.hp);
        }
        TraceObserver { hp, points: points(level), score, poses: array![] }
    }
}

pub impl TraceObserverObserver of Observer<TraceObserver> {
    fn on_level(ref self: TraceObserver, level: @Level) {
        let materials = level.materials.span();
        let mut hp: Array<u32> = array![];
        for def in level.bodies.span() {
            hp.append(*materials[(*def.material).into()].hp);
        }
        self.hp = hp;
        self.points = points(level);
        self.score = 0;
        print_header(level);
    }

    fn on_tick(ref self: TraceObserver, ref game: Game, report: @TickReport) {
        let tick = game.tick;
        // Damage, ascending.
        let entities = game.entities.span();
        let mut hp: Array<u32> = array![];
        let mut index: u32 = 0;
        for last in self.hp.span() {
            let now = *entities[index].hp;
            if now != *last {
                let mut line: ByteArray = "damage";
                push_u32(ref line, tick);
                push_u32(ref line, index);
                push_u32(ref line, now);
                println!("{}", line);
            }
            hp.append(now);
            index += 1;
        }
        self.hp = hp;
        // Destroyed bodies, each with its score.
        let points = self.points.span();
        for destroyed in report.destroyed.span() {
            let mut line: ByteArray = "destroyed";
            push_u32(ref line, tick);
            push_u32(ref line, *destroyed);
            println!("{}", line);
            let gained = *points[*destroyed];
            self.score += gained;
            print_score(tick, gained, self.score);
        }
        // The frame; a pose equal to the body's last one reuses its text.
        let mut line: ByteArray = "frame";
        push_u32(ref line, tick);
        let mut last = self.poses;
        let mut poses: Array<CachedPose> = array![];
        let mut index: u32 = 0;
        for entity in entities {
            let cached = last.pop_front();
            if *entity.alive && *entity.kind != KIND_STATIC {
                let body = game.world.body(*entity.body).unwrap();
                let pose = body.position();
                let text = match cached {
                    Some(cached) => if same_pose(@cached.pose, @pose) {
                        cached.text
                    } else {
                        pose_text(index, pose)
                    },
                    None => pose_text(index, pose),
                };
                line.append(@text);
                push_asleep(ref line, body.is_sleeping());
                poses.append(CachedPose { pose, text });
            } else {
                poses.append(CachedPose { pose: Default::default(), text: "" });
            }
            index += 1;
        }
        self.poses = poses;
        if let Some(pebble) = game.pebble {
            let body = game.world.body(pebble).unwrap();
            line.append(@pose_text(index + game.shots_used.into(), body.position()));
            push_asleep(ref line, body.is_sleeping());
        }
        println!("{}", line);
    }

    fn on_shot_end(ref self: TraceObserver, ref game: Game, shot: u8) {
        let tick = game.tick;
        if game.score != self.score {
            print_score(tick, game.score - self.score, game.score);
            self.score = game.score;
        }
        let mut line: ByteArray = "shot_end";
        push_u32(ref line, tick);
        push_u32(ref line, shot.into());
        println!("{}", line);
    }
}

/// The D7 score of each level body (its material's).
fn points(level: @Level) -> Array<u32> {
    let materials = level.materials.span();
    let mut points: Array<u32> = array![];
    for def in level.bodies.span() {
        points.append(*materials[(*def.material).into()].score);
    }
    points
}

fn print_score(tick: u32, points: u32, total: u32) {
    let mut line: ByteArray = "score";
    push_u32(ref line, tick);
    push_u32(ref line, points);
    push_u32(ref line, total);
    println!("{}", line);
}

/// The `trace`, `level`, `material` and `body` lines.
fn print_header(level: @Level) {
    let mut line: ByteArray = "trace";
    push_u32(ref line, TRACE_LINES_VERSION.into());
    println!("{}", line);
    let (min_x, min_y, max_x, max_y) = *level.bounds;
    let mut line: ByteArray = "level";
    push_i64(ref line, (*level.gravity_y).raw);
    push_i64(ref line, (*level.launch_scale).raw);
    push_u32(ref line, (*level.pull_radius).into());
    push_u32(ref line, (*level.shots).into());
    push_i64(ref line, min_x.raw);
    push_i64(ref line, min_y.raw);
    push_i64(ref line, max_x.raw);
    push_i64(ref line, max_y.raw);
    push_vec2(ref line, *level.sling_anchor);
    push_u32(ref line, level.bodies.len());
    println!("{}", line);
    let mut index: u32 = 0;
    for material in level.materials.span() {
        let mut line: ByteArray = "material";
        push_u32(ref line, index);
        push_u32(ref line, *material.score);
        println!("{}", line);
        index += 1;
    }
    let mut index: u32 = 0;
    for def in level.bodies.span() {
        let mut line: ByteArray = "body";
        push_u32(ref line, index);
        push_u32(ref line, (*def.kind).into());
        push_u32(ref line, (*def.material).into());
        push_pose(ref line, *def.pose);
        match def.shape {
            ShapeDef::Ball(radius) => {
                line.append(@" ball");
                push_i64(ref line, (*radius).raw);
            },
            ShapeDef::Cuboid((
                hx, hy,
            )) => {
                line.append(@" cuboid");
                push_i64(ref line, (*hx).raw);
                push_i64(ref line, (*hy).raw);
            },
            ShapeDef::Polygon(points) => {
                line.append(@" polygon");
                push_u32(ref line, points.len());
                for point in points.span() {
                    push_vec2(ref line, *point);
                }
            },
            ShapeDef::HalfSpace(normal) => {
                line.append(@" halfspace");
                push_vec2(ref line, *normal);
            },
        }
        println!("{}", line);
        index += 1;
    }
}

/// ` <handle> <x> <y> <re> <im>`.
fn pose_text(handle: u32, pose: Pose2) -> ByteArray {
    let mut text: ByteArray = "";
    push_u32(ref text, handle);
    push_pose(ref text, pose);
    text
}

/// ` <asleep>`, 0 or 1.
fn push_asleep(ref line: ByteArray, asleep: bool) {
    line.append_word(if asleep {
        ' 1'
    } else {
        ' 0'
    }, 2);
}

/// Same raw values.
fn same_pose(a: @Pose2, b: @Pose2) -> bool {
    *a.translation.x.raw == *b.translation.x.raw
        && *a.translation.y.raw == *b.translation.y.raw
        && *a.rotation.re.raw == *b.rotation.re.raw
        && *a.rotation.im.raw == *b.rotation.im.raw
}

fn push_pose(ref line: ByteArray, pose: Pose2) {
    push_vec2(ref line, pose.translation);
    push_i64(ref line, pose.rotation.re.raw);
    push_i64(ref line, pose.rotation.im.raw);
}

fn push_vec2(ref line: ByteArray, v: Vec2) {
    push_i64(ref line, v.x.raw);
    push_i64(ref line, v.y.raw);
}

/// Appends ` <value>` in decimal.
pub fn push_u32(ref line: ByteArray, value: u32) {
    push_decimal(ref line, value.into(), false);
}

/// Appends ` <value>` in decimal, `-` for a negative value.
pub fn push_i64(ref line: ByteArray, value: i64) {
    if value >= 0 {
        push_decimal(ref line, value.try_into().unwrap(), false);
    } else if value == -0x8000000000000000 {
        push_decimal(ref line, 0x8000000000000000, true);
    } else {
        push_decimal(ref line, (-value).try_into().unwrap(), true);
    }
}

/// Appends a space, the sign and the digits of `magnitude` as one word: at most 22 bytes, under
/// the 31 of a `bytes31`. Digits are produced two at a time, lowest first, each placed at its byte
/// offset from the right.
fn push_decimal(ref line: ByteArray, magnitude: u64, negative: bool) {
    let mut word: felt252 = 0;
    let mut scale: felt252 = 1;
    let mut len: usize = 0;
    let mut rest = magnitude;
    let hundred: NonZero<u64> = 100;
    let ten: NonZero<u64> = 10;
    // `rest >= 100`: two digits per `DivRem`.
    while rest >= 100 {
        let (q, pair) = DivRem::div_rem(rest, hundred);
        let (tens, ones) = DivRem::div_rem(pair, ten);
        word += (ones.into() + '0') * scale + (tens.into() + '0') * scale * 0x100;
        scale *= 0x10000;
        len += 2;
        rest = q;
    }
    if rest >= 10 {
        let (tens, ones) = DivRem::div_rem(rest, ten);
        word += (ones.into() + '0') * scale + (tens.into() + '0') * scale * 0x100;
        scale *= 0x10000;
        len += 2;
    } else {
        word += (rest.into() + '0') * scale;
        scale *= 0x100;
        len += 1;
    }
    if negative {
        word += '-' * scale;
        scale *= 0x100;
        len += 1;
    }
    word += ' ' * scale;
    line.append_word(word, len + 1);
}

/// Trace build: [`play`] with a [`TraceObserver`]. Same arguments and outputs as
/// `crate::main::main`; prints the trace lines v1 of the replay.
#[executable]
pub fn main_trace(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252> {
    let level: Level = decode(level.span(), errors::LEVEL);
    let inputs: Inputs = decode(inputs.span(), errors::INPUTS);
    let mut obs = TraceObserverTrait::new();
    play(@level, @inputs, ref obs).to_felts()
}
