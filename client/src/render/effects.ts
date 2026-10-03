import { ABSENT, type TraceBuffer } from './buffer';
import type { LevelBody, TraceEvent } from '../trace/types';

/** Starting hp per material (docs/DESIGN.md D12, as the levels set it): a body is worn under half of it. */
export const MATERIAL_HP: Readonly<Record<string, number>> = { timber: 100, slate: 300, frost: 40, core: 30 };

/** A damaged body flashes this long, ms of display time. */
export const FLASH_MS = 180;
/** A destroyed body fades out this long at its last pose, ms. */
export const FADE_MS = 450;
/** How far back a fading body's last pose is looked for, frames. */
const FADE_LOOKBACK = 8;

/**
 * Damage flashes and destroyed fade-outs, from the events as the playback head passes their
 * tick. A pebble is spent at its shot's `shot_end` (D5 removes it there, but the shot's last
 * frame still carries it): from that frame on it fades out like a destroyed body. Per-slot typed arrays; they grow only when the buffer gains a slot (a new pebble), so a
 * steady frame allocates nothing. Seeking backwards clears the effects.
 */
export class Effects {
  private readonly buffer: TraceBuffer;
  private readonly events: readonly TraceEvent[];
  /** Half the starting hp of each level body, by handle (a body of unknown material never wears). */
  private readonly halfHp = new Map<number, number>();
  private hp = new Float64Array(0);
  private flashAt = new Float64Array(0);
  private fadeAt = new Float64Array(0);
  private fadeFrame = new Int32Array(0);
  /** Frame from which a pebble slot is spent (-1: not spent). A property of the frames, never cleared. */
  private spentFrame = new Int32Array(0);
  private cursor = 0;
  private tick = -1;

  constructor(buffer: TraceBuffer, events: readonly TraceEvent[], bodies: readonly LevelBody[] = []) {
    this.buffer = buffer;
    this.events = events;
    for (const b of bodies) {
      const hp = MATERIAL_HP[b.material];
      if (hp !== undefined && b.kind !== 'static') this.halfHp.set(b.handle, hp / 2);
    }
  }

  /** Starts the effects of the events up to `tick`, displayed at frame index `frame`, at time `now`. */
  advance(tick: number, frame: number, now: number): void {
    this.fit();
    if (tick < this.tick) {
      this.cursor = 0;
      this.flashAt.fill(-Infinity);
      this.fadeAt.fill(-Infinity);
      this.hp.fill(Infinity);
      // Events already passed start no effect after a seek back (their hp still counts).
      while (this.cursor < this.events.length && this.events[this.cursor].tick <= tick) {
        const event = this.events[this.cursor++];
        if (event.kind === 'damage') this.setHp(event.handle, event.hp);
        if (event.kind === 'shot_end') this.spendPebbles(event.tick, -Infinity);
      }
    }
    this.tick = tick;
    while (this.cursor < this.events.length && this.events[this.cursor].tick <= tick) {
      const event = this.events[this.cursor++];
      if (event.kind === 'shot_end') this.spendPebbles(event.tick, now);
      if (event.kind !== 'damage' && event.kind !== 'destroyed') continue;
      const slot = this.buffer.slotOfHandle.get(event.handle);
      if (slot === undefined) continue;
      if (event.kind === 'damage') {
        this.hp[slot] = event.hp;
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

  /** Whether the body of `slot` is worn: its hp (from the `damage` events) is under half its material's. */
  worn(slot: number): boolean {
    if (slot >= this.hp.length) return false;
    const half = this.halfHp.get(this.buffer.handles[slot]);
    return half !== undefined && this.hp[slot] < half;
  }

  /** When the fade of `slot` started (display time, ms; -Infinity if it has not): tells a new destruction. */
  fadeStart(slot: number): number {
    return slot < this.fadeAt.length ? this.fadeAt[slot] : -Infinity;
  }

  /** Opacity of a destroyed body at `now` (0 once faded, or when not destroyed). */
  fade(slot: number, now: number): number {
    if (slot >= this.fadeAt.length) return 0;
    const t = (now - this.fadeAt[slot]) / FADE_MS;
    return t >= 0 && t < 1 ? 1 - t : 0;
  }

  /** Whether a pebble slot is spent (its shot ended) at frame index `frame`. */
  spent(slot: number, frame: number): boolean {
    return slot < this.spentFrame.length && this.spentFrame[slot] >= 0 && frame >= this.spentFrame[slot];
  }

  /** The frame whose pose a fading slot is drawn at. */
  fadePose(slot: number): number {
    return this.fadeFrame[slot];
  }

  /** The pebbles present at the frame of a `shot_end` at `tick` are spent there; they fade from `now`. */
  private spendPebbles(tick: number, now: number): void {
    const frame = this.buffer.frameAtTick(tick);
    if (frame < 0) return;
    for (let slot = this.buffer.levelSlotCount; slot < this.buffer.slotCount; slot++) {
      if (this.buffer.columns[slot].state[frame] === ABSENT) continue;
      if (this.spentFrame[slot] < 0 || frame < this.spentFrame[slot]) this.spentFrame[slot] = frame;
      this.fadeAt[slot] = now;
      this.fadeFrame[slot] = frame;
    }
  }

  private setHp(handle: number, hp: number): void {
    const slot = this.buffer.slotOfHandle.get(handle);
    if (slot !== undefined) this.hp[slot] = hp;
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
    this.hp = grow(this.hp, Infinity, (k) => new Float64Array(k));
    this.flashAt = grow(this.flashAt, -Infinity, (k) => new Float64Array(k));
    this.fadeAt = grow(this.fadeAt, -Infinity, (k) => new Float64Array(k));
    this.fadeFrame = grow(this.fadeFrame, -1, (k) => new Int32Array(k));
    this.spentFrame = grow(this.spentFrame, -1, (k) => new Int32Array(k));
  }
}
