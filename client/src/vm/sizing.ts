// Step-budgeted chunk sizing (docs/DESIGN.md D1, D8; docs/research/04 "Next steps" 2): the next
// chunk's tick count comes from the previous chunk's steps per tick, aiming at a fixed number of
// Cairo steps per chunk, and its execution segment is pre-reserved from the previous chunk's
// cells. Steps per tick vary ~3x between flight and impact, so a fixed K would size memory and
// tick gaps by the impact.

/** Tuning of the chunk sizing rule. */
export interface ChunkSizing {
  /** Cairo steps aimed at per chunk (2-5M: ~265-375 MB of wasm, < 3 % per-chunk overhead). */
  targetSteps: number;
  minTicks: number;
  /**
   * Upper bound on K (bounds the latency of a chunk when ticks are cheap). D8 says 60; lot G6b
   * measured 20 on pile10: a 54-tick chunk sized on the flight (65k steps per tick) runs into
   * the impact (200k+) and needs 6.7M cells, 1.5x any reserve the rule can give it.
   */
  maxTicks: number;
  /** K of the first stepping chunk, when no tick has been measured yet. */
  firstTicks: number;
  /** Execution-segment cells per tick assumed before any measurement (spike G1b: 700k). */
  priorCellsPerTick: number;
  /**
   * Reserve = factor x the previous chunk's cells, scaled to the new K. D8 says 1.1; measured on
   * pile12 (client/vm/README.md), 1.1 is overrun when the steps per tick rise > 10 % from one
   * chunk to the next (after the impact): the segment then doubles, 556 MB of wasm instead of
   * 330 MB with 1.25.
   */
  reserveFactor: number;
  /**
   * Floor of the reserve, cells (lot G6b). The worker's wasm memory already plateaus at the first
   * chunk's reserve (5 x 700k x 1.25 = 4.4M cells), so reserving at least ~that much costs no
   * memory and absorbs a chunk whose steps per tick jump at the impact.
   */
  minReserveCells?: number;
}

export const DEFAULT_SIZING: ChunkSizing = {
  targetSteps: 3_500_000,
  minTicks: 1,
  maxTicks: 20,
  firstTicks: 5,
  priorCellsPerTick: 700_000,
  reserveFactor: 1.25,
  minReserveCells: 5_000_000,
};

/** What a finished chunk measured (execution segment cells, not all segments). */
export interface ChunkMeasure {
  ticks: number;
  steps: number;
  execCells: number;
}

export interface ChunkPlan {
  ticks: number;
  reserveCells: number;
}

/**
 * Plans the next chunk from the previous stepping chunk (`null` before the first one, or when
 * the previous chunk stepped no tick). `remaining` > 0 caps K; `fixedTicks` forces K (tests,
 * benchmarks) while the reserve still follows the rule.
 */
export function planChunk(
  prev: ChunkMeasure | null,
  remaining: number,
  sizing: ChunkSizing = DEFAULT_SIZING,
  fixedTicks?: number,
): ChunkPlan {
  if (!(remaining > 0)) throw new Error(`planChunk: nothing left to step (${remaining})`);
  const measured = prev !== null && prev.ticks > 0;
  let ticks: number;
  if (fixedTicks !== undefined) {
    ticks = fixedTicks;
  } else if (measured) {
    const stepsPerTick = Math.max(prev.steps / prev.ticks, 1);
    ticks = Math.floor(sizing.targetSteps / stepsPerTick);
    ticks = Math.min(Math.max(ticks, sizing.minTicks), sizing.maxTicks);
  } else {
    ticks = sizing.firstTicks;
  }
  ticks = Math.max(1, Math.min(ticks, remaining));
  const cellsPerTick = measured ? prev.execCells / prev.ticks : sizing.priorCellsPerTick;
  const reserveCells = Math.max(Math.ceil(sizing.reserveFactor * cellsPerTick * ticks), sizing.minReserveCells ?? 0);
  return { ticks, reserveCells };
}
