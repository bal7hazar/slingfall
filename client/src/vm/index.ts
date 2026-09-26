// Page side of the cairo-vm worker (docs/DESIGN.md D8): one persistent worker per page, loaded
// once, running `init`, chunked shots and the outputs; `WorkerTraceSource` streams a shot's
// frames and events to the renderer.
import type { TraceSource } from '../trace/source';
import type { TraceEvent, TraceFrame, TraceLevel } from '../trace/types';
import type { FromWorker, LoadRequest, Loaded, ShotRequest, ToWorker } from './protocol';
import type { ChunkReport, ShotResult } from './shot';

export type { ChunkSizing } from './sizing';
export { DEFAULT_SIZING, planChunk } from './sizing.ts';
export type { BallDropLevel, ChunkProgram, SlingfallInputs, SlingfallLevel } from './program';
export { ballDropProgram, slingfallProgram } from './program.ts';
export type { ChunkReport, ShotResult } from './shot';
export type { LoadRequest, Loaded, ShotRequest } from './protocol';

/** The ends of a worker the client uses (a `Worker`, or an in-process stand-in in tests). */
export interface WorkerPort {
  postMessage(message: ToWorker): void;
  onmessage: ((event: { data: FromWorker }) => void) | null;
  terminate(): void;
}

/** Where the app is served (`base` of `vite.config.ts`: `/`, or `/<repo>/` on GitHub Pages); `/` under Node. */
const BASE: string = import.meta.env?.BASE_URL ?? '/';

/**
 * The slingfall replay (lot G4) as the app serves it: `npm run dev` from the client root,
 * `npm run build` copies both directories into `dist/vm/` (`vite.config.ts`). The wasm exists
 * once `client/vm/scripts/build.sh` has run; the executables are committed.
 */
export const DEFAULT_LOAD: LoadRequest = {
  pkgUrl: `${BASE}vm/pkg/slingfall_vm_runner.js`,
  executableUrl: `${BASE}vm/fixtures/replay/step_chunk.executable.json`,
  initExecutableUrl: `${BASE}vm/fixtures/replay/init.executable.json`,
  outputsExecutableUrl: `${BASE}vm/fixtures/replay/outputs.executable.json`,
  program: 'slingfall',
};

/** The ball_drop stand-in of lot G1c. */
export const BALL_DROP_LOAD: LoadRequest = {
  pkgUrl: `${BASE}vm/pkg/slingfall_vm_runner.js`,
  executableUrl: `${BASE}vm/fixtures/ball_drop.executable.json`,
  program: 'ball_drop',
};

/** A module Web Worker running `worker.ts`. */
export function spawnVmWorker(): WorkerPort {
  return new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' }) as unknown as WorkerPort;
}

export interface ShotHandlers {
  onFrame?: (frame: TraceFrame) => void;
  onEvent?: (event: TraceEvent) => void;
  onChunk?: (chunk: ChunkReport) => void;
  onLine?: (line: string) => void;
}

interface Pending extends ShotHandlers {
  resolve: (result: ShotResult) => void;
  reject: (error: Error) => void;
}

type Request = ToWorker extends infer T ? (T extends { id: number } ? Omit<T, 'id'> : never) : never;

/** A persistent VM worker: loads the wasm and the executables once, then runs requests in order. */
export class VmClient {
  readonly ready: Promise<Loaded>;
  private readonly port: WorkerPort;
  private readonly pending = new Map<number, Pending>();
  private nextId = 1;

  constructor(port: WorkerPort = spawnVmWorker(), load: LoadRequest = DEFAULT_LOAD) {
    this.port = port;
    let loaded!: (l: Loaded) => void;
    let failed!: (e: Error) => void;
    this.ready = new Promise((resolve, reject) => {
      loaded = resolve;
      failed = reject;
    });
    port.onmessage = ({ data }) => {
      if (data.type === 'loaded') return loaded({ ms: data.ms, wasmBytes: data.wasmBytes });
      if (data.id === undefined) return failed(new Error(data.type === 'error' ? data.message : data.type));
      const request = this.pending.get(data.id);
      if (request === undefined) return;
      switch (data.type) {
        case 'frame':
          return request.onFrame?.(data.frame);
        case 'event':
          return request.onEvent?.(data.event);
        case 'line':
          return request.onLine?.(data.line);
        case 'chunk':
          return request.onChunk?.(data.chunk);
        case 'done':
          this.pending.delete(data.id);
          return request.resolve(data.result);
        case 'error':
          this.pending.delete(data.id);
          return request.reject(new Error(data.message));
      }
    };
    port.postMessage({ type: 'load', ...load });
  }

  /** `init(level)`: the state before the first shot; the level header lines go to `onLine`. */
  init(level: unknown, handlers: ShotHandlers = {}): Promise<ShotResult> {
    return this.send({ type: 'init', level }, handlers);
  }

  /** Runs one chunked shot; handlers fire while it runs, the promise settles at its end. */
  shot(request: ShotRequest, handlers: ShotHandlers = {}): Promise<ShotResult> {
    return this.send({ type: 'shot', ...request }, handlers);
  }

  /** The outputs of a finished level (`result.state` holds their felts). */
  outputs(state: string[], inputs: unknown): Promise<ShotResult> {
    return this.send({ type: 'outputs', state, inputs }, {});
  }

  terminate() {
    this.port.terminate();
    for (const request of this.pending.values()) request.reject(new Error('VM worker terminated'));
    this.pending.clear();
  }

  private send(request: Request, handlers: ShotHandlers): Promise<ShotResult> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { ...handlers, resolve, reject });
      this.port.postMessage({ ...request, id } as ToWorker);
    });
  }
}

export interface WorkerTraceOptions {
  /**
   * The level as the renderer draws it (from `init`'s header lines, `LevelHeader`, or the
   * page's own copy).
   */
  level: TraceLevel;
  onChunk?: (chunk: ChunkReport) => void;
}

/** Frames and events of one shot, streamed from the VM worker as the chunks run. */
export class WorkerTraceSource implements TraceSource {
  readonly kind = 'worker';
  /** Game events received so far (trace lines v1: damage, destroyed, score, shot_end). */
  readonly events: TraceEvent[] = [];
  /** Settles with the shot's final state and chunk reports once `frames()` has run. */
  result: Promise<ShotResult> | null = null;
  private readonly client: VmClient;
  private readonly request: ShotRequest;
  private readonly options: WorkerTraceOptions;

  constructor(client: VmClient, request: ShotRequest, options: WorkerTraceOptions) {
    this.client = client;
    this.request = request;
    this.options = options;
  }

  async level(): Promise<TraceLevel> {
    return this.options.level;
  }

  async *frames(): AsyncIterable<TraceFrame> {
    const queue: TraceFrame[] = [];
    let wake: (() => void) | null = null;
    let settled = false;
    let failure: Error | null = null;
    const notify = () => wake?.();
    this.result = this.client.shot(this.request, {
      onFrame: (frame) => {
        queue.push(frame);
        notify();
      },
      onEvent: (event) => this.events.push(event),
      onChunk: this.options.onChunk,
    });
    this.result.then(
      () => {
        settled = true;
        notify();
      },
      (e: Error) => {
        failure = e;
        settled = true;
        notify();
      },
    );
    let next = 0;
    for (;;) {
      while (next < queue.length) yield queue[next++];
      if (settled) {
        if (failure !== null) throw failure;
        return;
      }
      await new Promise<void>((resolve) => (wake = resolve));
      wake = null;
    }
  }
}
