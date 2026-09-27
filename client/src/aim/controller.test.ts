import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Graphics } from 'pixi.js';
import { describe, expect, it } from 'vitest';
import { frameCamera, frameRect, worldToScreen, type Camera } from '../render/camera';
import { LevelHeader, parseTraceLine } from '../trace/lines';
import { fixedToNumber } from '../trace/types';
import { AimController, GRAB_MIN_PX_TOUCH, arrowNudge, type KeySurface, type PointerSurface } from './controller';
import { fullPullPixels, type Pull } from './pull';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));

/** pile10 as `init` prints it. */
function pile10() {
  const header = new LevelHeader();
  for (const line of readFileSync(root('client/vm/fixtures/pile10-reference.main_trace.txt'), 'utf8').split('\n')) {
    const parsed = /^(trace|level|material|body) /.test(line) ? parseTraceLine(line) : null;
    if (parsed !== null) header.push(parsed);
  }
  return header.level();
}

/** A PixiJS `Graphics` that records nothing: every method chains. */
function nullGraphics(): Graphics {
  const target: Record<string, unknown> = {};
  const proxy: unknown = new Proxy(target, { get: () => () => proxy });
  return proxy as Graphics;
}

class FakeTarget<E> {
  readonly listeners = new Map<string, (event: E) => void>();
  addEventListener(type: string, listener: (event: E) => void): void {
    this.listeners.set(type, listener);
  }
  removeEventListener(type: string): void {
    this.listeners.delete(type);
  }
  fire(type: string, event: Partial<E>): void {
    this.listeners.get(type)?.(event as E);
  }
}

class FakeCanvas extends FakeTarget<PointerEvent> implements PointerSurface {
  getBoundingClientRect() {
    return { left: 0, top: 0 };
  }
  setPointerCapture(): void {}
}

function setup(camera: Camera, fullPx: number) {
  const level = pile10();
  const canvas = new FakeCanvas();
  const keys = new FakeTarget<KeyboardEvent>();
  const shown: (Pull | undefined)[] = [];
  const released: Pull[] = [];
  const aim = new AimController({
    canvas,
    keys: keys as KeySurface,
    camera: () => camera,
    fullPullPx: () => fullPx,
    graphics: nullGraphics(),
    level,
    onAim: (p) => shown.push(p),
    onRelease: (p) => released.push(p),
  });
  const key = (k: string, shiftKey = false) => keys.fire('keydown', { key: k, shiftKey, target: null, preventDefault() {} });
  const anchor = worldToScreen(camera, fixedToNumber(level.sling_anchor.x), fixedToNumber(level.sling_anchor.y));
  return { level, canvas, keys, aim, shown, released, key, anchor };
}

const CAMERA: Camera = { scale: 40, offsetX: 100, offsetY: 600 };

describe('AimController: fine aiming by keyboard (M5)', () => {
  it('reaches the owner\'s pile10 pull (-1022, -63) exactly, displays it, and releases exactly it', () => {
    const t = setup(CAMERA, 200);
    for (let i = 0; i < 102; i++) t.key('ArrowLeft', true);
    t.key('ArrowLeft');
    t.key('ArrowLeft');
    for (let i = 0; i < 6; i++) t.key('ArrowDown', true);
    for (let i = 0; i < 3; i++) t.key('ArrowDown');
    expect(t.aim.current).toEqual({ x: -1022, y: -63 });
    expect(t.shown.at(-1)).toEqual({ x: -1022, y: -63 });
    t.key('Enter');
    // The pull sent is the integer pair displayed last (determinism guard).
    expect(t.released).toEqual([{ x: -1022, y: -63 }]);
    expect(t.shown.at(-1)).toBeUndefined();
  });

  it('stays inside the disk: a step past the edge stops on the last integer inside', () => {
    const t = setup(CAMERA, 200);
    for (let i = 0; i < 120; i++) t.key('ArrowLeft', true);
    expect(t.aim.current).toEqual({ x: -1024, y: 0 });
    t.key('ArrowDown');
    expect(t.aim.current).toEqual({ x: -1024, y: 0 }); // (−1024, −1) is outside the disk of radius 1024
    t.key('ArrowRight');
    t.key('ArrowDown', true);
    expect(t.aim.current).toEqual({ x: -1023, y: -10 });
    expect(1023 ** 2 + 10 ** 2).toBeLessThanOrEqual(1024 ** 2);
  });

  it('starts from the last pull released, cancels on Escape, and does nothing unarmed', () => {
    const t = setup(CAMERA, 200);
    t.key('ArrowLeft', true);
    t.key('Enter');
    t.key('ArrowUp');
    expect(t.aim.current).toEqual({ x: -10, y: 1 });
    t.key('Escape');
    expect(t.aim.current).toBeUndefined();
    t.aim.enabled = false;
    t.key('ArrowUp');
    t.key('Enter');
    expect(t.aim.current).toBeUndefined();
    expect(t.released).toEqual([{ x: -10, y: 0 }]);
  });

  it('leaves keys typed into a form field alone', () => {
    const t = setup(CAMERA, 200);
    t.keys.fire('keydown', { key: 'ArrowLeft', shiftKey: false, target: { tagName: 'SELECT' } as unknown as EventTarget, preventDefault() {} });
    expect(t.aim.current).toBeUndefined();
  });

  it('maps the arrows onto pull units (Shift: 10)', () => {
    expect(arrowNudge('ArrowLeft', false)).toEqual({ axis: 'x', step: -1 });
    expect(arrowNudge('ArrowUp', true)).toEqual({ axis: 'y', step: 10 });
    expect(arrowNudge('a', false)).toBeNull();
  });
});

describe('AimController: the drag (M5)', () => {
  const pointer = (x: number, y: number, pointerType = 'mouse') => ({ pointerId: 1, pointerType, clientX: x, clientY: y });

  it('scales the drag to the screen, whatever the zoom: a full pull is fullPullPx pixels', () => {
    for (const scale of [10, 40, 120]) {
      const t = setup({ scale, offsetX: 300, offsetY: 500 }, 200);
      t.canvas.fire('pointerdown', pointer(t.anchor.x, t.anchor.y));
      t.canvas.fire('pointermove', pointer(t.anchor.x - 200, t.anchor.y));
      expect(t.aim.current).toEqual({ x: -1024, y: 0 });
      t.canvas.fire('pointermove', pointer(t.anchor.x - 100, t.anchor.y + 50)); // screen y down: pull y down
      expect(t.aim.current).toEqual({ x: -512, y: -256 });
      t.canvas.fire('pointerup', pointer(t.anchor.x - 100, t.anchor.y + 50));
      expect(t.released).toEqual([{ x: -512, y: -256 }]);
      expect(t.shown.at(-2)).toEqual({ x: -512, y: -256 }); // displayed, then cleared by the release
    }
  });

  it('measures the drag from the press point, so a grab off-centre starts at (0, 0)', () => {
    const t = setup(CAMERA, 200);
    t.canvas.fire('pointerdown', pointer(t.anchor.x + 10, t.anchor.y - 10));
    expect(t.aim.current).toEqual({ x: 0, y: 0 });
    t.canvas.fire('pointerup', pointer(t.anchor.x + 10, t.anchor.y - 10));
    expect(t.released).toEqual([]); // a zero pull does not fire
  });

  it('grabs within 44 px of the pebble on a touch screen, even when the world is tiny', () => {
    const tiny: Camera = { scale: 6, offsetX: 50, offsetY: 400 }; // 1.5 m = 9 px (QA: iPhone 13)
    const t = setup(tiny, 105);
    t.canvas.fire('pointerdown', pointer(t.anchor.x + GRAB_MIN_PX_TOUCH - 1, t.anchor.y, 'touch'));
    expect(t.aim.current).toEqual({ x: 0, y: 0 });
    t.canvas.fire('pointercancel', pointer(0, 0));
    expect(t.aim.current).toBeUndefined();
    t.canvas.fire('pointerdown', pointer(t.anchor.x + GRAB_MIN_PX_TOUCH + 1, t.anchor.y, 'touch'));
    expect(t.aim.current).toBeUndefined();
  });

  it('does not grab while unarmed', () => {
    const t = setup(CAMERA, 200);
    t.aim.enabled = false;
    t.canvas.fire('pointerdown', pointer(t.anchor.x, t.anchor.y));
    expect(t.aim.current).toBeUndefined();
  });
});

describe('pile10 framing, measured', () => {
  // [viewport, controls inset] -> px per metre, full pull px, pull units per px, drag inside the screen
  it.each([
    [1280, 800],
    [390, 664],
    [390, 844],
    [844, 390],
  ])('%d x %d', (width, height) => {
    const level = pile10();
    const insets = { top: 0, bottom: 44 };
    const full = fullPullPixels(width, height);
    const anchor = { x: fixedToNumber(level.sling_anchor.x), y: fixedToNumber(level.sling_anchor.y) };
    const camera = frameCamera(frameRect(level), anchor, full, width, height, insets);
    const a = worldToScreen(camera, anchor.x, anchor.y);
    // A full drag in any direction stays on the play area.
    expect(a.x - full).toBeGreaterThanOrEqual(-1);
    expect(a.x + full).toBeLessThanOrEqual(width + 1);
    expect(a.y - full).toBeGreaterThanOrEqual(-1);
    expect(a.y + full).toBeLessThanOrEqual(height - 44 + 1);
    // Old: fitCamera on the 60 x 50 m bounds gave 6-20 px per metre and 24-61 pull units per px.
    expect(1024 / full).toBeLessThan(10.5);
    expect(camera.scale).toBeGreaterThan(9);
  });
});
