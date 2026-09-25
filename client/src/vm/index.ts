// Page side of the cairo-vm worker (docs/DESIGN.md D8): one persistent worker per page, loaded
// once, running chunked shots; `WorkerTraceSource` streams a shot's ticks to the renderer.
import type { TraceSource } from '../trace/source';
import type { TraceEvent, TraceFrame, TraceLevel } from '../trace/types';
import type { FromWorker, LoadRequest, Loaded, ShotRequest, ToWorker } from './protocol';
import type { ChunkReport, ShotResult } from './shot';

export type { ChunkSizing } from './sizing';
export { DEFAULT_SIZING, planChunk } from './sizing.ts';
export type { BallDropLevel, ChunkProgram } from './program';
export { ballDropProgram } from './program.ts';
export type { ChunkReport, ShotResult } from './shot';
export type { LoadRequest, Loaded, ShotRequest } from './protocol';

/** The ends of a worker the client uses (a `Worker`, or an in-process stand-in in tests). */
export interface WorkerPort {
  postMessage(message: ToWorker): void;
  onmessage: ((event: { data: FromWorker }) => void) | null;
  terminate(): void;
}

/**
 * Served by `npm run dev` from the client root once `client/vm/scripts/build.sh` has run. A
 * production build must copy `client/vm/pkg/` and the executable next to the app (lot G6b).
 */
export const DEFAULT_LOAD: LoadRequest = {
  pkgUrl: '/vm/pkg/slingfall_vm_runner.js',
  executableUrl: '/vm/fixtures/ball_drop.executable.json',
  program: 'ball_drop',
};

/** A module Web Worker running `worker.ts`. */
export function spawnVmWorker(): WorkerPort {
  return new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' }) as unknown as WorkerPort;
}

export interface ShotHandlers {
  onFrame?: (frame: TraceFrame) => void;
  onChunk?: (chunk: ChunkReport) => void;
  onLine?: (line: string) => void;
}

interface PendingShot extends ShotHandlers {
  resolve: (result: ShotResult) => void;
  reject: (error: Error) => void;
}

/** A persistent VM worker: loads the wasm and the executable once, then runs shots in order. */
export class VmClient {
  readonly ready: Promise<Loaded>;
  private readonly port: WorkerPort;
  private readonly shots = new Map<number, PendingShot>();
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
      const shot = this.shots.get(data.id);
      if (shot === undefined) return;
      switch (data.type) {
        case 'frame':
          return shot.onFrame?.(data.frame);
        case 'line':
          return shot.onLine?.(data.line);
        case 'chunk':
          return shot.onChunk?.(data.chunk);
        case 'done':
          this.shots.delete(data.id);
          return shot.resolve(data.result);
        case 'error':
          this.shots.delete(data.id);
          return shot.reject(new Error(data.message));
      }
    };
    port.postMessage({ type: 'load', ...load });
  }

  /** Runs one chunked shot; handlers fire while it runs, the promise settles at its end. */
  shot(request: ShotRequest, handlers: ShotHandlers = {}): Promise<ShotResult> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.shots.set(id, { ...handlers, resolve, reject });
      this.port.postMessage({ type: 'shot', id, ...request });
    });
  }

  terminate() {
    this.port.terminate();
    for (const shot of this.shots.values()) shot.reject(new Error('VM worker terminated'));
    this.shots.clear();
  }
}

export interface WorkerTraceOptions {
  /**
   * The level as the renderer draws it. The page knows the level it asks the worker to replay
   * (its JSON source); the executable does not print it.
   */
  level: TraceLevel;
  onChunk?: (chunk: ChunkReport) => void;
}

/** Frames of one shot, streamed from the VM worker as the chunks run. */
export class WorkerTraceSource implements TraceSource {
  readonly kind = 'worker';
  /**
   * Game events. None yet: the ball_drop stand-in prints ticks only; G4's observer adds them
   * through its `TickLineParser`.
   */
  readonly events: readonly TraceEvent[] = [];
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
