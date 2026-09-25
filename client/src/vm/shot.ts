// The chunked shot: `init(level)` once, then `step_chunk(state, inputs, k)` until the program
// says the shot is over, each chunk a fresh VM run on the same loaded executable (the worker
// and its wasm stay alive between chunks). Pure: no Worker, no DOM; the worker and the Node
// tests and benchmark all run it. Value imports carry `.ts` so that Node runs this file as is.
import type { TraceFrame } from '../trace/types';
import type { ChunkProgram } from './program';
import { DEFAULT_SIZING, planChunk, type ChunkMeasure, type ChunkSizing } from './sizing.ts';

/** Options of one run (the wasm `Runner.run` surface, client/vm/README.md). */
export interface RunOptions {
  reserveCells?: number;
  onPrint?: (text: string) => void;
}

/** What one run returned. */
export interface RunReport {
  steps: number;
  memoryCells: number;
  execCells: number;
  execCapacity: number;
  /** `main`'s `Array<felt252>`, decimal felts. */
  returned: string[];
}

/** The loaded executable (a wasm-bindgen `Runner`) plus the size of the wasm memory. */
export interface VmEngine {
  run(args: string, options: RunOptions): RunReport;
  /** Current size of the wasm linear memory in bytes (it only grows: the peak so far). */
  memoryBytes(): number;
}

/** The wasm-bindgen module surface used here (`pkg/` or `pkg-node/`). */
export interface RunnerModule {
  Runner: new (executableJson: string) => { run(args: string, options: RunOptions): RunReport };
  wasmMemoryBytes(): number;
}

export function engineFromModule(mod: RunnerModule, executableJson: string): VmEngine {
  const runner = new mod.Runner(executableJson);
  return { run: (args, options) => runner.run(args, options), memoryBytes: () => mod.wasmMemoryBytes() };
}

/** One VM run of a shot: `ticks` = 0 for `init`. */
export interface ChunkReport {
  index: number;
  ticks: number;
  steps: number;
  memoryCells: number;
  execCells: number;
  reserveCells: number;
  /** Wall time of the run, ms. */
  ms: number;
  /** Wasm memory after the run, bytes (the peak of the worker so far). */
  wasmBytes: number;
}

export interface ShotResult {
  /** The final serialized state (decimal felts). */
  state: string[];
  chunks: ChunkReport[];
  steps: number;
  ms: number;
}

export interface ShotOptions {
  sizing?: ChunkSizing;
  /** Forces K for every stepping chunk (tests and benchmarks). */
  fixedTicks?: number;
  onFrame?: (frame: TraceFrame) => void;
  /** Lines the program's parser does not recognise. */
  onLine?: (line: string) => void;
  onChunk?: (chunk: ChunkReport) => void;
  now?: () => number;
}

export function runShot<Level, Inputs>(
  engine: VmEngine,
  program: ChunkProgram<Level, Inputs>,
  level: Level,
  inputs: Inputs,
  options: ShotOptions = {},
): ShotResult {
  const now = options.now ?? (() => performance.now());
  const sizing = options.sizing ?? DEFAULT_SIZING;
  const onPrint = (text: string) => {
    const line = text.trimEnd();
    const sample = program.lines.parse(line);
    if (sample !== null) options.onFrame?.(program.frame(sample));
    else options.onLine?.(line);
  };
  const chunks: ChunkReport[] = [];
  const run = (args: string, ticks: number, reserveCells: number) => {
    const t = now();
    const r = engine.run(args, { reserveCells, onPrint });
    const chunk: ChunkReport = {
      index: chunks.length,
      ticks,
      steps: r.steps,
      memoryCells: r.memoryCells,
      execCells: r.execCells,
      reserveCells,
      ms: now() - t,
      wasmBytes: engine.memoryBytes(),
    };
    chunks.push(chunk);
    options.onChunk?.(chunk);
    return r.returned;
  };

  const t0 = now();
  let state = run(program.initArgs(level), 0, 0);
  let prev: ChunkMeasure | null = null;
  for (let remaining = program.remainingTicks(level, state); remaining > 0; ) {
    const plan = planChunk(prev, remaining, sizing, options.fixedTicks);
    state = run(program.chunkArgs(level, state, inputs, plan.ticks), plan.ticks, plan.reserveCells);
    prev = chunks[chunks.length - 1];
    const left = program.remainingTicks(level, state);
    // Fewer ticks left than planned is an early stop (G4: calm, all asleep); more is a bug.
    if (left > remaining - plan.ticks) {
      throw new Error(`${program.name}: stepped ${remaining - left} ticks, asked ${plan.ticks}`);
    }
    remaining = left;
  }
  return { state, chunks, steps: chunks.reduce((a, c) => a + c.steps, 0), ms: now() - t0 };
}
