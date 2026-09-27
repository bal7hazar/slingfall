import { ABSENT, type TraceBuffer } from './buffer';
import { boundsOf, clampRect, easeCamera, frameCamera, frameRect, union, type Camera, type Insets, type Rect } from './camera';
import type { Effects } from './effects';
import { fixedToNumber, type TraceLevel } from '../trace/types';

/** World margin kept around a flying pebble while the camera follows it, metres. */
export const FOLLOW_MARGIN_METRES = 2.5;
/** The camera also frames where the pebble will be this many frames later (the easing lags). */
export const FOLLOW_LOOKAHEAD_FRAMES = 12;

/**
 * The camera target at frame `index`: `frame` (the sling and the structures), grown to keep every
 * pebble present and not yet spent, now and `FOLLOW_LOOKAHEAD_FRAMES` later, inside
 * `FOLLOW_MARGIN_METRES`, within the level `bounds` (the engine removes a pebble at the bounds).
 * While aiming the newest frame has no pebble and the target is the frame itself.
 */
export function followRect(frame: Rect, bounds: Rect, buffer: TraceBuffer, index: number, effects?: Effects): Rect {
  if (buffer.frameCount === 0) return frame;
  let r = frame;
  const last = buffer.frameCount - 1;
  const i = Math.min(Math.max(index, 0), last);
  const m = FOLLOW_MARGIN_METRES;
  for (let slot = buffer.levelSlotCount; slot < buffer.slotCount; slot++) {
    const c = buffer.columns[slot];
    if (c.state[i] === ABSENT || effects?.spent(slot, i)) continue;
    for (const k of [i, Math.min(i + FOLLOW_LOOKAHEAD_FRAMES, last)]) {
      if (c.state[k] === ABSENT) continue;
      r = union(r, { minX: c.x[k] - m, minY: c.y[k] - m, maxX: c.x[k] + m, maxY: c.y[k] + m });
    }
  }
  return clampRect(r, bounds);
}

/**
 * The stage's camera, without PixiJS: framed on the sling and the structures with `padPx()` of
 * screen around the anchor (room for a full drag), zooming out, eased, to follow a pebble in flight.
 */
export class CameraRig {
  camera: Camera;
  private readonly frame: Rect;
  private readonly bounds: Rect;
  private readonly anchor: { x: number; y: number };
  private readonly buffer: TraceBuffer;
  private readonly screen: () => { width: number; height: number };
  private readonly insets: Insets;
  private readonly padPx: () => number;

  constructor(
    level: TraceLevel,
    buffer: TraceBuffer,
    screen: () => { width: number; height: number },
    insets: Insets,
    padPx: () => number,
  ) {
    this.frame = frameRect(level);
    this.bounds = boundsOf(level);
    this.anchor = { x: fixedToNumber(level.sling_anchor.x), y: fixedToNumber(level.sling_anchor.y) };
    this.buffer = buffer;
    this.screen = screen;
    this.insets = insets;
    this.padPx = padPx;
    this.camera = this.target(0);
  }

  /** The camera wanted at frame `index`. */
  target(index: number, effects?: Effects): Camera {
    const { width, height } = this.screen();
    const rect = followRect(this.frame, this.bounds, this.buffer, index, effects);
    return frameCamera(rect, this.anchor, this.padPx(), width, height, this.insets);
  }

  /** Eases towards the target of frame `index` over `deltaMs`; returns whether the camera moved. */
  step(index: number, deltaMs: number, effects?: Effects): boolean {
    const next = easeCamera(this.camera, this.target(index, effects), deltaMs);
    const c = this.camera;
    if (next.scale === c.scale && next.offsetX === c.offsetX && next.offsetY === c.offsetY) return false;
    this.camera = next;
    return true;
  }

  /** Jumps to the target (a resize). */
  snap(index: number, effects?: Effects): void {
    this.camera = this.target(index, effects);
  }
}
