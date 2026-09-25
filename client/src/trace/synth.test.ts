import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { arcParamsFromLevel, flightArc } from '../aim/arc';
import { formatTrace, buildPile10 } from './synth';
import { parseTrace } from './source';

const FIXTURE = new URL('../../../fixtures/traces/pile10.json', import.meta.url);
const SERVED = new URL('../../public/traces/pile10.json', import.meta.url);

// Regeneration: delete `fixtures/traces/pile10.json` (or its copy under `client/public/traces/`)
// and run `npm test`; both files are rewritten. CI never regenerates: a missing file fails there.
if (!process.env.CI && !(existsSync(FIXTURE) && existsSync(SERVED))) {
  const text = formatTrace(buildPile10());
  writeFileSync(FIXTURE, text);
  writeFileSync(SERVED, text);
}

describe('pile10 fixture', () => {
  const trace = buildPile10();

  it('is the committed fixture, and the copy Vite serves is the same file', () => {
    const text = formatTrace(trace);
    expect(readFileSync(FIXTURE, 'utf8')).toBe(text);
    expect(readFileSync(SERVED, 'utf8')).toBe(text);
  });

  it('parses as trace format v1', () => {
    expect(parseTrace(JSON.parse(formatTrace(trace)))).toEqual(trace);
  });

  it('has at least 120 frames and a falling pebble', () => {
    expect(trace.frames.length).toBeGreaterThanOrEqual(120);
    const heights = trace.frames.map((f) => BigInt(f.bodies.find((b) => b.handle === 11)!.y));
    expect(heights.at(-1)).toBe(2n ** 30n); // resting on the ground: y = radius 0.25
    expect(heights.at(-1)).toBeLessThan(heights[0]);
  });

  it('flies along the exact aim arc until the contact', () => {
    const arc = flightArc(arcParamsFromLevel(trace.level), { x: -775, y: -270 });
    for (let tick = 1; tick <= 40; tick++) {
      const pebble = trace.frames[tick].bodies.find((b) => b.handle === 11)!;
      expect([BigInt(pebble.x), BigInt(pebble.y)]).toEqual([arc[tick - 1].x, arc[tick - 1].y]);
    }
  });

  it('wakes three sleeping blocks, which sleep again; the roof is destroyed', () => {
    const asleepOf = (handle: number) =>
      trace.frames.map((f) => f.bodies.find((b) => b.handle === handle)?.asleep);
    for (const handle of [4, 6]) {
      const states = asleepOf(handle);
      expect(states[0]).toBe(true);
      expect(states).toContain(false);
      expect(states.at(-1)).toBe(true);
    }
    const roof = asleepOf(7);
    expect(roof[0]).toBe(true);
    expect(roof).toContain(false);
    expect(roof.at(-1)).toBeUndefined();
    expect(trace.events.map((e) => e.kind)).toEqual([
      'damage',
      'damage',
      'damage',
      'destroyed',
      'score',
      'shot_end',
    ]);
  });
});
