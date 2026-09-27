import { describe, expect, it } from 'vitest';
import { FULL_PULL_SHARE, clampPull, fullPullPixels, nudgePull, pullFromDrag, pullToDrag, type Pull } from './pull';

describe('clampPull', () => {
  // [px, py, radius, x, y]: computed by hand as s = ceil(sqrt(px² + py²)), then
  // (px * R / s, py * R / s) with the quotients truncated toward zero.
  it.each([
    [0, 0, 1024, 0, 0],
    [1024, 0, 1024, 1024, 0],
    [-1024, 0, 1024, -1024, 0],
    [600, 800, 1000, 600, 800], // exactly on the circle: kept
    [300, -400, 500, 300, -400],
    [300, -400, 499, 299, -399],
    [1000, 300, 1024, 979, 293],
    [-1000, -300, 1024, -979, -293], // symmetric: truncation toward zero, not floor
    [1024, 1024, 1024, 723, 723],
    [-1024, 1024, 1024, -723, 723],
    [1024, -1024, 512, 361, -361],
    [-7, 1, 3, -2, 0],
    [1, 1, 0, 0, 0],
  ])('(%d, %d) in a disk of radius %d -> (%d, %d)', (px, py, radius, x, y) => {
    expect(clampPull(px, py, radius)).toEqual({ x, y });
  });

  it('never leaves the disk', () => {
    for (let px = -1100; px <= 1100; px += 137) {
      for (let py = -1100; py <= 1100; py += 91) {
        const p = clampPull(px, py, 1024);
        expect(p.x * p.x + p.y * p.y).toBeLessThanOrEqual(1024 * 1024);
      }
    }
  });

  it('rejects non-integers and radii above 1024', () => {
    expect(() => clampPull(1.5, 0, 1024)).toThrow(RangeError);
    expect(() => clampPull(0, 0, 1025)).toThrow('pull radius 1025 outside [0, 1024]');
  });
});

describe('pullFromDrag', () => {
  it('maps 3 m of drag to the full radius, in integers', () => {
    expect(pullFromDrag(3, 0, 1024)).toEqual({ x: 1024, y: 0 });
    expect(pullFromDrag(-1.5, 0.75, 1024)).toEqual({ x: -512, y: 256 });
  });

  it('clamps a long drag to the disk, and ignores a non-finite pointer', () => {
    expect(pullFromDrag(100, 100, 1024)).toEqual({ x: 723, y: 723 });
    expect(pullFromDrag(Number.NaN, Infinity, 1024)).toEqual({ x: 0, y: 0 });
  });

  it('round-trips through pullToDrag', () => {
    expect(pullToDrag({ x: 512, y: -256 }, 1024)).toEqual({ dx: 1.5, dy: -0.75 });
  });
});

describe('screen-scaled drag', () => {
  it('maps fullPullPixels of drag onto the full radius', () => {
    const full = fullPullPixels(390, 800);
    expect(full).toBeCloseTo(390 * FULL_PULL_SHARE);
    expect(pullFromDrag(-full, 0, 1024, full)).toEqual({ x: -1024, y: 0 });
    expect(pullToDrag({ x: -1024, y: 0 }, 1024, full).dx).toBeCloseTo(-full);
  });
});

describe('nudgePull', () => {
  /** The key presses of a player: Shift steps of 10, then single steps, x first, then y. */
  const reach = (target: Pull, radius: number): Pull => {
    let p: Pull = { x: 0, y: 0 };
    for (const axis of ['x', 'y'] as const) {
      while (Math.abs(target[axis] - p[axis]) >= 10) p = nudgePull(p, axis, 10 * Math.sign(target[axis] - p[axis]), radius);
      while (p[axis] !== target[axis]) {
        const next = nudgePull(p, axis, Math.sign(target[axis] - p[axis]), radius);
        if (next[axis] === p[axis]) return p; // stuck: unreachable
        p = next;
      }
    }
    return p;
  };

  it('reaches every integer pull of the disk (a grid, its rim, and the owner\'s pile10 shot)', () => {
    const R = 1024;
    const targets: Pull[] = [{ x: -1022, y: -63 }, { x: -1024, y: 0 }, { x: 0, y: -1024 }, { x: 723, y: -724 }];
    for (let x = -R; x <= R; x += 31) {
      for (let y = -R; y <= R; y += 29) if (x * x + y * y <= R * R) targets.push({ x, y });
      // The rim: the largest |y| inside for this x.
      const rim = Math.floor(Math.sqrt(R * R - x * x));
      targets.push({ x, y: rim }, { x, y: rim === 0 ? 0 : -rim });
    }
    for (const target of targets) {
      expect(target.x ** 2 + target.y ** 2).toBeLessThanOrEqual(R * R);
      expect(reach(target, R)).toEqual(target);
    }
  });

  it('never leaves the disk and stops at its edge', () => {
    expect(nudgePull({ x: 1020, y: 0 }, 'x', 10, 1024)).toEqual({ x: 1024, y: 0 });
    expect(nudgePull({ x: 1024, y: 0 }, 'y', 1, 1024)).toEqual({ x: 1024, y: 0 });
    expect(nudgePull({ x: -1022, y: -60 }, 'y', -10, 1024)).toEqual({ x: -1022, y: -63 });
    expect(nudgePull({ x: 3, y: 4 }, 'x', -1, 5)).toEqual({ x: 2, y: 4 });
    expect(() => nudgePull({ x: 0, y: 0 }, 'x', 0.5, 1024)).toThrow(RangeError);
  });
});
