import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it } from 'vitest';
import { TraceBuffer } from '../render/buffer';
import { Effects } from '../render/effects';
import { hudAt } from '../render/hud';
import { Playback } from '../render/playback';
import type { TraceEvent, TraceFrame } from '../trace/types';
import type { ShotHandlers, ShotRequest } from '../vm/index';
import type { ShotResult } from '../vm/shot';
import { ShotLoop } from './play';
import { LevelSession, type GameVm } from './session';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const HEADER = readFileSync(root('client/vm/fixtures/pile10-reference.main_trace.txt'), 'utf8')
  .split('\n')
  .filter((l) => /^(trace|level|material|body) /.test(l));
const PEBBLE = 11;
/** Frames of every shot of the fake worker: one second of play at 60 Hz. */
const SHOT_TICKS = 60;

const header = (shotsUsed: number, over: boolean, tick: number) => ['1', String(shotsUsed), over ? '1' : '0', '0', '0', String(tick), '0', 'world'];
const pebbleAt = (tick: number): TraceFrame => ({
  tick,
  bodies: [{ handle: PEBBLE, x: String(tick * 2 ** 30), y: String(2 ** 32), re: String(2 ** 32), im: '0', asleep: false }],
});

/** A worker the test drives: `emit` streams frames of the shot in flight, `finish` ends it. */
class StreamVm implements GameVm {
  private flight: { request: ShotRequest; handlers: ShotHandlers; sent: number; resolve: (r: ShotResult) => void; reject: (e: Error) => void } | null = null;

  get busy(): boolean {
    return this.flight !== null;
  }

  async init(_level: unknown, handlers: ShotHandlers = {}): Promise<ShotResult> {
    for (const line of HEADER) handlers.onLine?.(line);
    return { state: header(0, false, 0), chunks: [], steps: 0, ms: 0 };
  }

  shot(request: ShotRequest, handlers: ShotHandlers = {}): Promise<ShotResult> {
    return new Promise((resolve, reject) => (this.flight = { request, handlers, sent: 0, resolve, reject }));
  }

  async outputs(): Promise<ShotResult> {
    throw new Error('not used');
  }

  emit(frames: number): void {
    const f = this.flight!;
    const start = Number(f.request.state![5]);
    for (let k = 0; k < frames && f.sent < SHOT_TICKS; k++) f.handlers.onFrame?.(pebbleAt(start + ++f.sent));
  }

  finish(): void {
    const f = this.flight!;
    this.emit(SHOT_TICKS);
    const shot = f.request.shot!;
    const tick = Number(f.request.state![5]) + SHOT_TICKS;
    f.handlers.onEvent?.({ tick, kind: 'shot_end', shot });
    this.flight = null;
    f.resolve({ state: header(shot + 1, shot + 1 === 3, tick), chunks: [], steps: 1, ms: 1 });
  }

  fail(): void {
    const f = this.flight!;
    this.flight = null;
    f.reject(new Error('replay: shot'));
  }
}

/** A session, its buffer, a playback and a loop on a fake clock; `run` plays display frames of 1/60 s. */
async function setup() {
  const vm = new StreamVm();
  const session = await LevelSession.open(vm, { felts: [] });
  let now = 0;
  const buffer = new TraceBuffer(session.traceLevel);
  buffer.push(session.startFrame());
  const playback = new Playback(() => buffer.frameCount);
  const log: string[] = [];
  const loop = new ShotLoop(
    session,
    buffer,
    playback,
    {
      released: () => log.push(`released@${now}`),
      produced: () => log.push(`produced@${now}`),
      failed: () => log.push(`failed@${now}`),
      armed: () => log.push(`armed@${now}`),
      over: () => log.push(`over@${now}`),
    },
    () => now,
  );
  const frameMs = 1000 / 60;
  /** Plays `ms` of display time; `each` runs before every display frame (the worker's pace). */
  const run = (ms: number, each?: () => void) => {
    for (let t = 0; t < ms; t += frameMs) {
      each?.();
      now += frameMs;
      loop.advance(frameMs);
    }
  };
  return { vm, session, buffer, playback, loop, log, run, time: () => now };
}

describe('ShotLoop: the result and the sling wait for the playback (M2, M3)', () => {
  let t: Awaited<ReturnType<typeof setup>>;
  beforeEach(async () => {
    t = await setup();
  });

  it('VM faster than real time: re-arms when the last frame is shown, not when the worker is done', async () => {
    expect(t.loop.release({ x: -150, y: -150 })).toBe(true);
    expect(t.loop.armed).toBe(false);
    t.vm.finish(); // all 60 frames at once
    await t.loop.settled;
    expect(t.session.phase).toBe('aiming'); // the worker is done...
    expect(t.log).toEqual(['released@0', 'produced@0']);
    expect(t.loop.release({ x: -1, y: -1 })).toBe(false); // ...but a second release does not fire (M3)
    t.run(900);
    expect(t.loop.armed).toBe(false);
    expect(t.playback.position).toBeLessThan(t.playback.lastFrame);
    t.run(200);
    expect(t.loop.armed).toBe(true);
    expect(t.log[2]).toMatch(/^armed@/);
    const armedAt = Number(t.log[2].split('@')[1]);
    expect(armedAt).toBeGreaterThanOrEqual(1000 - 1e-9); // 60 frames at 60 Hz
    expect(armedAt).toBeLessThan(1000 + 20);
  });

  it('VM slower than real time: the head waits for the frames, and re-arms once the last one arrived and is shown', async () => {
    t.loop.release({ x: -150, y: -150 });
    let frame = 0;
    // 20 frames per second: the head plays at the arrival rate, never past the newest frame.
    t.run(2500, () => {
      if (++frame % 3 === 0) t.vm.emit(1);
      expect(t.playback.position).toBeLessThanOrEqual(t.playback.lastFrame);
    });
    expect(t.loop.producing).toBe(true);
    expect(t.loop.armed).toBe(false);
    t.vm.finish();
    await t.loop.settled;
    t.run(1500);
    expect(t.loop.armed).toBe(true);
    expect(t.playback.position).toBe(t.playback.lastFrame);
    expect(t.log.map((l) => l.split('@')[0])).toEqual(['released', 'produced', 'armed']);
  });

  it('paused playback: nothing re-arms and no result shows until the head reaches the end', async () => {
    for (let shot = 0; shot < 2; shot++) {
      t.loop.release({ x: -150, y: -150 });
      t.vm.finish();
      await t.loop.settled;
      t.run(1100);
    }
    t.loop.release({ x: -150, y: -150 }); // the third and last shot
    t.vm.finish();
    await t.loop.settled;
    expect(t.session.phase).toBe('over');
    t.run(300);
    t.playback.toggle();
    expect(t.playback.playing).toBe(false);
    t.run(5000);
    expect(t.log.filter((l) => l.startsWith('over'))).toEqual([]);
    expect(t.playback.running()).toBe(false);
    t.playback.toggle();
    t.run(1000);
    expect(t.log.filter((l) => l.startsWith('over'))).toHaveLength(1);
    expect(t.loop.armed).toBe(false); // the level is over: the sling stays empty
  });

  it('a scrub to the end while paused shows the end: the gate opens', async () => {
    t.loop.release({ x: -150, y: -150 });
    t.vm.finish();
    await t.loop.settled;
    t.playback.playing = false;
    t.run(100);
    expect(t.loop.armed).toBe(false);
    t.playback.seek(t.playback.lastFrame);
    t.run(20);
    expect(t.loop.armed).toBe(true);
  });

  it('Retry during the playback: allowed once the worker is idle, and the old loop fires nothing', async () => {
    t.loop.release({ x: -150, y: -150 });
    expect(t.loop.canLeave).toBe(false); // the worker is producing: Retry and the level list wait
    t.vm.emit(10);
    t.run(100);
    expect(t.loop.canLeave).toBe(false);
    t.vm.finish();
    await t.loop.settled;
    t.run(300);
    expect(t.loop.canLeave).toBe(true);
    t.loop.dispose();
    t.session.reset();
    t.run(2000);
    expect(t.log.map((l) => l.split('@')[0])).toEqual(['released', 'produced']);
    expect(t.loop.release({ x: -1, y: -1 })).toBe(false);
  });

  it('a failed shot re-arms at once and forgets the shot', async () => {
    t.loop.release({ x: -150, y: -150 });
    t.vm.fail();
    await t.loop.settled;
    expect(t.loop.armed).toBe(true);
    expect(t.session.shots).toEqual([]);
    expect(t.log.map((l) => l.split('@')[0])).toEqual(['released', 'failed']);
  });

  it('a release from a scrubbed-back head jumps to the newest frame', async () => {
    t.loop.release({ x: -150, y: -150 });
    t.vm.finish();
    await t.loop.settled;
    t.run(1100);
    t.playback.seek(5);
    expect(t.loop.release({ x: -200, y: -200 })).toBe(true);
    expect(t.playback.position).toBe(SHOT_TICKS);
  });
});

describe('released shots and spent pebbles (m2, m4)', () => {
  it('a released shot counts as spent in the HUD at once', async () => {
    const t = await setup();
    const shots = t.session.traceLevel.shots;
    expect(hudAt(t.session.events, shots, 0, t.session.releases).shotsLeft).toBe(3);
    t.loop.release({ x: -150, y: -150 });
    expect(t.session.releases).toEqual([0]);
    // The head still shows tick 0 and no frame of the shot arrived: already spent.
    expect(hudAt(t.session.events, shots, 0, t.session.releases).shotsLeft).toBe(2);
    t.vm.finish();
    await t.loop.settled;
    t.run(1100);
    t.loop.release({ x: -150, y: -150 });
    expect(hudAt(t.session.events, shots, SHOT_TICKS, t.session.releases).shotsLeft).toBe(1);
    // Scrubbed back into the first shot: one spent.
    expect(hudAt(t.session.events, shots, 30, t.session.releases).shotsLeft).toBe(2);
    t.vm.fail();
    await t.loop.settled;
    expect(t.session.releases).toEqual([0]);
  });

  it('the pebble is spent at its shot\'s last frame, and fades from there', async () => {
    const t = await setup();
    t.loop.release({ x: -150, y: -150 });
    t.vm.finish();
    await t.loop.settled;
    const effects = new Effects(t.buffer, t.session.events as TraceEvent[]);
    const slot = t.buffer.slotOfHandle.get(PEBBLE)!;
    expect(slot).toBe(t.buffer.levelSlotCount);
    const last = t.buffer.frameCount - 1;
    effects.advance(t.buffer.ticks[last - 1], last - 1, 0);
    expect(effects.spent(slot, last - 1)).toBe(false);
    effects.advance(t.buffer.ticks[last], last, 100);
    expect(effects.spent(slot, last)).toBe(true);
    expect(effects.fadePose(slot)).toBe(last);
    expect(effects.fade(slot, 100)).toBe(1);
    expect(effects.fade(slot, 10_000)).toBe(0);
    // Seek back into the flight: drawn again; the level's bodies are never spent.
    effects.advance(t.buffer.ticks[10], 10, 200);
    expect(effects.spent(slot, 10)).toBe(false);
    expect(effects.spent(0, last)).toBe(false);
  });
});

describe('Playback: Play / Pause from the real state (m3)', () => {
  it('is not running at the end of the frames, before the first shot or after a retry', () => {
    let frames = 1;
    const playback = new Playback(() => frames);
    expect(playback.playing).toBe(true);
    expect(playback.running()).toBe(false); // one frame: nothing plays, the label says Play
    expect(playback.running(true)).toBe(true); // a shot is coming: it plays as frames arrive
    frames = 30;
    expect(playback.running()).toBe(true);
    playback.advance(1000);
    expect(playback.running()).toBe(false);
    playback.toggle(); // Play at the end replays from the start
    expect([playback.playing, playback.position]).toEqual([true, 0]);
    playback.toggle();
    expect(playback.playing).toBe(false);
    playback.seek(29);
    playback.toggle(true); // producing: resumes where it is
    expect([playback.playing, playback.position]).toEqual([true, 29]);
  });
});
