import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it } from 'vitest';
import { TraceBuffer } from '../render/buffer';
import { Effects } from '../render/effects';
import { hudAt } from '../render/hud';
import { Playback } from '../render/playback';
import type { TraceEvent, TraceFrame } from '../trace/types';
import type { ShotHandlers, ShotRequest } from '../vm/index';
import type { ChunkReport, ShotResult } from '../vm/shot';
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
  /** Every request and the handler keys the session passed, in order. */
  readonly requests: { request: ShotRequest; handlerKeys: string[] }[] = [];
  /** Frames of each shot. */
  shotTicks = SHOT_TICKS;
  private chunks = 0;
  private flight: { request: ShotRequest; handlers: ShotHandlers; sent: number; resolve: (r: ShotResult) => void; reject: (e: Error) => void } | null = null;

  get busy(): boolean {
    return this.flight !== null;
  }

  async init(_level: unknown, handlers: ShotHandlers = {}): Promise<ShotResult> {
    for (const line of HEADER) handlers.onLine?.(line);
    return { state: header(0, false, 0), chunks: [], steps: 0, ms: 0 };
  }

  shot(request: ShotRequest, handlers: ShotHandlers = {}): Promise<ShotResult> {
    this.chunks = 0;
    this.requests.push({ request: structuredClone(request), handlerKeys: Object.keys(handlers).sort() });
    return new Promise((resolve, reject) => (this.flight = { request, handlers, sent: 0, resolve, reject }));
  }

  async outputs(): Promise<ShotResult> {
    throw new Error('not used');
  }

  emit(frames: number): void {
    const f = this.flight!;
    const start = Number(f.request.state![5]);
    for (let k = 0; k < frames && f.sent < this.shotTicks; k++) f.handlers.onFrame?.(pebbleAt(start + ++f.sent));
  }

  /** A stepping chunk: its frames, then its report (`ms` of VM wall time). */
  chunk(ticks: number, steps: number, ms: number): void {
    this.emit(ticks);
    const report: ChunkReport = { index: this.chunks++, ticks, steps, memoryCells: 0, execCells: 0, reserveCells: 0, ms, wasmBytes: 0 };
    this.flight!.handlers.onChunk?.(report);
  }

  finish(): void {
    const f = this.flight!;
    this.emit(this.shotTicks);
    const shot = f.request.shot!;
    const tick = Number(f.request.state![5]) + this.shotTicks;
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
async function setup(options: { levelId?: number; shotTicks?: number } = {}) {
  const vm = new StreamVm();
  vm.shotTicks = options.shotTicks ?? SHOT_TICKS;
  // version, level_id, seed, gravity_y, shots, tick_cap (`levelInfo`); the id keys the tick table.
  const session = await LevelSession.open(vm, { felts: ['1', String(options.levelId ?? 2), '0', '0', '3', '180'] });
  let now = 0;
  const buffer = new TraceBuffer(session.traceLevel);
  buffer.push(session.startFrame());
  const playback = new Playback(() => buffer.frameCount);
  const log: string[] = [];
  const sink = { info: [] as string[], warn: [] as string[] };
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
    { info: (m: string) => sink.info.push(m), warn: (m: string) => sink.warn.push(m) },
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
  return { vm, session, buffer, playback, loop, log, sink, run, time: () => now };
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

  it('VM slower than real time: the head holds with no measured rate, then re-arms once the last frame arrived and is shown', async () => {
    t.loop.release({ x: -150, y: -150 });
    let frame = 0;
    // 20 frames per second and no chunk report yet: the head holds at the release frame.
    t.run(2500, () => {
      if (++frame % 3 === 0) t.vm.emit(1);
      expect(t.playback.position).toBe(0);
      expect(t.playback.speed).toBe(0);
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

/**
 * A worker that runs the chunks of `plan` at `stepsPerSecond` of VM speed, on the test's clock: a
 * chunk's frames and report land when its wall time (steps / speed) has elapsed. Returns the
 * per-display-frame step for `run`'s `each`; the shot ends after the last chunk.
 */
function worker(t: Awaited<ReturnType<typeof setup>>, plan: { ticks: number; stepsPerTick: number }[], stepsPerSecond: number) {
  const queue = [...plan];
  let budget = 0; // ms of VM time banked
  let finished = false;
  return () => {
    if (finished) return;
    budget += 1000 / 60;
    for (let c = queue[0]; c !== undefined; c = queue[0]) {
      const steps = c.ticks * c.stepsPerTick;
      const ms = (steps / stepsPerSecond) * 1000;
      if (budget < ms) return;
      budget -= ms;
      queue.shift();
      t.vm.chunk(c.ticks, steps, ms);
    }
    t.vm.finish();
    finished = true;
  };
}

/** A shot of `total` ticks: flight chunks of 65k steps per tick, then `rest` of the given plan. */
const FLIGHT = 65_000;
const flight = (ticks: number) => [{ ticks, stepsPerTick: FLIGHT }];

describe('ShotLoop: compute ahead, then real time (lot CB)', () => {
  it('holds at the release: speed 0, head still, with no rate to price the shot', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    t.run(500);
    expect(t.playback.speed).toBe(0);
    expect(t.playback.position).toBe(0);
    expect(t.loop.producing && t.playback.speed < 1).toBe(true); // what `#simulating` shows
  });

  it('never stalls once started: the head advances by dt x 60 on every advance, with the lead kept', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    // A fast machine (60M steps/s): the whole shot is produced in well under real time.
    const work = worker(t, [...flight(20), { ticks: 130, stepsPerTick: 150_000 }], 60e6);
    let started = false;
    let moved = 0;
    for (let i = 0; i < 400; i++) {
      work();
      await Promise.resolve(); // the worker's result message lands before the next display frame
      const before = t.playback.position;
      t.run(1000 / 60 - 1e-9);
      if (t.playback.speed === 1) started = true;
      if (started && before < t.playback.lastFrame && t.playback.position < t.playback.lastFrame) {
        // the display frame is 1000/60 ms: one tick, whatever the lead
        expect(t.playback.position - before).toBeCloseTo(1, 6);
        moved++;
      }
      if (started) expect(t.playback.speed).toBe(1);
    }
    expect(started).toBe(true);
    expect(moved).toBeGreaterThan(100);
    expect(t.loop.dryEvents).toBe(0);
    expect(t.sink.warn).toEqual([]);
    expect(t.loop.armed).toBe(true);
  });

  it('15x stress: priced at the prior, the rule does not start at the release; the impact then runs dry, the head waits at speed 1 and the event is logged', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    t.run(200);
    expect(t.playback.speed).toBe(0); // nothing measured yet
    // A fast machine for the flight, an impact 15x dearer per tick than the flight, which the prior (10x) did not expect.
    const work = worker(t, [...flight(20), { ticks: 130, stepsPerTick: 15 * FLIGHT }], 40e6);
    const speeds = new Set<number>();
    for (let i = 0; i < 600; i++) {
      work();
      await Promise.resolve();
      t.run(1000 / 60 - 1e-9);
      if (t.loop.producing && t.playback.speed > 0) speeds.add(t.playback.speed);
    }
    expect([...speeds]).toEqual([1]); // started once, never slow motion
    expect(t.loop.dryEvents).toBeGreaterThanOrEqual(1);
    expect(t.sink.warn.length).toBe(t.loop.dryEvents);
    expect(t.sink.warn[0]).toMatch(/lead ran dry at \d+ ms: \d+ ticks produced of ~180 expected, head at \d+\.\d, \d+\.\d\dM steps\/s, flight 65000 steps\/tick/);
    await t.loop.settled;
    expect(t.loop.armed).toBe(true); // it caught up in the end
  });

  it('15x stress on a slower machine: the flight alone does not start it', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    const work = worker(t, [...flight(20), { ticks: 130, stepsPerTick: 15 * FLIGHT }], 13e6);
    for (let i = 0; i < 40; i++) {
      work();
      await Promise.resolve();
      t.run(1000 / 60 - 1e-9);
    }
    expect(t.playback.speed).toBe(0);
    expect(t.playback.position).toBe(0);
  });

  it('a slow impact followed by a fast settle: no dry event', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    const work = worker(
      t,
      [...flight(30), { ticks: 20, stepsPerTick: 300_000 }, { ticks: 100, stepsPerTick: 40_000 }],
      26e6,
    );
    for (let i = 0; i < 600; i++) {
      work();
      await Promise.resolve();
      t.run(1000 / 60 - 1e-9);
    }
    await t.loop.settled;
    expect(t.loop.dryEvents).toBe(0);
    expect(t.sink.warn).toEqual([]);
    expect(t.loop.armed).toBe(true);
    expect(t.sink.info.length).toBe(3);
    expect(t.sink.info[0]).toMatch(/^chunk 0: 30 ticks, 1950000 steps, [\d.]+ ms$/);
    expect(t.sink.info[1]).toMatch(/\(contact\)$/);
  });

  it('production ending while still holding: the hold releases at once and the end check fires', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    t.vm.chunk(20, 20 * FLIGHT, 400); // 3.25M steps/s: far too slow to start
    t.run(100);
    expect(t.playback.speed).toBe(0);
    t.vm.finish();
    await t.loop.settled;
    t.run(100);
    expect(t.playback.speed).toBe(1);
    expect(t.playback.position).toBeGreaterThan(0);
    t.run(3000);
    expect(t.loop.armed).toBe(true);
    expect(t.loop.dryEvents).toBe(0);
  });

  it('a shot that fails during the hold: the hold clears', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    t.run(100);
    t.vm.fail();
    await t.loop.settled;
    t.run(100);
    expect(t.playback.speed).toBe(1);
    expect(t.loop.armed).toBe(true);
    expect(t.log.map((l) => l.split('@')[0])).toEqual(['released', 'failed']);
  });

  it('dispose during the hold: nothing moves and a late chunk report is ignored', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    t.run(100);
    t.loop.dispose();
    t.vm.chunk(20, 20 * FLIGHT, 20);
    t.run(500);
    expect(t.playback.position).toBe(0);
    expect(t.sink.info).toEqual([]);
    t.vm.finish();
    await t.loop.settled;
    expect(t.log.map((l) => l.split('@')[0])).toEqual(['released']);
  });

  it('a second shot that starts with the head at the last frame holds again from there', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    t.vm.finish();
    await t.loop.settled;
    t.run(3000);
    expect(t.loop.armed).toBe(true);
    const end = t.playback.lastFrame;
    expect(t.playback.position).toBe(end);
    expect(t.loop.release({ x: -150, y: -150 })).toBe(true);
    t.run(300);
    expect([t.playback.speed, t.playback.position]).toEqual([0, end]);
    expect(t.loop.dryEvents).toBe(0); // holding on the last frame is not a dry lead
    t.vm.finish();
    await t.loop.settled;
    t.run(3000);
    expect(t.loop.armed).toBe(true);
  });

  it('a second shot starts early when the lead allows it: shown ticks count from this shot, not from the buffer start', async () => {
    const t = await setup({ shotTicks: 150 });
    t.loop.release({ x: -604, y: -392 });
    t.vm.finish();
    await t.loop.settled;
    t.run(3000);
    expect(t.loop.armed).toBe(true);
    const base = t.playback.position; // the previous shot's last frame
    expect(base).toBeGreaterThan(100);
    t.loop.release({ x: -150, y: -150 });
    // At 40M steps/s the prior (130 x 650k steps = 2.6 s) fits the 3 s of the whole shot after the first chunk,
    // but not the ~0.5 s that an absolute frame index would leave (150 of 180 already 'shown').
    const work = worker(t, [...flight(20), ...Array.from({ length: 13 }, () => ({ ticks: 10, stepsPerTick: 150_000 }))], 40e6);
    let startedWhileProducing = false;
    for (let i = 0; i < 400; i++) {
      work();
      await Promise.resolve();
      t.run(1000 / 60 - 1e-9);
      // started on the first chunk (20 ticks); an absolute frame index only starts at ~50 produced
      if (t.playback.speed === 1 && t.buffer.frameCount - 1 - base <= 30) startedWhileProducing = true;
    }
    expect(startedWhileProducing).toBe(true);
    expect(t.loop.dryEvents).toBe(0);
    expect(t.loop.armed).toBe(true);
  });

  it('pause and scrub during the hold: the head stays where it is put, and plays on from there once started', async () => {
    const t = await setup({ shotTicks: 150 });
    // Frames of an earlier shot to scrub in: a first shot, shown.
    t.loop.release({ x: -604, y: -392 });
    t.vm.finish();
    await t.loop.settled;
    t.run(3000);
    t.loop.release({ x: -150, y: -150 });
    t.playback.playing = false;
    t.playback.seek(20);
    t.run(500);
    expect(t.playback.position).toBe(20);
    t.playback.playing = true;
    t.run(100);
    expect(t.playback.position).toBe(20); // still holding: no rate
    t.vm.finish();
    await t.loop.settled;
    t.run(100);
    expect(t.playback.position).toBeGreaterThan(20);
    expect(t.loop.dryEvents).toBe(0);
  });
});

describe('ShotLoop: the proof is unchanged', () => {
  /** A shot with chunk reports, then one without any: the same fire arguments and frames in the buffer. */
  async function play(withChunks: boolean) {
    const vm = new StreamVm();
    vm.shotTicks = 10;
    const session = await LevelSession.open(vm, { felts: ['1', '2', '0', '0', '3', '180'] });
    const pushed: TraceFrame[] = [];
    const sink = { push: (f: TraceFrame) => void pushed.push(f), get frameCount() { return pushed.length; } };
    const buffer = sink as unknown as ConstructorParameters<typeof ShotLoop>[1];
    const loop = new ShotLoop(session, buffer, new Playback(() => pushed.length), {}, () => 0, { info: () => {}, warn: () => {} });
    loop.release({ x: -604, y: -392 });
    if (withChunks) {
      vm.chunk(4, 4 * FLIGHT, 10);
      vm.chunk(6, 6 * FLIGHT * 3, 10);
    }
    vm.finish();
    await loop.settled;
    return { vm, pushed };
  }

  it('fires with the same arguments as before (plus an onChunk handler) and pushes the same frames in order', async () => {
    const a = await play(true);
    const b = await play(false);
    const expected = {
      level: { felts: ['1', '2', '0', '0', '3', '180'] },
      inputs: { player: expect.any(String), shots: [{ pull_x: -604, pull_y: -392, delay: 0 }] },
      shot: 0,
      state: header(0, false, 0),
    };
    expect(a.vm.requests).toEqual([{ request: expected, handlerKeys: ['onChunk', 'onEvent', 'onFrame'] }]);
    expect(b.vm.requests).toEqual(a.vm.requests);
    expect(a.pushed.map((f) => f.tick)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(a.pushed).toEqual(b.pushed);
  });
});
