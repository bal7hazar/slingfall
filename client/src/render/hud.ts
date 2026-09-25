import type { TraceEvent } from '../trace/types';

export interface HudState {
  score: number;
  shotsLeft: number;
}

/**
 * Score and shots left at `tick`, from the events up to and including it: the total of the last
 * `score` event, and the level's shots minus the `shot_end` events (a shot in flight is spent).
 */
export function hudAt(events: readonly TraceEvent[], shots: number, tick: number): HudState {
  let score = 0;
  let ended = 0;
  for (const event of events) {
    if (event.tick > tick) break;
    if (event.kind === 'score') score = event.total;
    else if (event.kind === 'shot_end') ended++;
  }
  return { score, shotsLeft: Math.max(0, shots - ended) };
}

/** Text HUD in the DOM (score, shots left, tick); a field is written only when it changes. */
export class Hud {
  private readonly score: HTMLElement;
  private readonly shots: HTMLElement;
  private readonly tick: HTMLElement;

  constructor(root: HTMLElement) {
    this.score = root.querySelector<HTMLElement>('[data-hud="score"]')!;
    this.shots = root.querySelector<HTMLElement>('[data-hud="shots"]')!;
    this.tick = root.querySelector<HTMLElement>('[data-hud="tick"]')!;
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
