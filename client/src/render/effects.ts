import { ABSENT, type TraceBuffer } from './buffer';
import type { TraceEvent } from '../trace/types';

/** A damaged body flashes this long, ms of display time. */
export const FLASH_MS = 180;
/** A destroyed body fades out this long at its last pose, ms. */
export const FADE_MS = 450;
/** How far back a fading body's last pose is looked for, frames. */
const FADE_LOOKBACK = 8;

/**
 * Damage flashes and destroyed fade-outs, from the events as the playback head passes their
 * tick. Per-slot typed arrays; they grow only when the buffer gains a slot (a new pebble), so a
 * steady frame allocates nothing. Seeking backwards clears the effects.
 */
export class Effects {
  private readonly buffer: TraceBuffer;
  private readonly events: readonly TraceEvent[];
  private flashAt = new Float64Array(0);
  private fadeAt = new Float64Array(0);
  private fadeFrame = new Int32Array(0);
  private cursor = 0;
  private tick = -1;

  constructor(buffer: TraceBuffer, events: readonly TraceEvent[]) {
    this.buffer = buffer;
    this.events = events;
  }

  /** Starts the effects of the events up to `tick`, displayed at frame index `frame`, at time `now`. */
  advance(tick: number, frame: number, now: number): void {
    this.fit();
    if (tick < this.tick) {
      this.cursor = 0;
      this.flashAt.fill(-Infinity);
      this.fadeAt.fill(-Infinity);
      // Events already passed start no effect after a seek back.
      while (this.cursor < this.events.length && this.events[this.cursor].tick <= tick) this.cursor++;
    }
    this.tick = tick;
    while (this.cursor < this.events.length && this.events[this.cursor].tick <= tick) {
      const event = this.events[this.cursor++];
      if (event.kind !== 'damage' && event.kind !== 'destroyed') continue;
      const slot = this.buffer.slotOfHandle.get(event.handle);
      if (slot === undefined) continue;
      if (event.kind === 'damage') {
        this.flashAt[slot] = now;
      } else {
        this.fadeAt[slot] = now;
        this.fadeFrame[slot] = this.lastPresent(slot, frame);
      }
    }
  }

  /** Whether the slot flashes at `now`. */
  flashing(slot: number, now: number): boolean {
    return slot < this.flashAt.length && now - this.flashAt[slot] < FLASH_MS;
  }

  /** Opacity of a destroyed body at `now` (0 once faded, or when not destroyed). */
  fade(slot: number, now: number): number {
    if (slot >= this.fadeAt.length) return 0;
    const t = (now - this.fadeAt[slot]) / FADE_MS;
    return t >= 0 && t < 1 ? 1 - t : 0;
  }

  /** The frame whose pose a fading slot is drawn at. */
  fadePose(slot: number): number {
    return this.fadeFrame[slot];
  }

  private lastPresent(slot: number, frame: number): number {
    const state = this.buffer.columns[slot].state;
    for (let i = frame, stop = Math.max(0, frame - FADE_LOOKBACK); i >= stop; i--) {
      if (state[i] !== ABSENT) return i;
    }
    return -1;
  }

  private fit(): void {
    const n = this.buffer.slotCount;
    if (this.flashAt.length >= n) return;
    const grow = <T extends Float64Array | Int32Array>(a: T, fill: number, make: (n: number) => T): T => {
      const next = make(n);
      next.fill(fill);
      next.set(a);
      return next;
    };
    this.flashAt = grow(this.flashAt, -Infinity, (k) => new Float64Array(k));
    this.fadeAt = grow(this.fadeAt, -Infinity, (k) => new Float64Array(k));
    this.fadeFrame = grow(this.fadeFrame, -1, (k) => new Int32Array(k));
  }
}
