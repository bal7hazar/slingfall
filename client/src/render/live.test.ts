import { describe, expect, it } from 'vitest';
import { TraceBuffer } from './buffer';
import { Effects, FADE_MS, FLASH_MS } from './effects';
import { ArrivalRate, LEAD_FRAMES, liveSpeed } from './live';
import { buildPile10 } from '../trace/synth';
import type { TraceEvent } from '../trace/types';

describe('ArrivalRate', () => {
  it('counts the frames of the last second', () => {
    const rate = new ArrivalRate();
    expect(rate.fps(0)).toBe(0);
    for (let t = 0; t <= 500; t += 50) rate.push(t); // 11 frames in 500 ms
    expect(rate.fps(500)).toBeCloseTo(22);
    // Two seconds later nothing is in the window.
    expect(rate.fps(2600)).toBe(0);
    rate.reset();
    expect(rate.fps(500)).toBe(0);
  });

  it('keeps a bounded ring when frames arrive much faster than real time', () => {
    const rate = new ArrivalRate();
    for (let i = 0; i < 1000; i++) rate.push(i * 0.5);
    expect(rate.fps(500)).toBeGreaterThan(1000);
  });
});

describe('liveSpeed', () => {
  it('plays at real time with a full lead or once the worker is done', () => {
    expect(liveSpeed(LEAD_FRAMES, true, 5)).toBe(1);
    expect(liveSpeed(0, false, 0)).toBe(1);
  });

  it('slows to the arrival rate when the frames lag real time (slow-motion impact)', () => {
    // 20 frames per second arriving, half the lead: a third of real time times 0.75.
    expect(liveSpeed(LEAD_FRAMES / 2, true, 20)).toBeCloseTo((20 / 60) * 0.75);
    // No lead: half the arrival rate, so the lead rebuilds.
    expect(liveSpeed(0, true, 30)).toBeCloseTo(0.25);
    // Faster than real time: never above 1.
    expect(liveSpeed(1, true, 600)).toBe(1);
    expect(liveSpeed(0, true, 0)).toBe(0);
  });
});

describe('Effects', () => {
  const trace = buildPile10();
  const destroyedAt = trace.events.find((e) => e.kind === 'destroyed') as Extract<TraceEvent, { kind: 'destroyed' }>;
  const setup = (events: TraceEvent[]) => {
    const buffer = new TraceBuffer(trace.level);
    for (const frame of trace.frames) buffer.push(frame);
    return { buffer, effects: new Effects(buffer, events) };
  };

  it('flashes a damaged body for FLASH_MS', () => {
    const { buffer, effects } = setup([{ tick: 5, kind: 'damage', handle: 3, hp: 40 }]);
    const slot = buffer.slotOfHandle.get(3)!;
    effects.advance(4, 4, 1000);
    expect(effects.flashing(slot, 1000)).toBe(false);
    effects.advance(5, 5, 1000);
    expect(effects.flashing(slot, 1000 + FLASH_MS - 1)).toBe(true);
    expect(effects.flashing(slot, 1000 + FLASH_MS)).toBe(false);
  });

  it('fades a destroyed body out at its last pose', () => {
    const { buffer, effects } = setup(trace.events);
    const slot = buffer.slotOfHandle.get(destroyedAt.handle)!;
    const frame = destroyedAt.tick; // pile10's synthetic frames are one per tick from 0
    effects.advance(destroyedAt.tick, frame, 2000);
    expect(effects.fade(slot, 2000)).toBe(1);
    expect(effects.fade(slot, 2000 + FADE_MS / 2)).toBeCloseTo(0.5);
    expect(effects.fade(slot, 2000 + FADE_MS)).toBe(0);
    const pose = effects.fadePose(slot);
    expect(pose).toBeLessThanOrEqual(frame);
    expect(buffer.columns[slot].state[pose]).not.toBe(0);
  });

  it('clears the effects on a seek backwards, and starts none for the events already passed', () => {
    const { buffer, effects } = setup([
      { tick: 5, kind: 'damage', handle: 3, hp: 40 },
      { tick: 9, kind: 'damage', handle: 4, hp: 40 },
    ]);
    effects.advance(9, 9, 0);
    effects.advance(6, 6, 10);
    expect(effects.flashing(buffer.slotOfHandle.get(3)!, 10)).toBe(false);
    expect(effects.flashing(buffer.slotOfHandle.get(4)!, 10)).toBe(false);
    effects.advance(9, 9, 20);
    expect(effects.flashing(buffer.slotOfHandle.get(4)!, 20)).toBe(true);
  });

  it('ignores handles the buffer has not seen and the other events', () => {
    const { effects } = setup([
      { tick: 1, kind: 'damage', handle: 99, hp: 1 },
      { tick: 1, kind: 'score', points: 50, total: 50 },
    ]);
    expect(() => effects.advance(1, 1, 0)).not.toThrow();
    expect(effects.fade(99, 0)).toBe(0);
  });
});
