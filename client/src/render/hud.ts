import type { TraceEvent } from '../trace/types';

export interface HudState {
  score: number;
  shotsLeft: number;
}

/**
 * Score and shots left at `tick`, from the events up to and including it: the total of the last
 * `score` event, and the level's shots minus the shots spent. A shot is spent from its release
 * (`releases`: the tick each shot was released at, which the playback shows while the worker
 * starts the shot) or, for a recorded trace without releases, from its `shot_end` event.
 */
export function hudAt(events: readonly TraceEvent[], shots: number, tick: number, releases: readonly number[] = []): HudState {
  let score = 0;
  let ended = 0;
  for (const event of events) {
    if (event.tick > tick) break;
    if (event.kind === 'score') score = event.total;
    else if (event.kind === 'shot_end') ended++;
  }
  let released = 0;
  for (const at of releases) if (at <= tick) released++;
  return { score, shotsLeft: Math.max(0, shots - Math.max(ended, released)) };
}

/** `(-1022, -63)`, or an en dash when there is no pull. */
export function pullText(pull: { x: number; y: number } | undefined): string {
  return pull === undefined ? '–' : `(${pull.x}, ${pull.y})`;
}

/** Text HUD in the DOM (score, shots left, tick); a field is written only when it changes. */
export class Hud {
  private readonly score: HTMLElement;
  private readonly shots: HTMLElement;
  private readonly tick: HTMLElement;
  private readonly pull: HTMLElement | null;

  constructor(root: HTMLElement) {
    this.score = root.querySelector<HTMLElement>('[data-hud="score"]')!;
    this.shots = root.querySelector<HTMLElement>('[data-hud="shots"]')!;
    this.tick = root.querySelector<HTMLElement>('[data-hud="tick"]')!;
    this.pull = root.querySelector<HTMLElement>('[data-hud="pull"]');
  }

  /** The integer pull being aimed: exactly the pair a release sends. */
  setPull(pull: { x: number; y: number } | undefined): void {
    if (this.pull !== null) write(this.pull, pullText(pull));
  }

  set(state: HudState, tick: number, tickCount: number): void {
    write(this.score, String(state.score));
    write(this.shots, String(state.shotsLeft));
    write(this.tick, `${tick} / ${tickCount}`);
  }
}

function write(element: HTMLElement, text: string): void {
  if (element.textContent !== text) element.textContent = text;
}
