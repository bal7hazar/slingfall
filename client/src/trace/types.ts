// Trace of a replay as the renderer consumes it. Placeholder layout until the trace build of lot
// G4 (`main_trace`) fixes it; G6 owns its evolution. Scalars stay raw Q32.32 integers (decimal
// strings, exact) and are converted to `number` only for drawing (docs/DESIGN.md D8).

/** A raw Q32.32 value (`fixed::Fixed.raw`, an `i64`) as a decimal string. */
export type RawFixed = string;

/** Pose of one body at one tick. */
export interface BodyPose {
  handle: number;
  x: RawFixed;
  y: RawFixed;
  /** Unit complex rotation (`Rot2 { re, im }`). */
  re: RawFixed;
  im: RawFixed;
}

/** One tick of the replay. */
export interface TraceFrame {
  tick: number;
  bodies: BodyPose[];
}

export interface Trace {
  version: number;
  frames: TraceFrame[];
}

const ONE = 2 ** 32;

/** Raw Q32.32 to `number`, for drawing only. */
export function fixedToNumber(raw: RawFixed): number {
  return Number(BigInt(raw)) / ONE;
}
