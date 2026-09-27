import { describe, expect, it } from 'vitest';
import { ContactCut, DEFAULT_SIZING, planChunk } from './sizing';

const F = DEFAULT_SIZING.reserveFactor;
/** The rule without the reserve floor and ceiling (lot G1c's). */
const NO_FLOOR = { ...DEFAULT_SIZING, minReserveCells: 0, maxReserveCells: undefined };
/** The rule with the floor, without the ceiling (lot G6b's). */
const NO_CEILING = { ...DEFAULT_SIZING, maxReserveCells: undefined };

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
    expect(planChunk(heavy, 360, NO_CEILING).reserveCells).toBe(Math.ceil(F * 4_400_000));
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
    expect(planChunk(prev, 360, { ...NO_CEILING, targetSteps: 5_000_000 }).ticks).toBe(16);
  });

  it('lowers K until the reserve fits maxReserveCells (lot Q2: the worker never grows past the floor)', () => {
    // 440k cells per tick: K = 10 would reserve 5.5M; 9 ticks fit 1.25 x 440k x 9 = 4.95M, floored to 5M.
    const heavy = { ticks: 10, steps: 3_500_000, execCells: 4_400_000 };
    expect(planChunk(heavy, 360)).toEqual({ ticks: 9, reserveCells: 5_000_000 });
    // pile10's owner shot (alpha.5): 15 ticks of 4.16M cells asked 5.20M, 14 fit.
    const owner = { ticks: 8, steps: 1_860_000, execCells: 2_220_000 };
    expect(planChunk(owner, 360, NO_CEILING)).toEqual({ ticks: 15, reserveCells: 5_203_125 });
    expect(planChunk(owner, 360)).toEqual({ ticks: 14, reserveCells: 5_000_000 });
    // At least one tick, whatever a tick costs; fixedTicks is not lowered.
    const huge = { ticks: 1, steps: 5_000_000, execCells: 6_000_000 };
    expect(planChunk(huge, 360).ticks).toBe(1);
    expect(planChunk(heavy, 360, DEFAULT_SIZING, 12).ticks).toBe(12);
  });
});

describe('ContactCut (lot Q2: the impact opens a fresh chunk)', () => {
  const { contactLead, impactTicks, impactWatch } = DEFAULT_SIZING;
  const flight = { ticks: 20, steps: 640_000, execCells: 700_000 };
  const impact = { ticks: 8, steps: 1_860_000, execCells: 2_220_000 };

  it('is the default sizing: lead 1 tick, K = 8 after the cut, a watch of 16 ticks', () => {
    expect([contactLead, impactTicks, impactWatch]).toEqual([1, 8, 16]);
  });

  it.each([
    // [ticks stepped, cap] with the contact predicted at tick 43 (pile10, the owner's shot): the
    // flight runs ticks 1-41, the impact chunks start at tick 42 until one meets the impact.
    [0, 41],
    [25, 16],
    [40, 1],
    [41, 8],
    [49, 8],
    [56, 8],
    [57, Infinity],
    [100, Infinity],
  ])('before any impact is measured, after %i ticks: at most %d', (stepped, cap) => {
    expect(new ContactCut(43).cap(stepped)).toBe(cap);
  });

  it('lifts the cap once a chunk after the cut costs 2x the flight per tick', () => {
    const cut = new ContactCut(43);
    cut.record(25, { ticks: 16, steps: 530_000, execCells: 560_000 }); // 33k steps per tick
    // Still flight after the cut (a prediction too early): the cap holds.
    cut.record(41, { ticks: 8, steps: 500_000, execCells: 520_000 });
    expect(cut.cap(49)).toBe(8);
    cut.record(49, impact); // 232k steps per tick
    expect(cut.cap(56)).toBe(Infinity);
  });

  it('caps nothing without a prediction, starts with the impact when the contact is at hand', () => {
    expect(new ContactCut(null).cap(0)).toBe(Infinity);
    expect(new ContactCut(2).cap(0)).toBe(8);
    expect(new ContactCut(1).cap(0)).toBe(8);
    expect(new ContactCut(43, { ...DEFAULT_SIZING, impactTicks: undefined }).cap(0)).toBe(Infinity);
  });

  it('with planChunk: the flight chunk ends at the cut, the impact chunk reserves the floor', () => {
    const cut = new ContactCut(43);
    expect(planChunk(flight, Math.min(300, cut.cap(25)))).toEqual({ ticks: 16, reserveCells: 5_000_000 });
    expect(planChunk(flight, Math.min(300, cut.cap(41)))).toEqual({ ticks: 8, reserveCells: 5_000_000 });
  });
});
