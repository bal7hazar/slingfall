// Runs the real cairo-vm wasm (`client/vm/pkg-node/`, built by `client/vm/scripts/build.sh`) on
// the ball_drop stand-in; skipped when that build is absent (the plain `client` CI job).
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { beforeAll, describe, expect, it } from 'vitest';
import type { TraceFrame, TraceLevel } from '../trace/types';
import { VmClient, WorkerTraceSource, type WorkerPort } from './index';
import { ballDropProgram, type BallDropLevel } from './program';
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
    const client = new VmClient(inProcessWorker(engine));
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
    const client = new VmClient(inProcessWorker(engine));
    await client.ready;
    // Scene 9 does not exist: the Cairo assert aborts the run.
    await expect(client.shot({ level: { scene: 9, ticks: 1 }, inputs: null })).rejects.toThrow();
    const bad = new VmClient(inProcessWorker(engine), { pkgUrl: '', executableUrl: '', program: 'nope' });
    await expect(bad.ready).rejects.toThrow('unknown program nope');
  });
});
