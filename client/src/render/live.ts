import { TICKS_PER_SECOND } from './playback';

/** Frames kept ahead of the playback head before it plays at full speed. */
export const LEAD_FRAMES = 8;
/** Width of the arrival-rate window, ms. */
export const RATE_WINDOW_MS = 1000;
const RING = 128;

/** Frames per second arriving from the worker, over the last `RATE_WINDOW_MS` (fixed ring, no allocation). */
export class ArrivalRate {
  private readonly times = new Float64Array(RING);
  private count = 0;
  private head = 0;

  push(now: number): void {
    this.times[this.head] = now;
    this.head = (this.head + 1) % RING;
    this.count = Math.min(this.count + 1, RING);
  }

  reset(): void {
    this.count = 0;
    this.head = 0;
  }

  /** 0 until two frames arrived in the window. */
  fps(now: number): number {
    let n = 0;
    let oldest = now;
    for (let i = 1; i <= this.count; i++) {
      const t = this.times[(this.head - i + RING) % RING];
      if (now - t > RATE_WINDOW_MS) break;
      oldest = t;
      n++;
    }
    return n < 2 ? 0 : (n * 1000) / Math.max(now - oldest, 1);
  }
}

/**
 * Speed of the live playback head (1 = real time, 60 ticks per second). While the worker is
 * still producing and fewer than `LEAD_FRAMES` frames are ahead of the head, the head plays at
 * the arrival rate, scaled down further as the lead shrinks: the impact, whose ticks cost the
 * most Cairo steps, plays in slow motion instead of freezing. With no producer, or a full lead,
 * it plays at real time.
 */
export function liveSpeed(lead: number, producing: boolean, arrivalFps: number): number {
  if (!producing || lead >= LEAD_FRAMES) return 1;
  const speed = (arrivalFps / TICKS_PER_SECOND) * (0.5 + (0.5 * lead) / LEAD_FRAMES);
  return Math.min(1, Math.max(0, speed));
}
