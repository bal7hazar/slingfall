import { isqrtCeil } from './fixed';

/** Integer pull vector of a shot: `Shot.pull_x`, `Shot.pull_y` of docs/DESIGN.md D3. */
export interface Pull {
  x: number;
  y: number;
}

/** Bound of each pull component (`[-1024, 1024]²`, docs/research/02 §1.1). */
export const PULL_LIMIT = 1024;

/** Drag length, in metres, that maps onto the full pull radius. */
export const MAX_DRAG_METRES = 3;

/**
 * Clamps a pull to the disk of radius `radius`, in integer math (`BigInt`), as D3 does: a pull with
 * `px² + py² <= R²` is kept as is; otherwise both components are scaled by `R / s`, one integer
 * square root and one division, the quotients truncated toward zero.
 *
 * D3 does not fix the rounding of the square root. `s` is the CEILING square root of `px² + py²`,
 * which guarantees that the clamped pull is inside the disk (a floor root can leave it up to one
 * unit outside). The Cairo implementation of lot G3 must use the same root and truncation, or
 * D3 must be amended: the table in `pull.test.ts` is the reference.
 */
export function clampPull(px: number, py: number, radius: number): Pull {
  if (!Number.isInteger(px) || !Number.isInteger(py) || !Number.isInteger(radius)) {
    throw new RangeError(`pull (${px}, ${py}) and radius ${radius} must be integers`);
  }
  if (radius < 0 || radius > PULL_LIMIT) {
    throw new RangeError(`pull radius ${radius} outside [0, ${PULL_LIMIT}]`);
  }
  const x = BigInt(px);
  const y = BigInt(py);
  const r = BigInt(radius);
  const squared = x * x + y * y;
  if (squared <= r * r) return { x: px, y: py };
  const s = isqrtCeil(squared);
  return { x: Number((x * r) / s), y: Number((y * r) / s) };
}

/**
 * Pull for a drag from the sling anchor to the pointer (y up), in any length unit: `full` of that
 * unit maps onto the full pull radius (default `MAX_DRAG_METRES` metres; the page passes screen
 * pixels, `fullPullPixels`). The pull points along the drag; the launch velocity is opposite
 * (`v = -pull · launch_scale`). The float to integer rounding is the only inexact step, and it is
 * the quantisation the player sees.
 */
export function pullFromDrag(dx: number, dy: number, radius: number, full = MAX_DRAG_METRES): Pull {
  const perUnit = radius / full;
  // Bound the components before the integer clamp, so that a wild pointer stays exact.
  const quantise = (v: number) =>
    Number.isFinite(v) ? Math.max(-PULL_LIMIT, Math.min(PULL_LIMIT, Math.round(v * perUnit))) : 0;
  return clampPull(quantise(dx), quantise(dy), radius);
}

/** Inverse of the drag scale: where the pebble sits, in `full`'s unit from the anchor, for a pull. */
export function pullToDrag(pull: Pull, radius: number, full = MAX_DRAG_METRES): { dx: number; dy: number } {
  const perUnit = radius / full;
  return perUnit === 0 ? { dx: 0, dy: 0 } : { dx: pull.x / perUnit, dy: pull.y / perUnit };
}

/** Share of the screen's short side a full pull drags: the drag scale does not depend on the zoom. */
export const FULL_PULL_SHARE = 0.27;

/** Drag length, in pixels, of a full pull on a `width` x `height` play area. */
export function fullPullPixels(width: number, height: number): number {
  return Math.max(1, FULL_PULL_SHARE * Math.min(width, height));
}

/**
 * Fine aiming: moves one component of the pull by `step` integer units, staying inside the disk
 * of radius `radius` (a step that would leave it stops at the last integer inside). Every integer
 * pull of the disk is reachable from (0, 0): along x first, then along y, every point on the way
 * is inside the disk.
 */
export function nudgePull(pull: Pull, axis: 'x' | 'y', step: number, radius: number): Pull {
  if (!Number.isInteger(step)) throw new RangeError(`nudge ${step} must be an integer`);
  const other = axis === 'x' ? pull.y : pull.x;
  const room = radius * radius - other * other;
  if (room < 0) return pull;
  // The largest |v| with v² <= room, in integers.
  let limit = Math.floor(Math.sqrt(room));
  while (limit * limit > room) limit--;
  while ((limit + 1) * (limit + 1) <= room) limit++;
  const value = Math.max(-limit, Math.min(limit, pull[axis] + step)) + 0; // + 0: no -0
  return axis === 'x' ? { x: value, y: pull.y } : { x: pull.x, y: value };
}
