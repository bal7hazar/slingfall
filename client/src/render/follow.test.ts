import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { arcParamsFromLevel, flightArc } from '../aim/arc';
import { fullPullPixels, type Pull } from '../aim/pull';
import { LevelHeader, parseTraceLine, startFrame } from '../trace/lines';
import { fixedToNumber, type TraceLevel } from '../trace/types';
import { TraceBuffer } from './buffer';
import { boundsOf, easeCamera, frameRect, worldToScreen } from './camera';
import { CameraRig, followRect } from './follow';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const PEBBLE = 11;
const INSETS = { top: 0, bottom: 44 };

function pile10(): TraceLevel {
  const header = new LevelHeader();
  for (const line of readFileSync(root('client/vm/fixtures/pile10-reference.main_trace.txt'), 'utf8').split('\n')) {
    const parsed = /^(trace|level|material|body) /.test(line) ? parseTraceLine(line) : null;
    if (parsed !== null) header.push(parsed);
  }
  return header.level();
}

/** A buffer holding the tick-0 frame and the exact free flight of `pull` (the aim arc's ticks). */
function flight(level: TraceLevel, pull: Pull): TraceBuffer {
  const buffer = new TraceBuffer(level);
  buffer.push(startFrame(level));
  flightArc(arcParamsFromLevel(level), pull).forEach((p, i) =>
    buffer.push({ tick: i + 1, bodies: [{ handle: PEBBLE, x: p.x.toString(), y: p.y.toString(), re: String(2 ** 32), im: '0', asleep: false }] }),
  );
  return buffer;
}

describe('framing on the sling and the structures (M5)', () => {
  it('frames pile10 on its sling and pile, not on its 60 x 50 m bounds', () => {
    const level = pile10();
    const r = frameRect(level);
    expect(r.minX).toBeCloseTo(3 - 1.5); // the anchor at x = 3, less the margin
    expect(r.minY).toBeLessThanOrEqual(0 - 1.5); // the ground under the sling (and the blocks' bounding circles)
    expect(r.minY).toBeGreaterThan(-2);
    expect(r.maxX).toBeGreaterThan(21); // the pile ends at x = 21.5
    expect(r.maxX).toBeLessThan(25);
    expect(r.maxY).toBeLessThan(8);
    const b = boundsOf(level);
    expect(r.maxX - r.minX).toBeLessThan((b.maxX - b.minX) / 2);
  });

  it('eases towards the target and snaps once close', () => {
    const from = { scale: 10, offsetX: 0, offsetY: 0 };
    const to = { scale: 20, offsetX: 100, offsetY: 50 };
    const half = easeCamera(from, to, 220 * Math.LN2);
    expect(half.scale).toBeCloseTo(15);
    let c = from;
    for (let i = 0; i < 200; i++) c = easeCamera(c, to, 16);
    expect(c).toBe(to);
  });
});

describe('the camera follows the flight: every tick of a flight inside the bounds is on screen', () => {
  // Pulls: the owner's winning shot, a lob at 45°, straight up (21 m high), a flat full pull.
  const pulls: Pull[] = [
    { x: -1022, y: -63 },
    { x: -723, y: -723 },
    { x: 0, y: -1024 },
    { x: -1024, y: 0 },
    { x: -300, y: -900 },
  ];
  it.each([
    [1280, 800],
    [390, 844],
    [844, 390],
  ])('%d x %d', (width, height) => {
    const level = pile10();
    const bounds = boundsOf(level);
    for (const pull of pulls) {
      const buffer = flight(level, pull);
      const rig = new CameraRig(level, buffer, () => ({ width, height }), INSETS, () => fullPullPixels(width, height));
      const framed = rig.camera.scale;
      let minScale = framed;
      // The playback at real time: one frame per 1/60 s of display time.
      for (let i = 0; i < buffer.frameCount; i++) {
        rig.step(i, 1000 / 60);
        minScale = Math.min(minScale, rig.camera.scale);
        const c = buffer.columns[buffer.slotOfHandle.get(PEBBLE)!];
        if (i === 0) continue;
        const inBounds = c.x[i] >= bounds.minX && c.x[i] <= bounds.maxX && c.y[i] >= bounds.minY && c.y[i] <= bounds.maxY;
        if (!inBounds) continue; // the engine removes it there
        const p = worldToScreen(rig.camera, c.x[i], c.y[i]);
        expect(p.x, `pull (${pull.x}, ${pull.y}) tick ${i}`).toBeGreaterThanOrEqual(0);
        expect(p.x).toBeLessThanOrEqual(width);
        expect(p.y).toBeGreaterThanOrEqual(0);
        expect(p.y).toBeLessThanOrEqual(height - INSETS.bottom);
      }
      expect(minScale).toBeLessThanOrEqual(framed);
    }
  });

  it('frames the structures alone while no pebble flies', () => {
    const level = pile10();
    const buffer = flight(level, { x: -1022, y: -63 });
    const frame = frameRect(level);
    expect(followRect(frame, boundsOf(level), buffer, 0)).toEqual(frame);
    const high = followRect(frame, boundsOf(level), flight(level, { x: 0, y: -1024 }), 60);
    expect(high.maxY).toBeGreaterThan(20); // the top of the vertical shot, 21 m up
    expect(fixedToNumber(level.sling_anchor.y)).toBe(2.5);
  });
});
