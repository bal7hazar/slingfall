import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { TraceEvent, TraceFrame } from '../trace/types';
import type { ShotHandlers, ShotRequest } from '../vm/index';
import { DEFAULT_PLAYER, type SlingfallInputs } from '../vm/program';
import type { ShotResult } from '../vm/shot';
import { LevelSession, coresDestroyed, inputsJson, type GameVm } from './session';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const LINES = readFileSync(root('client/vm/fixtures/pile10-reference.main_trace.txt'), 'utf8').split('\n');
const HEADER = LINES.filter((l) => /^(trace|level|material|body) /.test(l));
const LEVEL = { felts: ['1', '2', '0'] };
const CORE = 10;

const header = (shotsUsed: number, over: boolean, tick: number, score: number) =>
  ['1', String(shotsUsed), over ? '1' : '0', '0', '0', String(tick), String(score), 'world'];
const result = (state: string[]): ShotResult => ({ state, chunks: [], steps: 1000, ms: 1 });

/**
 * A scripted worker: each shot plays 3 ticks; the shot listed in `winsAt` destroys the core.
 * Requests are recorded.
 */
class FakeVm implements GameVm {
  readonly requests: ShotRequest[] = [];
  outputsRuns = 0;
  failNext = false;
  private readonly winsAt: number;

  constructor(winsAt = -1) {
    this.winsAt = winsAt;
  }

  async init(_level: unknown, handlers: ShotHandlers = {}): Promise<ShotResult> {
    for (const line of ['   Executing slingfall_replay', ...HEADER]) handlers.onLine?.(line);
    return result(header(0, false, 0, 0));
  }

  async shot(request: ShotRequest, handlers: ShotHandlers = {}): Promise<ShotResult> {
    this.requests.push(structuredClone(request));
    if (this.failNext) {
      this.failNext = false;
      throw new Error('replay: shot');
    }
    const shot = request.shot!;
    const start = Number(request.state![5]);
    let score = Number(request.state![6]);
    const won = shot === this.winsAt;
    for (let t = start + 1; t <= start + 3; t++) {
      if (won && t === start + 2) {
        handlers.onEvent?.({ tick: t, kind: 'destroyed', handle: CORE });
        score += 1000;
        handlers.onEvent?.({ tick: t, kind: 'score', points: 1000, total: score });
      }
      handlers.onFrame?.({ tick: t, bodies: [] });
    }
    handlers.onEvent?.({ tick: start + 3, kind: 'shot_end', shot });
    const over = won || shot + 1 === 3;
    return result(header(shot + 1, over, start + 3, score));
  }

  async outputs(state: string[], inputs: unknown): Promise<ShotResult> {
    this.outputsRuns++;
    const player = (inputs as SlingfallInputs).player;
    return result(['1', 'lh', '0', player, 'ih', state[6], this.winsAt >= 0 ? '1' : '0', state[1], state[5], 'fh']);
  }
}

describe('LevelSession (fake engine)', () => {
  it('reads the level from init\'s header lines', async () => {
    const session = await LevelSession.open(new FakeVm(), LEVEL);
    expect(session.traceLevel.bodies).toHaveLength(11);
    expect(session.traceLevel.shots).toBe(3);
    expect(session.phase).toBe('aiming');
    expect(session.startFrame().tick).toBe(0);
  });

  it('plays shot after shot from the previous state, keeping the inputs, until the level is over', async () => {
    const vm = new FakeVm(1);
    const session = await LevelSession.open(vm, LEVEL);
    const frames: TraceFrame[] = [];
    const events: TraceEvent[] = [];
    const handlers = { onFrame: (f: TraceFrame) => frames.push(f), onEvent: (e: TraceEvent) => events.push(e) };

    const first = await session.fire({ x: -150, y: -150 }, handlers);
    expect(first).toMatchObject({ shot: 0, ticks: 3, steps: 1000 });
    expect(first.firstFrameMs).not.toBeNull();
    expect(session.phase).toBe('aiming');
    expect(session.result()).toBeNull();
    await expect(session.outputs()).rejects.toThrow('the level is not over');

    await session.fire({ x: -600, y: -392 }, handlers);
    expect(session.phase).toBe('over');
    await expect(session.fire({ x: 1, y: 1 })).rejects.toThrow('cannot shoot while over');

    // Shot 1 started from shot 0's state, with both shots in the inputs.
    expect(vm.requests.map((r) => [r.shot, r.state![5], (r.inputs as SlingfallInputs).shots.length])).toEqual([
      [0, '0', 1],
      [1, '3', 2],
    ]);
    expect(frames.map((f) => f.tick)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(session.events).toEqual(events);
    expect(session.result()).toEqual({ score: 1000, won: true, shotsUsed: 2, ticks: 6 });

    const outputs = await session.outputs();
    expect(outputs).toMatchObject({ player: DEFAULT_PLAYER, score: '1000', won: '1', shots_used: '2', ticks_run: '6' });
    await session.outputs();
    expect(vm.outputsRuns).toBe(1);
    expect(JSON.parse(inputsJson(session.inputs()))).toEqual({
      player: DEFAULT_PLAYER,
      shots: [
        { pull_x: -150, pull_y: -150, delay: 0 },
        { pull_x: -600, pull_y: -392, delay: 0 },
      ],
    });
  });

  it('loses after the level\'s shots without the core', async () => {
    const session = await LevelSession.open(new FakeVm(), LEVEL);
    for (let i = 0; i < 3; i++) await session.fire({ x: -100, y: -100 });
    expect(session.result()).toEqual({ score: 0, won: false, shotsUsed: 3, ticks: 9 });
  });

  it('refuses a release while a shot is in flight', async () => {
    const session = await LevelSession.open(new FakeVm(), LEVEL);
    const flying = session.fire({ x: -100, y: -100 });
    expect(session.phase).toBe('flying');
    expect(() => session.reset()).toThrow('cannot reset while a shot is in flight');
    await expect(session.fire({ x: -100, y: -100 })).rejects.toThrow('cannot shoot while flying');
    await flying;
  });

  it('a failed shot leaves the state and the inputs as they were', async () => {
    const vm = new FakeVm();
    const session = await LevelSession.open(vm, LEVEL);
    vm.failNext = true;
    await expect(session.fire({ x: -100, y: -100 })).rejects.toThrow('replay: shot');
    expect(session.shots).toEqual([]);
    expect(session.phase).toBe('aiming');
    expect((await session.fire({ x: -100, y: -100 })).shot).toBe(0);
  });

  it('retry goes back to init\'s state without running init again', async () => {
    const vm = new FakeVm(0);
    const session = await LevelSession.open(vm, LEVEL);
    await session.fire({ x: -600, y: -392 });
    expect(session.phase).toBe('over');
    await session.outputs();
    session.reset();
    expect(session.phase).toBe('aiming');
    expect([session.shots, session.events, session.reports]).toEqual([[], [], []]);
    expect(session.header.tick).toBe(0);
    await session.fire({ x: -600, y: -392 });
    expect(vm.requests[1].state![5]).toBe('0');
    await session.outputs();
    expect(vm.outputsRuns).toBe(2);
  });

  it('won needs every core destroyed', async () => {
    const level = (await LevelSession.open(new FakeVm(), LEVEL)).traceLevel;
    expect(coresDestroyed(level, [])).toBe(false);
    expect(coresDestroyed(level, [{ tick: 3, kind: 'destroyed', handle: 9 }])).toBe(false);
    expect(coresDestroyed(level, [{ tick: 3, kind: 'destroyed', handle: CORE }])).toBe(true);
  });
});
