import { describe, expect, it } from 'vitest';
import { TraceBuffer } from './buffer';
import { Effects, FADE_MS, FLASH_MS } from './effects';
import { TICKS_PER_SECOND } from './playback';
import { expectedShotTicks, ProductionModel, shouldStart, TICKS_MARGIN } from './live';
import { buildPile10 } from '../trace/synth';
import type { TraceEvent } from '../trace/types';

describe('shouldStart', () => {
  // 150 ticks to play: 2.5 s of real time. Flight ticks cost 65k steps.
  const base = { produced: 20, shown: 0, expectedTicks: 150, stepsPerSecond: 4e6, flightStepsPerTick: 65_000, postContactStepsPerTick: null };

  it('holds before the first stepping chunk: no rate', () => {
    expect(shouldStart({ ...base, stepsPerSecond: 0, flightStepsPerTick: 0, produced: 0 })).toBe(false);
  });

  it('prices the ticks to come at the post-contact prior, not the flight rate, until a contact is measured', () => {
    // At the flight rate the rest (130 x 65k = 8.5M steps at 4M/s: 2.1 s) would be done within 2.5 s...
    const flightPriced = ((base.expectedTicks - base.produced) * base.flightStepsPerTick) / base.stepsPerSecond;
    expect(flightPriced).toBeLessThan(base.expectedTicks / TICKS_PER_SECOND);
    // ...but the contact is still ahead: at 6x it takes 12.7 s, so the rule holds.
    expect(shouldStart(base)).toBe(false);
    // On a machine 8x faster even the prior fits.
    expect(shouldStart({ ...base, stepsPerSecond: 32e6 })).toBe(true);
  });

  it('a measured post-contact mean replaces the prior', () => {
    // The impact was cheap (2x the flight): 130 x 130k = 16.9M steps at 8M/s = 2.1 s <= 2.5 s.
    const input = { ...base, stepsPerSecond: 8e6 };
    expect(shouldStart(input)).toBe(false); // the prior (6x) says 6.3 s
    expect(shouldStart({ ...input, postContactStepsPerTick: 130_000 })).toBe(true);
    // A measured impact dearer than the prior holds even where the prior would start.
    expect(shouldStart({ ...input, stepsPerSecond: 32e6, postContactStepsPerTick: 1_000_000 })).toBe(false);
  });

  it('plays what is not shown yet: a head already ahead needs less lead, a shot longer than expected is not priced', () => {
    expect(shouldStart({ ...base, stepsPerSecond: 12e6, produced: 100, shown: 0 })).toBe(true);
    expect(shouldStart({ ...base, stepsPerSecond: 12e6, produced: 100, shown: 100 })).toBe(false);
    // Produced past the expected total: nothing left to produce.
    expect(shouldStart({ ...base, produced: 160 })).toBe(true);
  });
});

describe('expectedShotTicks', () => {
  it('uses the level table with the margin, capped; a level with no entry defaults to the cap', () => {
    expect(expectedShotTicks(2, 180)).toBe(180); // 151 x 1.25 = 189 -> cap
    expect(expectedShotTicks(1, 360)).toBe(Math.ceil(150 * TICKS_MARGIN));
    expect(expectedShotTicks(99, 180)).toBe(180);
    expect(expectedShotTicks(1, 360, 30)).toBe(Math.ceil(150 * TICKS_MARGIN) + 30);
    expect(expectedShotTicks(99, 180, 30)).toBe(210);
  });
});

describe('ProductionModel', () => {
  it('excludes init and outputs, detects the contact at 2x the flight mean and splits the means', () => {
    const m = new ProductionModel();
    expect(m.push({ ticks: 0, steps: 5e6, ms: 900 })).toBe(false); // init
    expect(m.stepsPerSecond).toBe(0);
    expect(m.flightStepsPerTick).toBe(0);
    m.push({ ticks: 5, steps: 325_000, ms: 100 });
    m.push({ ticks: 10, steps: 650_000, ms: 100 }); // flight: 65k per tick
    expect(m.contact).toBe(false);
    expect(m.push({ ticks: 4, steps: 4 * 97_500, ms: 100 })).toBe(false); // 1.5x: still flight (mean 71.8k)
    expect(m.push({ ticks: 4, steps: 4 * 150_000, ms: 100 })).toBe(true); // 2.1x of it
    expect(m.postContactStepsPerTick).toBe(150_000);
    expect(m.push({ ticks: 4, steps: 4 * 70_000, ms: 100 })).toBe(false);
    expect(m.flightStepsPerTick).toBeCloseTo((325_000 + 650_000 + 4 * 97_500) / 19);
    expect(m.postContactStepsPerTick).toBeCloseTo((4 * 150_000 + 4 * 70_000) / 8);
    expect(m.produced).toBe(27);
    expect(m.stepsPerSecond).toBeCloseTo((325_000 + 650_000 + 4 * 97_500 + 4 * 150_000 + 4 * 70_000) / 0.5);
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
