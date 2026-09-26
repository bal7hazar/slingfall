import { containsPoint, obstaclesFromLevel, type Aabb } from './contact';
import { mulFloor } from './fixed';
import type { Pull } from './pull';
import type { TraceLevel } from '../trace/types';

/**
 * The exact flight arc of the pebble, before any contact (docs/DESIGN.md D8).
 *
 * rapier integrates a free flight as `SUBSTEPS` semi-implicit Euler steps of `h = dt // SUBSTEPS`
 * per tick, gravity included in each (lot S1, escalation 1). All values are raw Q32.32 `bigint`,
 * `mul(a, b) = (a * b) >> 32` (the exact product floored, one rescale: the `fixed` crate's `Mul`):
 *
 *   launch:  v = ( -pull_x * launch_scale , -pull_y * launch_scale )      (integer times raw, exact)
 *   p_0      = sling_anchor
 *   tick i:  SUBSTEPS times:
 *              v_y += mul(gravity_y, h)                   velocity first,
 *              p   += ( mul(v_x, h) , mul(v_y, h) )       then position with the NEW velocity
 *   dt       = TICK_DT_RAW = 71582788 = floor(2^32 / 60)
 *   h        = SUBSTEP_DT_RAW = dt // SUBSTEPS = 17895697   (integer division of the raw dt, so
 *              SUBSTEPS * h <= dt: up to SUBSTEPS - 1 raw units of a tick are dropped, as in the engine)
 *
 * `flightArc` returns the pebble after each tick, p_1, p_2, ... (p_0 is the anchor); the substeps
 * inside a tick are not returned. Bit-exact against the pebble's frames in
 * `fixtures/traces/pile10-reference.json` (`arc.test.ts`) and `tools/golden/matrix.py::arc_points`.
 *
 * `SUBSTEPS` mirrors `SOLVER_ITERATIONS` in `crates/slingfall_rules/src/world.cairo`: a change of
 * that setting is a change of this constant (`docs/levels.md`, "Simulation setting"), nothing else.
 */
export const TICK_DT_RAW = 71582788n;

/** Euler steps per tick: rapier's `num_solver_iterations` (`SOLVER_ITERATIONS = 4`). */
export const SUBSTEPS = 4;

/** Length of one substep, raw: the integer division of `TICK_DT_RAW` (`dt // SUBSTEPS`). */
export const SUBSTEP_DT_RAW = TICK_DT_RAW / BigInt(SUBSTEPS);

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
  /** Bodies the preview stops at (`contact.ts`); none when absent. */
  obstacles?: Aabb[];
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
    obstacles: obstaclesFromLevel(level),
  };
}

/** Launch velocity `-pull · launch_scale`, raw. */
export function launchVelocity(pull: Pull, launchScale: bigint): ArcPoint {
  return { x: -BigInt(pull.x) * launchScale, y: -BigInt(pull.y) * launchScale };
}

/**
 * Positions after ticks 1..n, stopping before the first one outside `bounds`, at `maxTicks`, or
 * after the first one inside an obstacle's AABB (that dot is kept: it is where the pebble arrives).
 * The contact cut is a display cut, not physics: the AABB of a body is an approximation of its
 * shape, the pebble is a point, and the engine may touch a body between two ticks.
 */
export function flightArc(params: ArcParams, pull: Pull, maxTicks = MAX_ARC_TICKS): ArcPoint[] {
  const v = launchVelocity(pull, params.launchScale);
  const dvy = mulFloor(params.gravityY, SUBSTEP_DT_RAW);
  const obstacles = params.obstacles ?? [];
  let { x, y } = params.anchor;
  const points: ArcPoint[] = [];
  for (let tick = 1; tick <= maxTicks; tick++) {
    for (let substep = 0; substep < SUBSTEPS; substep++) {
      v.y += dvy;
      x += mulFloor(v.x, SUBSTEP_DT_RAW);
      y += mulFloor(v.y, SUBSTEP_DT_RAW);
    }
    if (x < params.minX || x > params.maxX || y < params.minY || y > params.maxY) break;
    points.push({ x, y });
    if (obstacles.some((box) => containsPoint(box, x, y))) break;
  }
  return points;
}
