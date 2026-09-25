// Recorded trace format v1, as the renderer consumes it. The trace build of lot G4 (`main_trace`)
// emits the same layout; G6 owns its evolution until then. Scalars stay raw Q32.32 integers
// (decimal strings, exact) and are converted to `number` only for drawing (docs/DESIGN.md D8).

/** A raw Q32.32 value (`fixed::Fixed.raw`, an `i64`) as a decimal string. */
export type RawFixed = string;

export const TRACE_VERSION = 1;

const FRACTION_BITS = 32n;
const FRACTION_MASK = (1n << FRACTION_BITS) - 1n;
const ONE = 2 ** 32;

/**
 * Raw Q32.32 to `number`, for drawing only. Integer part and fraction are converted separately so
 * that the result is the correctly rounded value for every `i64` (a direct `Number(raw)` would
 * round twice above 2^53).
 */
export function fixedToNumber(raw: RawFixed): number {
  const value = BigInt(raw);
  return Number(value >> FRACTION_BITS) + Number(value & FRACTION_MASK) / ONE;
}

export interface Vec2Raw {
  x: RawFixed;
  y: RawFixed;
}

/** The despawn AABB of the level (`Level.bounds`). */
export interface BoundsRaw {
  min_x: RawFixed;
  min_y: RawFixed;
  max_x: RawFixed;
  max_y: RawFixed;
}

/** `ShapeDef` of docs/DESIGN.md D2, in body-local coordinates. */
export type Shape =
  | { type: 'ball'; radius: RawFixed }
  | { type: 'cuboid'; hx: RawFixed; hy: RawFixed }
  | { type: 'polygon'; vertices: Vec2Raw[] }
  | { type: 'halfspace'; normal: Vec2Raw };

export type BodyKind = 'static' | 'block' | 'core';

/** Pose of one body: position and unit complex rotation (`Rot2 { re, im }`). */
export interface PoseRaw {
  x: RawFixed;
  y: RawFixed;
  re: RawFixed;
  im: RawFixed;
}

export interface LevelBody {
  handle: number;
  kind: BodyKind;
  shape: Shape;
  /** D12 name: `timber`, `slate`, `frost`, `core`, `ground`; an unknown name draws grey. */
  material: string;
  /** Settled pose at tick 0; frames override it while they carry the body. */
  pose: PoseRaw;
}

/**
 * The part of the level the client needs. `bounds`, `sling_anchor` and `bodies` are the format
 * the brief fixes; `gravity_y`, `launch_scale`, `pull_radius` and `shots` are the `Level` fields
 * (D2) the aim arc and the HUD read. A body handle that is in no `bodies` entry is a pebble.
 */
export interface TraceLevel {
  bounds: BoundsRaw;
  sling_anchor: Vec2Raw;
  gravity_y: RawFixed;
  launch_scale: RawFixed;
  pull_radius: number;
  shots: number;
  bodies: LevelBody[];
}

/** Pose of one body at one tick; a body absent from a frame does not exist at that tick. */
export interface BodyPose extends PoseRaw {
  handle: number;
  asleep: boolean;
}

/** One tick of the replay. Ticks strictly increase across frames. */
export interface TraceFrame {
  tick: number;
  bodies: BodyPose[];
}

/** Game events, in emission order (docs/DESIGN.md D6, D7). */
export type TraceEvent =
  | { tick: number; kind: 'damage'; handle: number; hp: number }
  | { tick: number; kind: 'destroyed'; handle: number }
  | { tick: number; kind: 'score'; points: number; total: number }
  | { tick: number; kind: 'shot_end'; shot: number };

export interface Trace {
  version: typeof TRACE_VERSION;
  level: TraceLevel;
  frames: TraceFrame[];
  events: TraceEvent[];
}
