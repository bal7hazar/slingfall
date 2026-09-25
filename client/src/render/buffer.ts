import { fixedToNumber, type TraceFrame, type TraceLevel } from '../trace/types';

/** Body state at a frame. `ABSENT`: the body does not exist at that tick (not yet, or removed). */
export const ABSENT = 0;
export const AWAKE = 1;
export const ASLEEP = 2;

/** Growable columns of one body over the frames received so far. */
export interface Column {
  x: Float64Array;
  y: Float64Array;
  re: Float64Array;
  im: Float64Array;
  state: Uint8Array;
}

function newColumn(capacity: number): Column {
  return {
    x: new Float64Array(capacity),
    y: new Float64Array(capacity),
    re: new Float64Array(capacity),
    im: new Float64Array(capacity),
    state: new Uint8Array(capacity),
  };
}

function grown<T extends Float64Array | Uint8Array | Int32Array>(array: T, capacity: number): T {
  const next = new (array.constructor as new (length: number) => T)(capacity);
  next.set(array);
  return next;
}

const INITIAL_CAPACITY = 512;

/**
 * The frames of a trace as `f64` columns, one per body ("slot"), converted once when a frame
 * arrives so that drawing never touches `BigInt` or allocates. Frames are appended as a source
 * yields them; the renderer reads `frameCount` each tick.
 */
export class TraceBuffer {
  /** Slot of a body handle. Level bodies first, in level order; pebbles as they first appear. */
  readonly slotOfHandle = new Map<number, number>();
  readonly handles: number[] = [];
  readonly columns: Column[] = [];
  ticks = new Int32Array(INITIAL_CAPACITY);
  frameCount = 0;

  private capacity = INITIAL_CAPACITY;
  private readonly staticSlots: { slot: number; x: number; y: number; re: number; im: number }[] = [];

  constructor(level: TraceLevel) {
    for (const body of level.bodies) {
      const slot = this.slotFor(body.handle);
      if (body.kind === 'static') {
        const p = body.pose;
        this.staticSlots.push({
          slot,
          x: fixedToNumber(p.x),
          y: fixedToNumber(p.y),
          re: fixedToNumber(p.re),
          im: fixedToNumber(p.im),
        });
      }
    }
  }

  get slotCount(): number {
    return this.handles.length;
  }

  /** Appends a frame. A static body a frame does not carry keeps its level pose. */
  push(frame: TraceFrame): void {
    if (this.frameCount === this.capacity) this.grow();
    const i = this.frameCount;
    this.ticks[i] = frame.tick;
    for (const s of this.staticSlots) {
      const c = this.columns[s.slot];
      c.x[i] = s.x;
      c.y[i] = s.y;
      c.re[i] = s.re;
      c.im[i] = s.im;
      c.state[i] = ASLEEP;
    }
    for (const body of frame.bodies) {
      const c = this.columns[this.slotFor(body.handle)];
      c.x[i] = fixedToNumber(body.x);
      c.y[i] = fixedToNumber(body.y);
      c.re[i] = fixedToNumber(body.re);
      c.im[i] = fixedToNumber(body.im);
      c.state[i] = body.asleep ? ASLEEP : AWAKE;
    }
    this.frameCount = i + 1;
  }

  private slotFor(handle: number): number {
    let slot = this.slotOfHandle.get(handle);
    if (slot === undefined) {
      slot = this.handles.length;
      this.slotOfHandle.set(handle, slot);
      this.handles.push(handle);
      this.columns.push(newColumn(this.capacity));
    }
    return slot;
  }

  private grow(): void {
    this.capacity *= 2;
    this.ticks = grown(this.ticks, this.capacity);
    for (const c of this.columns) {
      c.x = grown(c.x, this.capacity);
      c.y = grown(c.y, this.capacity);
      c.re = grown(c.re, this.capacity);
      c.im = grown(c.im, this.capacity);
      c.state = grown(c.state, this.capacity);
    }
  }
}
