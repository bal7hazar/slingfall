// Runs the real cairo-vm wasm (`client/vm/pkg-node/`, built by `client/vm/scripts/build.sh`) on
// the ball_drop stand-in and on the slingfall replay (lot G4's executables, committed under
// `client/vm/fixtures/replay/`); skipped when that build is absent (the plain `client` CI job).
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { beforeAll, describe, expect, it } from 'vitest';
import { LevelSession } from '../game/session';
import { linesToTrace } from '../trace/lines';
import type { TraceEvent, TraceFrame, TraceLevel } from '../trace/types';
import { BALL_DROP_LOAD, VmClient, WorkerTraceSource, type WorkerPort } from './index';
import { DEFAULT_PLAYER, ballDropProgram, decodeOutputs, readChunkHeader, type BallDropLevel, type SlingfallInputs } from './program';
import { serveVm, type WorkerScope } from './serve';
import { engineFromModule, runShot, type ChunkReport, type RunnerModule, type VmEngine } from './shot';

const vm = (path: string) => fileURLToPath(new URL(`../../vm/${path}`, import.meta.url));
const PKG_NODE = vm('pkg-node/slingfall_vm_runner.js');
const hasPkg = existsSync(PKG_NODE);

const PILE12: BallDropLevel = { scene: 3, ticks: 120 };
/** `mode 3` (one uninterrupted 120-tick world, then saved), from the native `slingfall-run`. */
const golden = () => readFileSync(vm('fixtures/pile12-mode3-120.state.txt'), 'utf8').trim().split(' ');

/** ball_drop as the renderer would draw it: a ground half-space and the ball (handle 0). */
const BALL_DROP_TRACE_LEVEL: TraceLevel = {
  bounds: { min_x: '-42949672960', min_y: '-4294967296', max_x: '42949672960', max_y: '42949672960' },
  sling_anchor: { x: '0', y: '0' },
  gravity_y: '-42133629174',
  launch_scale: '4294967296',
  pull_radius: 1024,
  shots: 1,
  bodies: [
    {
      handle: 1,
      kind: 'static',
      material: 'ground',
      shape: { type: 'halfspace', normal: { x: '0', y: '4294967296' } },
      pose: { x: '0', y: '0', re: '4294967296', im: '0' },
    },
  ],
};

/** A worker served in-process: messages cross as structured clones, in order, asynchronously. */
function inProcessWorker(engine: VmEngine): WorkerPort {
  const port: WorkerPort = {
    onmessage: null,
    postMessage: (m) => setTimeout(() => scope.onmessage?.({ data: structuredClone(m) })),
    terminate: () => {},
  };
  const scope: WorkerScope = {
    onmessage: null,
    postMessage: (m) => setTimeout(() => port.onmessage?.({ data: structuredClone(m) })),
  };
  serveVm(scope, async () => engine);
  return port;
}

describe.skipIf(!hasPkg)('cairo-vm wasm (pkg-node)', () => {
  let engine: VmEngine;

  beforeAll(() => {
    const mod = createRequire(import.meta.url)(PKG_NODE) as RunnerModule;
    engine = engineFromModule(mod, readFileSync(vm('fixtures/ball_drop.executable.json'), 'utf8'));
  });

  it.each([5, 10, 30])(
    'pile12, 120 ticks chained by K = %i, ends on the mode 3 state felt for felt',
    (k) => {
      const shot = runShot(engine, ballDropProgram, PILE12, null, { fixedTicks: k });
      expect(shot.chunks.slice(1).map((c) => c.ticks)).toEqual(
        Array.from({ length: Math.ceil(120 / k) }, (_, i) => Math.min(k, 120 - i * k)),
      );
      expect(shot.state).toEqual(golden());
    },
    180_000,
  );

  it(
    'pile12 with the sizing rule: bit-exact, ticks streamed in order, chunk by chunk',
    () => {
      const events: (TraceFrame | ChunkReport)[] = [];
      const shot = runShot(engine, ballDropProgram, PILE12, null, {
        onFrame: (f) => events.push(f),
        onChunk: (c) => events.push(c),
      });
      expect(shot.state).toEqual(golden());

      const frames = events.filter((e): e is TraceFrame => 'bodies' in e);
      expect(frames.map((f) => f.tick)).toEqual(Array.from({ length: 120 }, (_, i) => i + 1));
      // Each chunk report follows exactly the frames of its own ticks.
      let tick = 0;
      let pending = 0;
      for (const e of events) {
        if ('bodies' in e) {
          pending++;
          expect(e.tick).toBe(++tick);
        } else {
          expect(pending).toBe(e.ticks);
          pending = 0;
        }
      }
      // Step-budgeted: after the first chunk, every chunk but the last aims at 2-5M steps.
      const stepping = shot.chunks.slice(1);
      expect(stepping[0].ticks).toBe(5);
      for (const c of stepping.slice(1, -1)) {
        expect(c.steps).toBeGreaterThan(1_500_000);
        expect(c.steps).toBeLessThan(6_000_000);
      }
      expect(stepping.reduce((a, c) => a + c.ticks, 0)).toBe(120);
      // The reserve covers every chunk: the execution segment never doubles.
      for (const c of stepping) expect(c.execCells).toBeLessThanOrEqual(c.reserveCells);
    },
    180_000,
  );

  it('WorkerTraceSource streams a shot through the worker protocol', async () => {
    const level: BallDropLevel = { scene: 0, ticks: 60 };
    const client = new VmClient(inProcessWorker(engine), BALL_DROP_LOAD);
    await client.ready;
    const chunks: ChunkReport[] = [];
    const source = new WorkerTraceSource(
      client,
      { level, inputs: null, fixedTicks: 7 },
      { level: BALL_DROP_TRACE_LEVEL, onChunk: (c) => chunks.push(c) },
    );
    const ticks: number[] = [];
    for await (const frame of source.frames()) ticks.push(frame.tick);

    expect(source.kind).toBe('worker');
    expect(await source.level()).toBe(BALL_DROP_TRACE_LEVEL);
    expect(source.events).toEqual([]);
    expect(ticks).toEqual(Array.from({ length: 60 }, (_, i) => i + 1));
    expect(chunks.map((c) => c.ticks)).toEqual([0, 7, 7, 7, 7, 7, 7, 7, 7, 4]);
    const direct = runShot(engine, ballDropProgram, level, null, { fixedTicks: 60 });
    expect((await source.result)?.state).toEqual(direct.state);
  });

  it('reports errors of a shot and of a load', async () => {
    const client = new VmClient(inProcessWorker(engine), BALL_DROP_LOAD);
    await client.ready;
    // Scene 9 does not exist: the Cairo assert aborts the run.
    await expect(client.shot({ level: { scene: 9, ticks: 1 }, inputs: null })).rejects.toThrow();
    const bad = new VmClient(inProcessWorker(engine), { ...BALL_DROP_LOAD, program: 'nope' });
    await expect(bad.ready).rejects.toThrow('unknown program nope');
  });
});

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const replay = (name: string) => readFileSync(vm(`fixtures/replay/${name}.executable.json`), 'utf8');
/** `main_trace` on pile10 with the reference shot, as `scarb execute` printed it (natively). */
const RECORDED = () => readFileSync(vm('fixtures/pile10-reference.main_trace.txt'), 'utf8');
const PILE10 = { felts: JSON.parse(readFileSync(root('fixtures/levels/pile10.felts.json'), 'utf8')).felts as string[] };
const REFERENCE: SlingfallInputs = { player: DEFAULT_PLAYER, shots: [{ pull_x: -600, pull_y: -392 }] };

describe.skipIf(!hasPkg)('slingfall replay on cairo-vm wasm (pkg-node)', () => {
  let engine: VmEngine;

  beforeAll(() => {
    const mod = createRequire(import.meta.url)(PKG_NODE) as RunnerModule;
    engine = engineFromModule(mod, replay('step_chunk'), { init: replay('init'), outputs: replay('outputs') });
  });

  it(
    'pile10, reference shot through WorkerTraceSource: the frames, events and outputs of main_trace',
    async () => {
      const client = new VmClient(inProcessWorker(engine));
      await client.ready;
      const expected = linesToTrace(RECORDED().split('\n'));

      // init once: its header lines are the level main_trace prints.
      const headerLines: string[] = [];
      const init = await client.init(PILE10, { onLine: (l) => headerLines.push(l) });
      expect(linesToTrace(headerLines).level).toEqual(expected.level);
      expect(readChunkHeader(init.state)).toMatchObject({ shotsUsed: 0, over: false, tick: 0, score: 0 });

      const chunks: ChunkReport[] = [];
      const t0 = performance.now();
      const source = new WorkerTraceSource(
        client,
        { level: PILE10, inputs: REFERENCE, shot: 0, state: init.state },
        { level: expected.level, onChunk: (c) => chunks.push(c) },
      );
      const frames: TraceFrame[] = [];
      // The in-process worker runs on this thread: frames arrive after each run, so the first
      // frame's latency is `bench.mjs slingfall`'s figure, not this test's.
      for await (const frame of source.frames()) frames.push(frame);
      const shotMs = performance.now() - t0;
      const result = (await source.result)!;

      // Bit-exact with the uninterrupted native run: every frame and every event.
      expect(frames).toEqual(expected.frames.slice(1));
      expect(source.events).toEqual(expected.events as TraceEvent[]);
      expect(readChunkHeader(result.state)).toMatchObject({ shotsUsed: 1, over: true, tick: 191, score: 5350 });

      const t1 = performance.now();
      const outputs = await client.outputs(result.state, REFERENCE);
      const outputsMs = performance.now() - t1;
      const recordedOutputs = RECORDED().split('Program output:')[1].trim().split(/\s+/).slice(1);
      expect(outputs.state).toEqual(recordedOutputs);
      expect(decodeOutputs(outputs.state)).toMatchObject({ won: '1', score: '5350', ticks_run: '191' });

      const peak = Math.max(...chunks.map((c) => c.wasmBytes)) / 2 ** 20;
      console.log(
        `pile10 reference shot: ${(shotMs / 1000).toFixed(2)} s, ` +
          `${(result.steps / 1e6).toFixed(2)}M steps (${(result.steps / result.chunks.reduce((a, c) => a + c.ms, 0) / 1000).toFixed(2)}M steps/s), ` +
          `${chunks.length} chunks [${chunks.map((c) => c.ticks).join(' ')}], peak wasm ${peak.toFixed(0)} MB; ` +
          `init ${init.steps} steps in ${init.ms.toFixed(0)} ms; outputs ${outputs.steps} steps in ${outputsMs.toFixed(0)} ms`,
      );
    },
    180_000,
  );

  it(
    'the game session plays pile10 three shots in the worker (two weak, then the reference)',
    async () => {
      const client = new VmClient(inProcessWorker(engine));
      await client.ready;
      const session = await LevelSession.open(client, PILE10);
      const ticks: number[] = [];
      const onFrame = (f: TraceFrame) => ticks.push(f.tick);
      await session.fire({ x: -150, y: -150 }, { onFrame });
      expect(session.header).toMatchObject({ shotsUsed: 1, over: false, score: 0 });
      await session.fire({ x: -200, y: -200 }, { onFrame });
      await session.fire({ x: -600, y: -392 }, { onFrame });
      expect(session.phase).toBe('over');
      // Frames of the whole level, one per tick, across the three shots.
      expect(ticks).toEqual(Array.from({ length: session.header.tick }, (_, i) => i + 1));
      const result = session.result()!;
      const outputs = await session.outputs();
      expect(outputs).toMatchObject({
        won: result.won ? '1' : '0',
        score: String(result.score),
        shots_used: '3',
        ticks_run: String(result.ticks),
      });
      console.log(
        `pile10 three shots: ${session.reports.map((r) => `${r.ticks} ticks ${(r.steps / 1e6).toFixed(1)}M steps ${(r.ms / 1000).toFixed(1)} s`).join(', ')}; ` +
          `score ${result.score}, won ${result.won}`,
      );
    },
    300_000,
  );
});
