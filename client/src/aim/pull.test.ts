import { describe, expect, it } from 'vitest';
import { clampPull, pullFromDrag, pullToDrag } from './pull';

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
