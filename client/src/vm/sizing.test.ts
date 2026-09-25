import { describe, expect, it } from 'vitest';
import { DEFAULT_SIZING, planChunk } from './sizing';

const F = DEFAULT_SIZING.reserveFactor;
/** The rule without the reserve floor (lot G1c's). */
const NO_FLOOR = { ...DEFAULT_SIZING, minReserveCells: 0 };

describe('planChunk (step-budgeted chunks)', () => {
  it('starts with firstTicks and the prior cells per tick', () => {
    expect(planChunk(null, 120, NO_FLOOR)).toEqual({ ticks: 5, reserveCells: Math.ceil(F * 700_000 * 5) });
    // The init chunk (0 ticks) is no measurement either.
    expect(planChunk({ ticks: 0, steps: 400_000, execCells: 300_000 }, 120).ticks).toBe(5);
  });

  it.each([
    // [steps per tick of the previous chunk, expected K]: K = floor(3.5M / steps per tick).
    [540_000, 6], // impact
    [333_000, 10], // pile12 average
    [200_000, 17], // flight
    [250_000, 14],
    [100_000, 20], // capped by maxTicks (lot G6b: 20, D8: 60)
    [10_000, 20],
    [5_000_000, 1], // one tick above the target: at least minTicks
  ])('at %i steps per tick, K = %i', (stepsPerTick, k) => {
    const prev = { ticks: 10, steps: stepsPerTick * 10, execCells: stepsPerTick * 11 };
    expect(planChunk(prev, 360).ticks).toBe(k);
  });

  it('reserves reserveFactor x the previous chunk cells, scaled to the new K', () => {
    const prev = { ticks: 10, steps: 3_500_000, execCells: 3_600_000 };
    // Same K: exactly reserveFactor x the previous chunk's cells.
    expect(planChunk(prev, 360, NO_FLOOR)).toEqual({ ticks: 10, reserveCells: Math.ceil(F * 3_600_000) });
    // Half the steps per tick: twice the ticks, twice the reserve.
    const cheap = { ticks: 10, steps: 1_750_000, execCells: 1_800_000 };
    expect(planChunk(cheap, 360, NO_FLOOR)).toEqual({ ticks: 20, reserveCells: Math.ceil(F * 180_000 * 20) });
    // Above the floor, the rule alone.
    const heavy = { ticks: 10, steps: 3_500_000, execCells: 4_400_000 };
    expect(planChunk(heavy, 360).reserveCells).toBe(Math.ceil(F * 4_400_000));
  });

  it('never reserves below minReserveCells (a flight chunk followed by the impact)', () => {
    // pile10 (lot G6b): 20 flight ticks of 68k steps, the next 20 ticks cost 4.2M steps, 4.5M cells.
    const flight = { ticks: 20, steps: 1_360_000, execCells: 1_380_000 };
    expect(planChunk(flight, 300)).toEqual({ ticks: 20, reserveCells: 5_000_000 });
    expect(planChunk(null, 120).reserveCells).toBe(5_000_000);
  });

  it('never plans past the end of the shot', () => {
    const prev = { ticks: 10, steps: 1_000_000, execCells: 1_100_000 };
    expect(planChunk(prev, 7).ticks).toBe(7);
    expect(planChunk(null, 2).ticks).toBe(2);
    expect(planChunk(prev, 3, DEFAULT_SIZING, 30).ticks).toBe(3);
    expect(() => planChunk(prev, 0)).toThrow('nothing left');
  });

  it('fixedTicks forces K, the reserve still follows the rule', () => {
    const prev = { ticks: 5, steps: 2_700_000, execCells: 2_800_000 };
    expect(planChunk(prev, 100, NO_FLOOR, 30)).toEqual({
      ticks: 30,
      reserveCells: Math.ceil(F * (2_800_000 / 5) * 30),
    });
  });

  it('follows a custom target', () => {
    const prev = { ticks: 10, steps: 3_000_000, execCells: 3_100_000 };
    expect(planChunk(prev, 360, { ...DEFAULT_SIZING, targetSteps: 2_000_000 }).ticks).toBe(6);
    expect(planChunk(prev, 360, { ...DEFAULT_SIZING, targetSteps: 5_000_000 }).ticks).toBe(16);
  });
});
