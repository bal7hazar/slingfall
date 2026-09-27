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
  /**
   * Ceiling of the reserve, cells (lot Q2): K is lowered (to 1 at least) until the rule's reserve
   * fits. Wasm memory never shrinks and a larger reserve cannot reuse the freed block: pile10's
   * owner shot asked 5.20M cells once, for 4.02M used, and the worker grew from 352 to 510 MB.
   * Equal to the floor, every chunk reserves the same segment and the worker stays at its first
   * chunk's plateau.
   */
  maxReserveCells?: number;
  /**
   * Contact cut (lot Q2, QA M4): with a predicted contact tick (`ShotOptions.predictContact`), the
   * flight chunk ends `contactLead` ticks before it, so that the impact opens a fresh chunk
   * instead of running into a 20-tick chunk sized on flight ticks (4.5-7.9M cells against the 5M
   * floor: the segment doubled, 611-681 MB of wasm).
   */
  contactLead?: number;
  /**
   * K of the chunks after the cut until one has met the impact, during `impactWatch` ticks at
   * most (`ContactCut`). Their reserve is the floor, sized on the flight: it must hold
   * `impactTicks` ticks of impact (pile10: ~480k cells on the contact tick, 300-450k after it).
   */
  impactTicks?: number;
  impactWatch?: number;
}

export const DEFAULT_SIZING: ChunkSizing = {
  targetSteps: 3_500_000,
  minTicks: 1,
  maxTicks: 20,
  firstTicks: 5,
  priorCellsPerTick: 700_000,
  reserveFactor: 1.25,
  minReserveCells: 5_000_000,
  maxReserveCells: 5_000_000,
  contactLead: 1,
  impactTicks: 8,
  impactWatch: 16,
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
  if (fixedTicks === undefined && sizing.maxReserveCells !== undefined) {
    const fits = Math.floor(sizing.maxReserveCells / (sizing.reserveFactor * cellsPerTick));
    ticks = Math.max(1, Math.min(ticks, fits));
  }
  const reserveCells = Math.max(Math.ceil(sizing.reserveFactor * cellsPerTick * ticks), sizing.minReserveCells ?? 0);
  return { ticks, reserveCells };
}

/** A chunk after the cut whose steps per tick reach this multiple of the flight's has met the impact. */
const IMPACT_RATIO = 2;

/**
 * The contact cut of one shot's chunk loop (lot Q2), from the predicted contact tick counted from
 * the loop's start state (1-based; `null`: none, no cap). The flight runs until `contactLead` ticks
 * before the contact tick; from there, chunks run `impactTicks` at most until one of them has met
 * the impact (steps per tick >= 2x the last flight chunk's) or `impactWatch` ticks have passed
 * (a prediction too early: the bodies moved). After that, the rule alone, whose K the ceiling
 * (`maxReserveCells`) sizes on the impact's measured cells.
 */
export class ContactCut {
  private readonly cut: number | null;
  private readonly sizing: ChunkSizing;
  private flightStepsPerTick = Infinity;
  private impact = false;

  constructor(contact: number | null, sizing: ChunkSizing = DEFAULT_SIZING) {
    this.sizing = sizing;
    this.cut = contact === null || sizing.impactTicks === undefined ? null : Math.max(contact - 1 - (sizing.contactLead ?? 0), 0);
  }

  /**
   * The most ticks the chunk starting `stepped` ticks after the start may run (`Infinity`: no
   * cap). The caller passes `min(remaining, cap)` as `planChunk`'s `remaining`, so that the reserve
   * follows the capped K.
   */
  cap(stepped: number): number {
    const { cut, sizing } = this;
    if (cut === null) return Infinity;
    if (stepped < cut) return cut - stepped;
    if (!this.impact && stepped < cut + (sizing.impactWatch ?? 0)) return sizing.impactTicks ?? Infinity;
    return Infinity;
  }

  /** Records the chunk that started `stepped` ticks after the start. */
  record(stepped: number, chunk: ChunkMeasure) {
    if (this.cut === null || chunk.ticks === 0) return;
    const stepsPerTick = chunk.steps / chunk.ticks;
    if (stepped < this.cut) this.flightStepsPerTick = stepsPerTick;
    else if (stepsPerTick >= IMPACT_RATIO * this.flightStepsPerTick) this.impact = true;
  }
}
