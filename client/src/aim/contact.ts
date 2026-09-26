import { mulFloor } from './fixed';
import type { LevelBody, Shape, TraceLevel } from '../trace/types';

/**
 * Where the aim preview stops: the axis-aligned boxes of the level's bodies at their settled
 * poses. A display cut, NOT physics (the engine decides contacts on the real shapes, and a pebble
 * that touches a body between two ticks is not seen here). Raw Q32.32 `bigint`, edges inclusive.
 */
export interface Aabb {
  minX: bigint;
  minY: bigint;
  maxX: bigint;
  maxY: bigint;
}

export function containsPoint(box: Aabb, x: bigint, y: bigint): boolean {
  return x >= box.minX && x <= box.maxX && y >= box.minY && y <= box.maxY;
}

const abs = (a: bigint): bigint => (a < 0n ? -a : a);

/** Half extents of the box around a body-local box `(hx, hy)` turned by the unit rotation `(re, im)`. */
function turnedHalfExtents(hx: bigint, hy: bigint, re: bigint, im: bigint): [bigint, bigint] {
  return [mulFloor(hx, abs(re)) + mulFloor(hy, abs(im)), mulFloor(hx, abs(im)) + mulFloor(hy, abs(re))];
}

/**
 * The box of one body, or `undefined` for a shape that stops nothing. A half-space is the side
 * its normal points away from, cut at the body position along the dominant axis of the normal and
 * clipped to the level `bounds`.
 */
export function bodyAabb(body: LevelBody, bounds: Aabb): Aabb | undefined {
  const x = BigInt(body.pose.x);
  const y = BigInt(body.pose.y);
  const re = BigInt(body.pose.re);
  const im = BigInt(body.pose.im);
  const shape: Shape = body.shape;
  let hx: bigint;
  let hy: bigint;
  switch (shape.type) {
    case 'ball':
      hx = hy = BigInt(shape.radius);
      break;
    case 'cuboid':
      [hx, hy] = turnedHalfExtents(BigInt(shape.hx), BigInt(shape.hy), re, im);
      break;
    case 'polygon': {
      hx = hy = 0n;
      for (const vertex of shape.vertices) {
        const lx = BigInt(vertex.x);
        const ly = BigInt(vertex.y);
        const wx = abs(mulFloor(lx, re) - mulFloor(ly, im));
        const wy = abs(mulFloor(lx, im) + mulFloor(ly, re));
        if (wx > hx) hx = wx;
        if (wy > hy) hy = wy;
      }
      break;
    }
    case 'halfspace': {
      const nx = mulFloor(BigInt(shape.normal.x), re) - mulFloor(BigInt(shape.normal.y), im);
      const ny = mulFloor(BigInt(shape.normal.x), im) + mulFloor(BigInt(shape.normal.y), re);
      if (abs(ny) >= abs(nx)) {
        return ny > 0n ? { ...bounds, maxY: y } : { ...bounds, minY: y };
      }
      return nx > 0n ? { ...bounds, maxX: x } : { ...bounds, minX: x };
    }
  }
  return { minX: x - hx, minY: y - hy, maxX: x + hx, maxY: y + hy };
}

/** The boxes of every body of the level (a pebble is in no `bodies` entry). */
export function obstaclesFromLevel(level: TraceLevel): Aabb[] {
  const bounds: Aabb = {
    minX: BigInt(level.bounds.min_x),
    minY: BigInt(level.bounds.min_y),
    maxX: BigInt(level.bounds.max_x),
    maxY: BigInt(level.bounds.max_y),
  };
  const boxes: Aabb[] = [];
  for (const body of level.bodies) {
    const box = bodyAabb(body, bounds);
    if (box) boxes.push(box);
  }
  return boxes;
}
