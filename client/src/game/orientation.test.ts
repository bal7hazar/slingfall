// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { AimController, type KeySurface, type PointerSurface } from '../aim/controller';
import { Playback } from '../render/playback';
import { OVERLAY_CLASS, OrientationGuard, PHONE_PORTRAIT, INERT_SELECTORS, overlayShown, pageGuard, spaceToggles } from './orientation';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LevelHeader, parseTraceLine } from '../trace/lines';
import type { Graphics } from 'pixi.js';
import { worldToScreen, type Camera } from '../render/camera';
import { fixedToNumber } from '../trace/types';

/** A `matchMedia` of the test: it knows the facts of the device and evaluates the three terms of the query. */
function device(facts: { portrait: boolean; width: number; coarse: boolean }) {
  const listeners = new Set<() => void>();
  const evaluate = (query: string) => {
    expect(query).toBe(PHONE_PORTRAIT);
    return facts.portrait && facts.width <= 600 && facts.coarse;
  };
  const media = {
    get matches() {
      return evaluate(PHONE_PORTRAIT);
    },
    addEventListener: (_: 'change', l: () => void) => listeners.add(l),
    removeEventListener: (_: 'change', l: () => void) => listeners.delete(l),
  };
  return {
    media,
    rotate(to: Partial<typeof facts>) {
      Object.assign(facts, to);
      for (const l of [...listeners]) l();
    },
  };
}

const PAGE = `<div id="app"></div><div class="top"><div id="chain-info"><a href="#">c</a></div></div><div id="banner"></div>
<div id="result"><button id="retry-result">Retry</button><button id="copy-inputs">Copy</button><button>Connect</button><button>Submit</button></div>
<div id="controls"><button id="play">Play</button></div><div id="rotate" role="dialog"></div>`;

beforeEach(() => {
  document.body.innerHTML = PAGE;
});
const guards: OrientationGuard[] = [];
afterEach(() => {
  for (const guard of guards.splice(0)) guard.dispose(); // `shown` is module-level
  document.body.className = '';
});

function guarded(facts: { portrait: boolean; width: number; coarse: boolean }, playing = true) {
  const d = device(facts);
  const playback = new Playback(() => 10);
  playback.playing = playing;
  const changes: boolean[] = [];
  const guard = new OrientationGuard({
    media: d.media,
    body: document.body,
    playback,
    inert: () => INERT_SELECTORS.flatMap((s) => [...document.querySelectorAll<HTMLElement>(s)]),
    onChange: (shown) => changes.push(shown),
  });
  guards.push(guard);
  return { d, playback, guard, changes };
}

describe('the overlay and its query', () => {
  it('shows on a coarse-pointer phone in portrait', () => {
    const t = guarded({ portrait: true, width: 412, coarse: true });
    expect(t.guard.shown).toBe(true);
    expect(overlayShown()).toBe(true);
    expect(document.body.classList.contains(OVERLAY_CLASS)).toBe(true);
    t.guard.dispose();
  });

  it('does not show in a narrow desktop window (fine pointer), nor in landscape, nor on a wide portrait screen', () => {
    for (const facts of [
      { portrait: true, width: 500, coarse: false },
      { portrait: false, width: 915, coarse: true },
      { portrait: true, width: 800, coarse: true },
    ]) {
      const t = guarded(facts);
      expect(t.guard.shown).toBe(false);
      expect(document.body.classList.contains(OVERLAY_CLASS)).toBe(false);
      expect(t.playback.playing).toBe(true);
      t.guard.dispose();
    }
  });

  it('follows the rotation of the phone, both ways', () => {
    const t = guarded({ portrait: false, width: 915, coarse: true });
    t.d.rotate({ portrait: true, width: 412 });
    expect(document.body.classList.contains(OVERLAY_CLASS)).toBe(true);
    t.d.rotate({ portrait: false, width: 915 });
    expect(document.body.classList.contains(OVERLAY_CLASS)).toBe(false);
    expect(t.changes).toEqual([true, false]);
    t.guard.dispose();
  });

  it('builds the guard of the page from window.matchMedia', () => {
    const guard = pageGuard(new Playback(() => 1));
    guards.push(guard);
    expect(guard.shown).toBe(false); // happy-dom: no phone
    guard.dispose();
  });
});

describe('the pause', () => {
  it('resumes a playback that was playing', () => {
    const t = guarded({ portrait: false, width: 915, coarse: true }, true);
    t.d.rotate({ portrait: true, width: 412 });
    expect(t.playback.playing).toBe(false);
    t.d.rotate({ portrait: false, width: 915 });
    expect(t.playback.playing).toBe(true);
    t.guard.dispose();
  });

  it('leaves a pause the player chose paused', () => {
    const t = guarded({ portrait: false, width: 915, coarse: true }, false);
    t.d.rotate({ portrait: true, width: 412 });
    t.d.rotate({ portrait: false, width: 915 });
    expect(t.playback.playing).toBe(false);
    t.guard.dispose();
  });

  it('does not restart a finished trace', () => {
    const t = guarded({ portrait: false, width: 915, coarse: true }, true);
    t.playback.position = t.playback.lastFrame; // the end of the shot
    t.d.rotate({ portrait: true, width: 412 });
    t.d.rotate({ portrait: false, width: 915 });
    expect(t.playback.position).toBe(t.playback.lastFrame);
    t.guard.dispose();
  });

  it('does not move the head while it shows', () => {
    const t = guarded({ portrait: true, width: 412, coarse: true }, true);
    t.playback.advance(1000);
    expect(t.playback.position).toBe(0);
    t.guard.dispose();
  });

  it('waits for a stage shown under the overlay, then restores its flag', () => {
    const t = guarded({ portrait: true, width: 412, coarse: true }, true);
    t.playback.playing = true; // show() of a new stage
    t.guard.adopt();
    expect(t.playback.playing).toBe(false);
    t.d.rotate({ portrait: false, width: 915 });
    expect(t.playback.playing).toBe(true);
    t.guard.dispose();
  });
});

describe('the inert page', () => {
  it('makes every interactive sibling of the overlay inert, the overlay not', () => {
    const t = guarded({ portrait: true, width: 412, coarse: true });
    for (const selector of ['#app', '.top', '#banner', '#result', '#controls']) {
      expect(document.querySelector<HTMLElement>(selector)!.inert).toBe(true);
    }
    expect(INERT_SELECTORS).toContain('#result');
    expect(document.querySelector<HTMLElement>('#rotate')!.inert).toBe(false);
    t.d.rotate({ portrait: false, width: 915 });
    for (const selector of INERT_SELECTORS) expect(document.querySelector<HTMLElement>(selector)!.inert).toBe(false);
    t.guard.dispose();
  });
});

describe('the Space key under the overlay', () => {
  const space = (target: unknown = null) => ({ code: 'Space', target, preventDefault() {} }) as unknown as KeyboardEvent;

  it('toggles the playback in landscape, not while the overlay shows, not in a field', () => {
    let toggles = 0;
    const handler = spaceToggles(() => toggles++);
    const t = guarded({ portrait: false, width: 915, coarse: true });
    handler(space());
    expect(toggles).toBe(1);
    handler(space({ tagName: 'INPUT' }));
    expect(toggles).toBe(1);
    t.d.rotate({ portrait: true, width: 412 });
    handler(space());
    expect(toggles).toBe(1);
    t.d.rotate({ portrait: false, width: 915 });
    handler(space());
    expect(toggles).toBe(2);
  });
});

describe('the keys under the overlay', () => {
  const root = (path: string) => resolve(dirname(fileURLToPath(import.meta.url)), '../../..', path); // not `new URL`: vite takes it for an asset in this environment
  function level() {
    const header = new LevelHeader();
    for (const line of readFileSync(root('client/vm/fixtures/pile10-reference.main_trace.txt'), 'utf8').split('\n')) {
      const parsed = /^(trace|level|material|body) /.test(line) ? parseTraceLine(line) : null;
      if (parsed !== null) header.push(parsed);
    }
    return header.level();
  }
  class Fake<E> {
    listener: ((event: E) => void) | undefined;
    addEventListener(_: string, l: (event: E) => void) {
      this.listener = l;
    }
    removeEventListener() {}
  }

  it('ends a drag that was going when the phone turned to portrait without a shot', () => {
    const traceLevel = level();
    const handlers = new Map<string, (event: PointerEvent) => void>();
    const canvas = {
      addEventListener: (type: string, l: (event: PointerEvent) => void) => handlers.set(type, l),
      removeEventListener() {},
      getBoundingClientRect: () => ({ left: 0, top: 0 }),
      setPointerCapture() {},
    } as unknown as PointerSurface;
    const graphics = new Proxy({}, { get: () => () => graphics }) as unknown as Graphics;
    const camera = { scale: 10, offsetX: 0, offsetY: 0 } as Camera;
    const released: unknown[] = [];
    const aim = new AimController({ canvas, camera: () => camera, fullPullPx: () => 200, graphics, level: traceLevel, onRelease: (p) => released.push(p) });
    // Grab exactly at the anchor, then drag far to the left.
    const anchor = worldToScreen(camera, fixedToNumber(traceLevel.sling_anchor.x), fixedToNumber(traceLevel.sling_anchor.y));
    const at = (x: number, y: number) => ({ pointerId: 1, pointerType: 'touch', clientX: x, clientY: y }) as PointerEvent;
    const t = guarded({ portrait: false, width: 915, coarse: true });
    handlers.get('pointerdown')!(at(anchor.x, anchor.y));
    handlers.get('pointermove')!(at(anchor.x - 150, anchor.y));
    expect(aim.current).not.toEqual({ x: 0, y: 0 }); // a real pull, not a zero one that would only cancel
    expect(aim.current).toBeDefined();
    t.d.rotate({ portrait: true, width: 412 });
    handlers.get('pointerup')!(at(anchor.x - 150, anchor.y));
    expect(released).toEqual([]);
    expect(aim.current).toBeUndefined();
  });

  it('ignores the arrows and Enter while it shows, and takes them back after', () => {
    const traceLevel = level();
    const keys = new Fake<KeyboardEvent>();
    const canvas = { addEventListener() {}, removeEventListener() {}, getBoundingClientRect: () => ({ left: 0, top: 0 }), setPointerCapture() {} } as PointerSurface;
    const graphics = new Proxy({}, { get: () => () => graphics }) as unknown as Graphics;
    const camera = { scale: 10 } as Camera; // the keys do not look at the screen
    const aims: unknown[] = [];
    const released: unknown[] = [];
    new AimController({
      canvas,
      keys: keys as unknown as KeySurface,
      camera: () => camera,
      fullPullPx: () => 200,
      graphics,
      level: traceLevel,
      onAim: (p) => aims.push(p),
      onRelease: (p) => released.push(p),
    });
    const press = (key: string) => keys.listener!({ key, shiftKey: false, target: null, preventDefault() {} } as unknown as KeyboardEvent);
    const t = guarded({ portrait: true, width: 412, coarse: true });
    const before = aims.length;
    press('ArrowLeft');
    press('Enter');
    expect(aims.length).toBe(before);
    expect(released).toEqual([]);
    t.d.rotate({ portrait: false, width: 915 });
    press('ArrowLeft');
    press('Enter');
    expect(released.length).toBe(1);
    t.guard.dispose();
  });
});
