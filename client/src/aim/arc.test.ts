import { describe, expect, it } from 'vitest';
import { ONE_RAW, isqrtCeil, mulFloor } from './fixed';
import { MAX_ARC_TICKS, TICK_DT_RAW, flightArc, launchVelocity, type ArcParams } from './arc';

const FAR = 100n * ONE_RAW;

// gravity_y = -9.81, launch_scale = 0.02, anchor (-6, 2.5): raw values rounded to nearest.
const params: ArcParams = {
  anchor: { x: -25769803776n, y: 10737418240n },
  gravityY: -42133629174n,
  launchScale: 85899346n,
  minX: -FAR,
  minY: -FAR,
  maxX: FAR,
  maxY: FAR,
};
const pull = { x: -775, y: -270 };

// The first 20 positions, computed by hand (Python integers, floor division by 2^32) from
//   v = -pull * launch_scale;  every tick:  v_y += g*dt;  p += v*dt   (each product floored)
// with dt = 71582788 and g*dt = -702227151.
const GOLDEN: [bigint, bigint][] = [
  [-24660270561n, 11112261509n],
  [-23550737346n, 11475400992n],
  [-22441204131n, 11826836690n],
  [-21331670916n, 12166568602n],
  [-20222137701n, 12494596728n],
  [-19112604486n, 12810921068n],
  [-18003071271n, 13115541622n],
  [-16893538056n, 13408458391n],
  [-15784004841n, 13689671374n],
  [-14674471626n, 13959180571n],
  [-13564938411n, 14216985982n],
  [-12455405196n, 14463087607n],
  [-11345871981n, 14697485447n],
  [-10236338766n, 14920179501n],
  [-9126805551n, 15131169769n],
  [-8017272336n, 15330456251n],
  [-6907739121n, 15518038947n],
  [-5798205906n, 15693917858n],
  [-4688672691n, 15858092983n],
  [-3579139476n, 16010564322n],
];

describe('flightArc', () => {
  it('matches the hand-computed first 20 positions exactly', () => {
    const arc = flightArc(params, pull);
    expect(arc.slice(0, 20).map((p) => [p.x, p.y])).toEqual(GOLDEN);
  });

  it('launches with v = -pull * launch_scale, exact', () => {
    expect(launchVelocity(pull, params.launchScale)).toEqual({ x: 66571993150n, y: 23192823420n });
  });

  it('is 120 dots long when it stays inside the bounds', () => {
    expect(MAX_ARC_TICKS).toBe(120);
    expect(flightArc(params, pull)).toHaveLength(120);
    expect(flightArc(params, pull, 7)).toHaveLength(7);
  });

  it('stops before the first position outside the bounds (a point on the edge is inside)', () => {
    expect(flightArc({ ...params, maxX: -20222137701n }, pull)).toHaveLength(5);
    expect(flightArc({ ...params, maxX: -20222137702n }, pull)).toHaveLength(4);
    expect(flightArc({ ...params, minY: 0n, maxY: 11800000000n }, pull)).toHaveLength(2);
  });

  it('follows the closed form of semi-implicit Euler to within rounding', () => {
    // After n ticks: x = x0 + vx n dt,  y = y0 + vy n dt + g dt² n (n + 1) / 2.
    const n = 120;
    const dt = 1 / 60;
    const last = flightArc(params, pull)[n - 1];
    const x = -6 + 15.5 * n * dt;
    const y = 2.5 + 5.4 * n * dt - 9.81 * dt * dt * ((n * (n + 1)) / 2);
    expect(Number(last.x) / 2 ** 32).toBeCloseTo(x, 5);
    expect(Number(last.y) / 2 ** 32).toBeCloseTo(y, 5);
  });
});

describe('Q32.32 helpers', () => {
  it('mulFloor floors negative products (truncation would give 0)', () => {
    expect(mulFloor(-1n, 1n)).toBe(-1n);
    expect(mulFloor(ONE_RAW, -ONE_RAW)).toBe(-ONE_RAW);
    expect(mulFloor(-42133629174n, TICK_DT_RAW)).toBe(-702227151n);
  });

  it('isqrtCeil is the smallest root s with s² >= n', () => {
    expect([0n, 1n, 2n, 4n, 5n, 1048576n, 1048577n].map(isqrtCeil)).toEqual([0n, 1n, 2n, 2n, 3n, 1024n, 1025n]);
    expect(() => isqrtCeil(-1n)).toThrow(RangeError);
  });
});
