import { mulFloor } from './fixed';
import type { Pull } from './pull';
import type { TraceLevel } from '../trace/types';

/**
 * The exact flight arc of the pebble, before any contact (docs/DESIGN.md D8).
 *
 * Reference formula, all values raw Q32.32 `bigint`, `mul(a, b) = (a * b) >> 32` (the exact
 * product floored, one rescale: the `fixed` crate's `Mul`):
 *
 *   launch:  v = ( -pull_x * launch_scale , -pull_y * launch_scale )      (integer times raw, exact)
 *   p_0      = sling_anchor
 *   tick i:  v_y += mul(gravity_y, DT)               semi-implicit Euler: velocity first,
 *            p   += ( mul(v_x, DT) , mul(v_y, DT) )  then position with the NEW velocity
 *   DT       = 71582788 = floor(2^32 / 60)
 *
 * `flightArc` returns p_1, p_2, ... (p_0 is the anchor). Lot G4 asserts these against the
 * rapier `integrate` of the trace build for a pebble in free flight (no drag, no damping).
 */
export const TICK_DT_RAW = 71582788n;

/** Dots of the preview at most: two seconds of flight. */
export const MAX_ARC_TICKS = 120;

export interface ArcPoint {
  x: bigint;
  y: bigint;
}

export interface ArcParams {
  anchor: ArcPoint;
  gravityY: bigint;
  launchScale: bigint;
  minX: bigint;
  minY: bigint;
  maxX: bigint;
  maxY: bigint;
}

export function arcParamsFromLevel(level: TraceLevel): ArcParams {
  return {
    anchor: { x: BigInt(level.sling_anchor.x), y: BigInt(level.sling_anchor.y) },
    gravityY: BigInt(level.gravity_y),
    launchScale: BigInt(level.launch_scale),
    minX: BigInt(level.bounds.min_x),
    minY: BigInt(level.bounds.min_y),
    maxX: BigInt(level.bounds.max_x),
    maxY: BigInt(level.bounds.max_y),
  };
}

/** Launch velocity `-pull · launch_scale`, raw. */
export function launchVelocity(pull: Pull, launchScale: bigint): ArcPoint {
  return { x: -BigInt(pull.x) * launchScale, y: -BigInt(pull.y) * launchScale };
}

/** Positions after ticks 1..n, stopping before the first one outside `bounds` or at `maxTicks`. */
export function flightArc(params: ArcParams, pull: Pull, maxTicks = MAX_ARC_TICKS): ArcPoint[] {
  const v = launchVelocity(pull, params.launchScale);
  const dvy = mulFloor(params.gravityY, TICK_DT_RAW);
  let { x, y } = params.anchor;
  const points: ArcPoint[] = [];
  for (let tick = 1; tick <= maxTicks; tick++) {
    v.y += dvy;
    x += mulFloor(v.x, TICK_DT_RAW);
    y += mulFloor(v.y, TICK_DT_RAW);
    if (x < params.minX || x > params.maxX || y < params.minY || y > params.maxY) break;
    points.push({ x, y });
  }
  return points;
}
