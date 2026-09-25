// Messages between the page and the VM worker (structured-clone safe).
import type { TraceEvent, TraceFrame } from '../trace/types';
import type { ChunkSizing } from './sizing';
import type { ChunkReport, ShotResult } from './shot';

/** Where the worker loads its wasm and executables from, and which program drives them. */
export interface LoadRequest {
  /** URL of the wasm-bindgen `--target web` module (`client/vm/pkg/slingfall_vm_runner.js`). */
  pkgUrl: string;
  /** URL of scarb's `executable.json` of `step_chunk` (and of every entry without its own URL). */
  executableUrl: string;
  /** `init`'s executable, when it is not `executableUrl`. */
  initExecutableUrl?: string;
  /** The `outputs` executable, when the program has one. */
  outputsExecutableUrl?: string;
  /** A key of `PROGRAMS` (`program.ts`). */
  program: string;
}

export interface ShotRequest {
  level: unknown;
  inputs: unknown;
  /** 0-based shot index (default 0). */
  shot?: number;
  /** State to start from (the previous shot's, or `init`'s); `init` runs first when absent. */
  state?: string[];
  sizing?: ChunkSizing;
  fixedTicks?: number;
}

export interface InitRequest {
  level: unknown;
}

export interface OutputsRequest {
  state: string[];
  inputs: unknown;
}

export type ToWorker =
  | ({ type: 'load' } & LoadRequest)
  | ({ type: 'shot'; id: number } & ShotRequest)
  | ({ type: 'init'; id: number } & InitRequest)
  | ({ type: 'outputs'; id: number } & OutputsRequest);

export interface Loaded {
  /** Instantiating the wasm plus fetching and parsing the executables, ms. */
  ms: number;
  wasmBytes: number;
}

export type FromWorker =
  | ({ type: 'loaded' } & Loaded)
  | { type: 'frame'; id: number; frame: TraceFrame }
  | { type: 'event'; id: number; event: TraceEvent }
  | { type: 'line'; id: number; line: string }
  | { type: 'chunk'; id: number; chunk: ChunkReport }
  /** The end of any request: the state (`returned` of the last run) and the run reports. */
  | { type: 'done'; id: number; result: ShotResult }
  /** `id` is absent for a load failure. */
  | { type: 'error'; id?: number; message: string };
