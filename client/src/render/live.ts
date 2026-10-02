// When the live playback head may start (lot CB): the worker computes the shot ahead and the head
// holds (`playback.speed = 0`) until the rest of the shot can no longer be produced slower than it
// plays, so that it then runs at real time to the end, with no slow motion. The rule counts in
// Cairo steps: a tick after the contact costs several times a flight tick.
import { TICKS_PER_SECOND } from './playback';

/**
 * A chunk whose steps per tick reach this multiple of the flight mean has met the contact.
 * Duplicated from `IMPACT_RATIO` of `vm/sizing.ts` (private there, and `vm/**` is out of this lot).
 */
export const IMPACT_RATIO = 2;

/**
 * Steps per tick after the contact, as a multiple of the flight mean, when no post-contact chunk
 * has been measured yet. Measured on both pile10 shots (REPORT.md, "post-contact factor"), with a
 * margin: see `PRIOR_FACTOR` in the report. The repository's figures point to a few times (3x in
 * `client/README.md`, 65k -> 200k+ steps per tick in `vm/sizing.ts`), not 15-20x.
 */
export const POST_CONTACT_PRIOR = 6;

/** Ticks of a shot beyond the table's figure, as a multiple (the margin of the per-level table). */
export const TICKS_MARGIN = 1.25;

/**
 * Ticks of the longest shot of a level, keyed on `level_id` (`session.level.felts[1]`). From the
 * golden `outputs.ticks_run` (index 8) of the single-shot cases and `docs/qa/2026-09-30-mac-play.md`:
 * the owner's shot on pile10 (id 2) ran 151 ticks (the reference 107); one_block (id 1) with a
 * 30-tick delay ran 150. The other levels' shots reach their tick cap in the goldens (180), and
 * the multi-shot goldens give level totals only, so they have no entry and default to the cap.
 * The bundled client cannot read `fixtures/golden/*`, hence the copy.
 */
export const LEVEL_SHOT_TICKS: Readonly<Record<number, number>> = {
  1: 150,
  2: 151,
};

/**
 * Ticks a shot is expected to run in all (the table's figure with `TICKS_MARGIN`, or the level's
 * `tick_cap` with no entry, so that the hold lasts longer, not shorter), never above the cap plus
 * the shot's delay.
 */
export function expectedShotTicks(levelId: number, tickCap: number, delay = 0): number {
  const cap = tickCap + delay;
  const known = LEVEL_SHOT_TICKS[levelId];
  return known === undefined ? cap : Math.min(Math.ceil(known * TICKS_MARGIN) + delay, cap);
}

/** What `shouldStart` decides on. */
export interface StartInput {
  /** Ticks produced so far (stepping chunks only). */
  produced: number;
  /** Ticks the head has shown so far (its position). */
  shown: number;
  /** Ticks the shot is expected to run in all (`expectedShotTicks`). */
  expectedTicks: number;
  /** Measured speed of the VM, Cairo steps per second; 0 before the first stepping chunk. */
  stepsPerSecond: number;
  /** Mean steps per tick of the flight chunks; 0 before the first stepping chunk. */
  flightStepsPerTick: number;
  /** Mean steps per tick since the contact, once a post-contact chunk is measured; `null` before. */
  postContactStepsPerTick: number | null;
  /** Prior multiple of the flight mean for the ticks not produced yet, used with no post-contact chunk. */
  priorFactor?: number;
}

/**
 * Whether the head may start: the time to produce the rest of the shot at the measured speed is no
 * longer than the time to play everything not yet shown at real time. Every tick not produced yet
 * is priced at the post-contact mean once measured, else at the flight mean times the prior (never
 * at the flight rate alone: the impact is still ahead). With no rate yet, it holds.
 */
export function shouldStart(input: StartInput): boolean {
  const { produced, shown, expectedTicks, stepsPerSecond, flightStepsPerTick, postContactStepsPerTick } = input;
  if (!(stepsPerSecond > 0) || !(flightStepsPerTick > 0)) return false;
  const price = postContactStepsPerTick ?? flightStepsPerTick * (input.priorFactor ?? POST_CONTACT_PRIOR);
  const remainingSteps = Math.max(expectedTicks - produced, 0) * price;
  const playSeconds = Math.max(Math.max(expectedTicks, produced) - shown, 0) / TICKS_PER_SECOND;
  return remainingSteps / stepsPerSecond <= playSeconds;
}

/** The slice of a `ChunkReport` the estimate reads. */
export interface ChunkFigures {
  ticks: number;
  steps: number;
  ms: number;
}

/**
 * The production figures of one shot, from its chunk reports: the VM's speed, the flight mean and
 * the post-contact mean. The contact is the first chunk whose steps per tick are at least
 * `IMPACT_RATIO` times the flight mean (a lower bound, not the trigger).
 */
export class ProductionModel {
  /** Ticks produced by stepping chunks. */
  produced = 0;
  /** Whether a chunk met the contact. */
  contact = false;
  private steps = 0;
  private ms = 0;
  private flightTicks = 0;
  private flightSteps = 0;
  private postTicks = 0;
  private postSteps = 0;

  /** Records a chunk; `init` and `outputs` (`ticks` 0) are excluded. Returns whether it met the contact. */
  push(chunk: ChunkFigures): boolean {
    if (!(chunk.ticks > 0)) return false;
    let met = false;
    if (!this.contact && this.flightTicks > 0 && chunk.steps / chunk.ticks >= IMPACT_RATIO * this.flightStepsPerTick) {
      this.contact = true;
      met = true;
    }
    this.produced += chunk.ticks;
    this.steps += chunk.steps;
    this.ms += chunk.ms;
    if (this.contact) {
      this.postTicks += chunk.ticks;
      this.postSteps += chunk.steps;
    } else {
      this.flightTicks += chunk.ticks;
      this.flightSteps += chunk.steps;
    }
    return met;
  }

  get flightStepsPerTick(): number {
    return this.flightTicks > 0 ? this.flightSteps / this.flightTicks : 0;
  }

  get postContactStepsPerTick(): number | null {
    return this.postTicks > 0 ? this.postSteps / this.postTicks : null;
  }

  /** Cairo steps per second over the stepping chunks so far; 0 before the first one. */
  get stepsPerSecond(): number {
    return this.ms > 0 ? (this.steps * 1000) / this.ms : 0;
  }
}
