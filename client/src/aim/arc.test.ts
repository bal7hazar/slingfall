import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { ONE_RAW, isqrtCeil, mulFloor } from './fixed';
import {
  MAX_ARC_TICKS,
  SUBSTEPS,
  SUBSTEP_DT_RAW,
  TICK_DT_RAW,
  arcParamsFromLevel,
  flightArc,
  launchVelocity,
  type ArcParams,
} from './arc';
import { containsPoint } from './contact';
import type { TraceLevel } from '../trace/types';

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

// The first 20 positions: `tools/golden/matrix.py::arc_points(level, pull, TICK_DT_RAW, 20, 4)`,
// copied here as values (Python integers, floor division by 2^32):
//   v = -pull * launch_scale;  h = dt // 4 = 17895697;  g*h = -175556788
//   every tick, 4 times:  v_y += g*h;  x += v_x*h;  y += v_y*h      (each product floored)
const GOLDEN: [bigint, bigint][] = [
  [-24660270564n, 11116650428n],
  [-23550737352n, 11484178829n],
  [-22441204140n, 11840003445n],
  [-21331670928n, 12184124275n],
  [-20222137716n, 12516541319n],
  [-19112604504n, 12837254577n],
  [-18003071292n, 13146264049n],
  [-16893538080n, 13443569736n],
  [-15784004868n, 13729171637n],
  [-14674471656n, 14003069752n],
  [-13564938444n, 14265264081n],
  [-12455405232n, 14515754625n],
  [-11345872020n, 14754541382n],
  [-10236338808n, 14981624354n],
  [-9126805596n, 15197003540n],
  [-8017272384n, 15400678940n],
  [-6907739172n, 15592650554n],
  [-5798205960n, 15772918382n],
  [-4688672748n, 15941482425n],
  [-3579139536n, 16098342682n],
];

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));

describe('flightArc', () => {
  it('matches the first 20 positions of `matrix.py::arc_points` (4 substeps) exactly', () => {
    const arc = flightArc(params, pull);
    expect(arc.slice(0, 20).map((p) => [p.x, p.y])).toEqual(GOLDEN);
  });

  it('is the substepped free flight: 4 Euler steps of dt // 4 per tick', () => {
    expect(SUBSTEPS).toBe(4);
    expect(SUBSTEP_DT_RAW).toBe(17895697n);
    expect(SUBSTEP_DT_RAW).toBe(TICK_DT_RAW / 4n);
    expect(mulFloor(params.gravityY, SUBSTEP_DT_RAW)).toBe(-175556788n);
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
    expect(flightArc({ ...params, maxX: -20222137716n }, pull)).toHaveLength(5);
    expect(flightArc({ ...params, maxX: -20222137717n }, pull)).toHaveLength(4);
    expect(flightArc({ ...params, minY: 0n, maxY: 11800000000n }, pull)).toHaveLength(2);
  });

  it('follows the closed form of substepped semi-implicit Euler to within rounding', () => {
    // After n ticks, m = 4n steps of h = dt / 4: x = x0 + vx m h,  y = y0 + vy m h + g h² m (m + 1) / 2.
    const n = 120;
    const m = SUBSTEPS * n;
    const h = 1 / 60 / SUBSTEPS;
    const last = flightArc(params, pull)[n - 1];
    const x = -6 + 15.5 * m * h;
    const y = 2.5 + 5.4 * m * h - 9.81 * h * h * ((m * (m + 1)) / 2);
    expect(Number(last.x) / 2 ** 32).toBeCloseTo(x, 5);
    expect(Number(last.y) / 2 ** 32).toBeCloseTo(y, 5);
  });

  it('stops after the first dot inside an obstacle box (display cut)', () => {
    const box = { minX: -20500000000n, minY: 0n, maxX: -19000000000n, maxY: 20000000000n };
    // Dots 5 (-20222137716) and 6 (-19112604504) are inside; the arc ends with dot 5.
    expect(flightArc({ ...params, obstacles: [box] }, pull)).toHaveLength(5);
    expect(flightArc({ ...params, obstacles: [] }, pull)).toHaveLength(120);
  });
});

describe('flightArc against the engine (pile10-reference)', () => {
  const trace = JSON.parse(readFileSync(root('fixtures/traces/pile10-reference.json'), 'utf8')) as {
    level: TraceLevel;
    frames: { tick: number; bodies: { handle: number; x: string; y: string }[] }[];
  };
  // The reference shot of pile10 (`client/src/vm/program.test.ts`); its pebble is the handle after the bodies.
  const REFERENCE_PULL = { x: -600, y: -392 };
  const pebble = trace.level.bodies.length;
  const flight = trace.frames
    .flatMap((frame) => frame.bodies.filter((b) => b.handle === pebble))
    .map((b) => [BigInt(b.x), BigInt(b.y)]);

  it('equals the pebble frames of the first 60 flight ticks, bit for bit (raw felts)', () => {
    expect(flight.length).toBeGreaterThanOrEqual(60);
    // No obstacles: the engine pebble flies on through where the preview would stop.
    const arc = flightArc({ ...arcParamsFromLevel(trace.level), obstacles: [] }, REFERENCE_PULL, 60);
    expect(arc).toHaveLength(60);
    expect(arc.map((p) => [p.x, p.y])).toEqual(flight.slice(0, 60));
  });

  it('stops at the first tick inside a body box', () => {
    const params = arcParamsFromLevel(trace.level);
    const boxes = params.obstacles!;
    const arc = flightArc(params, REFERENCE_PULL);
    const free = flightArc({ ...params, obstacles: [] }, REFERENCE_PULL);
    expect(arc.length).toBeLessThan(free.length);
    expect(arc).toEqual(free.slice(0, arc.length));
    const inside = (p: { x: bigint; y: bigint }) => boxes.some((b) => containsPoint(b, p.x, p.y));
    expect(inside(arc[arc.length - 1])).toBe(true);
    expect(arc.slice(0, -1).some(inside)).toBe(false);
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
