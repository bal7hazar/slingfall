import { describe, expect, it } from 'vitest';
import { ABSENT, ASLEEP, AWAKE, TraceBuffer } from './buffer';
import { boundsOf, fitCamera, screenToWorld, worldToScreen } from './camera';
import { hudAt } from './hud';
import { Playback } from './playback';
import { buildPile10 } from '../trace/synth';
import type { TraceEvent } from '../trace/types';

describe('camera', () => {
  const bounds = { minX: -10, minY: -2, maxX: 30, maxY: 18 };

  it('fits the bounds inside the screen, limited by the tighter axis', () => {
    const wide = fitCamera(bounds, 1600, 400);
    expect(wide.scale).toBeCloseTo((400 * 0.94) / 20);
    const tall = fitCamera(bounds, 400, 1600);
    expect(tall.scale).toBeCloseTo((400 * 0.94) / 40);
  });

  it('keeps every corner of the bounds on screen, above the bottom inset', () => {
    const camera = fitCamera(bounds, 1280, 720, { top: 0, bottom: 44 });
    for (const [x, y] of [
      [bounds.minX, bounds.minY],
      [bounds.maxX, bounds.maxY],
    ]) {
      const p = worldToScreen(camera, x, y);
      expect(p.x).toBeGreaterThanOrEqual(0);
      expect(p.x).toBeLessThanOrEqual(1280);
      expect(p.y).toBeGreaterThanOrEqual(0);
      expect(p.y).toBeLessThanOrEqual(720 - 44);
    }
  });

  it('draws world y upwards and inverts exactly', () => {
    const camera = fitCamera(bounds, 1280, 720);
    const low = worldToScreen(camera, 0, 0);
    const high = worldToScreen(camera, 0, 10);
    expect(high.y).toBeLessThan(low.y);
    const back = screenToWorld(camera, low.x, low.y);
    expect(back.x).toBeCloseTo(0);
    expect(back.y).toBeCloseTo(0);
  });

  it('reads the level bounds', () => {
    expect(boundsOf(buildPile10().level)).toEqual({ minX: -12, minY: -4, maxX: 26, maxY: 14 });
  });
});

describe('TraceBuffer', () => {
  const trace = buildPile10();

  it('converts frames once and keeps statics at their level pose', () => {
    const buffer = new TraceBuffer(trace.level);
    for (const frame of trace.frames) buffer.push(frame);
    expect(buffer.frameCount).toBe(trace.frames.length);
    const ground = buffer.columns[buffer.slotOfHandle.get(0)!];
    expect(ground.state[0]).toBe(ASLEEP);
    expect(ground.y[10]).toBe(0);
    expect(buffer.ticks[buffer.frameCount - 1]).toBe(trace.frames.length - 1);
  });

  it('marks a body absent from a frame, and gives a new handle its own slot', () => {
    const buffer = new TraceBuffer(trace.level);
    for (const frame of trace.frames) buffer.push(frame);
    const roof = buffer.columns[buffer.slotOfHandle.get(7)!];
    expect(roof.state[0]).toBe(ASLEEP);
    expect(roof.state[buffer.frameCount - 1]).toBe(ABSENT);
    const pebble = buffer.columns[buffer.slotOfHandle.get(11)!];
    expect(pebble.state[1]).toBe(AWAKE);
    expect(buffer.slotCount).toBe(12);
  });

  it('grows past its initial capacity', () => {
    const buffer = new TraceBuffer(trace.level);
    for (let i = 0; i < 1100; i++) buffer.push({ ...trace.frames[i % trace.frames.length], tick: i });
    expect(buffer.frameCount).toBe(1100);
    expect(buffer.ticks[1099]).toBe(1099);
    expect(buffer.columns[buffer.slotOfHandle.get(4)!].state[1099]).not.toBe(ABSENT);
  });
});

describe('Playback', () => {
  it('advances at 60 frames per second and stalls on the newest frame', () => {
    let frames = 10;
    const playback = new Playback(() => frames);
    playback.advance(50);
    expect(playback.position).toBeCloseTo(3);
    playback.advance(1000);
    expect(playback.position).toBe(9);
    expect(playback.atEnd).toBe(true);
    frames = 20; // more frames streamed in: playback goes on
    playback.advance(100);
    expect(playback.position).toBeCloseTo(15);
  });

  it('pauses, scrubs within the frames, and replays from the end', () => {
    const playback = new Playback(() => 30);
    playback.toggle();
    playback.advance(1000);
    expect(playback.position).toBe(0);
    playback.seek(12.5);
    expect(playback.position).toBe(12.5);
    playback.seek(-3);
    expect(playback.position).toBe(0);
    playback.seek(1000);
    expect(playback.position).toBe(29);
    playback.toggle(); // play again from the end
    expect(playback.playing).toBe(true);
    expect(playback.position).toBe(0);
  });
});

describe('hudAt', () => {
  const events: TraceEvent[] = [
    { tick: 20, kind: 'destroyed', handle: 7 },
    { tick: 20, kind: 'score', points: 100, total: 100 },
    { tick: 30, kind: 'shot_end', shot: 0 },
    { tick: 55, kind: 'score', points: 1000, total: 1100 },
  ];

  it.each([
    [0, 0, 3],
    [19, 0, 3],
    [20, 100, 3],
    [30, 100, 2],
    [54, 100, 2],
    [55, 1100, 2],
  ])('tick %d: score %d, %d shots left', (tick, score, shotsLeft) => {
    expect(hudAt(events, 3, tick)).toEqual({ score, shotsLeft });
  });
});
