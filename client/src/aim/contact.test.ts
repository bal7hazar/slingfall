import { describe, expect, it } from 'vitest';
import { ONE_RAW } from './fixed';
import { bodyAabb, containsPoint, obstaclesFromLevel, type Aabb } from './contact';
import type { LevelBody, TraceLevel } from '../trace/types';

const q = (metres: number): string => String(BigInt(Math.round(metres * 2 ** 32)));
const BOUNDS: Aabb = { minX: -10n * ONE_RAW, minY: -10n * ONE_RAW, maxX: 100n * ONE_RAW, maxY: 50n * ONE_RAW };
const pose = (x: number, y: number, re = 1, im = 0) => ({ x: q(x), y: q(y), re: q(re), im: q(im) });
const body = (shape: LevelBody['shape'], p = pose(0, 0)): LevelBody => ({
  handle: 1,
  kind: 'block',
  shape,
  material: 'timber',
  pose: p,
});

describe('body boxes', () => {
  it('a cuboid is its half extents around the pose', () => {
    const box = bodyAabb(body({ type: 'cuboid', hx: q(0.5), hy: q(1) }, pose(10, 2)), BOUNDS);
    expect(box).toEqual({ minX: BigInt(q(9.5)), minY: BigInt(q(1)), maxX: BigInt(q(10.5)), maxY: BigInt(q(3)) });
  });

  it('a cuboid turned a quarter swaps its extents', () => {
    const box = bodyAabb(body({ type: 'cuboid', hx: q(0.5), hy: q(1) }, pose(10, 2, 0, 1)), BOUNDS);
    expect(box).toEqual({ minX: BigInt(q(9)), minY: BigInt(q(1.5)), maxX: BigInt(q(11)), maxY: BigInt(q(2.5)) });
  });

  it('a ball is its radius around the pose', () => {
    const box = bodyAabb(body({ type: 'ball', radius: q(0.25) }, pose(1, 1)), BOUNDS);
    expect(box).toEqual({ minX: BigInt(q(0.75)), minY: BigInt(q(0.75)), maxX: BigInt(q(1.25)), maxY: BigInt(q(1.25)) });
  });

  it('a polygon is the box of its turned vertices', () => {
    const vertices = [
      { x: q(-1), y: q(0) },
      { x: q(1), y: q(0) },
      { x: q(0), y: q(0.5) },
    ];
    const box = bodyAabb(body({ type: 'polygon', vertices }, pose(5, 5)), BOUNDS);
    expect(box).toEqual({ minX: BigInt(q(4)), minY: BigInt(q(4.5)), maxX: BigInt(q(6)), maxY: BigInt(q(5.5)) });
  });

  it('the ground half-space is everything below it, clipped to the level bounds', () => {
    const ground = body({ type: 'halfspace', normal: { x: q(0), y: q(1) } });
    expect(bodyAabb(ground, BOUNDS)).toEqual({ ...BOUNDS, maxY: 0n });
  });

  it('edges are inside', () => {
    const box: Aabb = { minX: 0n, minY: 0n, maxX: 4n, maxY: 4n };
    expect(containsPoint(box, 4n, 0n)).toBe(true);
    expect(containsPoint(box, 5n, 0n)).toBe(false);
  });

  it('obstaclesFromLevel gives one box per body', () => {
    const level = {
      bounds: { min_x: '-4294967296', min_y: '-4294967296', max_x: '4294967296', max_y: '4294967296' },
      bodies: [body({ type: 'ball', radius: q(1) }), body({ type: 'ball', radius: q(2) })],
    } as TraceLevel;
    expect(obstaclesFromLevel(level)).toHaveLength(2);
  });
});
