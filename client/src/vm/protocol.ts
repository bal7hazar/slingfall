// Messages between the page and the VM worker (structured-clone safe).
import type { TraceFrame } from '../trace/types';
import type { ChunkSizing } from './sizing';
import type { ChunkReport, ShotResult } from './shot';

/** Where the worker loads its wasm and executable from, and which program drives it. */
export interface LoadRequest {
  /** URL of the wasm-bindgen `--target web` module (`client/vm/pkg/slingfall_vm_runner.js`). */
  pkgUrl: string;
  /** URL of scarb's `executable.json`. */
  executableUrl: string;
  /** A key of `PROGRAMS` (`program.ts`). */
  program: string;
}

export interface ShotRequest {
  level: unknown;
  inputs: unknown;
  sizing?: ChunkSizing;
  fixedTicks?: number;
}

export type ToWorker =
  | ({ type: 'load' } & LoadRequest)
  | ({ type: 'shot'; id: number } & ShotRequest);

export interface Loaded {
  /** Instantiating the wasm plus fetching and parsing the executable, ms. */
  ms: number;
  wasmBytes: number;
}

export type FromWorker =
  | ({ type: 'loaded' } & Loaded)
  | { type: 'frame'; id: number; frame: TraceFrame }
  | { type: 'line'; id: number; line: string }
  | { type: 'chunk'; id: number; chunk: ChunkReport }
  | { type: 'done'; id: number; result: ShotResult }
  /** `id` is absent for a load failure. */
  | { type: 'error'; id?: number; message: string };
