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
 * Pull for a drag from the sling anchor to the pointer, in metres (world axes, y up). The pull
 * points along the drag; the launch velocity is opposite (`v = -pull · launch_scale`). The float
 * to integer rounding is the only inexact step, and it is the quantisation the player sees.
 */
export function pullFromDrag(dx: number, dy: number, radius: number): Pull {
  const perMetre = radius / MAX_DRAG_METRES;
  // Bound the components before the integer clamp, so that a wild pointer stays exact.
  const quantise = (v: number) =>
    Number.isFinite(v) ? Math.max(-PULL_LIMIT, Math.min(PULL_LIMIT, Math.round(v * perMetre))) : 0;
  return clampPull(quantise(dx), quantise(dy), radius);
}

/** Inverse of the drag scale: where the pebble sits, in metres from the anchor, for a pull. */
export function pullToDrag(pull: Pull, radius: number): { dx: number; dy: number } {
  const perMetre = radius / MAX_DRAG_METRES;
  return perMetre === 0 ? { dx: 0, dy: 0 } : { dx: pull.x / perMetre, dy: pull.y / perMetre };
}
