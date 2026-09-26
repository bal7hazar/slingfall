// The chunked shot: `init(level)` once, then `step_chunk(state, inputs, shot, k)` until the
// program says the shot is over, each chunk a fresh VM run on the same loaded executables (the
// worker and its wasm stay alive between chunks). Pure: no Worker, no DOM; the worker and the
// Node tests and benchmark all run it. Value imports carry `.ts` so that Node runs this file as is.
import type { TraceEvent, TraceFrame } from '../trace/types';
import type { ChunkProgram, Entry } from './program';
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

/** The loaded executables (wasm-bindgen `Runner`s) plus the size of the wasm memory. */
export interface VmEngine {
  /** Runs `entry`'s executable (default `chunk`, the one every program has). */
  run(args: string, options: RunOptions, entry?: Entry): RunReport;
  /** Current size of the wasm linear memory in bytes (it only grows: the peak so far). */
  memoryBytes(): number;
}

/** The wasm-bindgen module surface used here (`pkg/` or `pkg-node/`). */
export interface RunnerModule {
  Runner: new (executableJson: string) => { run(args: string, options: RunOptions): RunReport };
  wasmMemoryBytes(): number;
}

/**
 * An engine over `executableJson` (the `chunk` entry, and every entry `others` lacks). The
 * slingfall program has one executable per entry; ball_drop's `main` takes a mode instead.
 */
export function engineFromModule(
  mod: RunnerModule,
  executableJson: string,
  others: Partial<Record<Entry, string>> = {},
): VmEngine {
  const chunk = new mod.Runner(executableJson);
  const runners: Partial<Record<Entry, InstanceType<RunnerModule['Runner']>>> = { chunk };
  for (const [entry, json] of Object.entries(others) as [Entry, string][]) runners[entry] = new mod.Runner(json);
  return {
    run: (args, options, entry = 'chunk') => (runners[entry] ?? chunk).run(args, options),
    memoryBytes: () => mod.wasmMemoryBytes(),
  };
}

/** One VM run: `ticks` = 0 for `init` and `outputs`. */
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
  /** The 0-based shot to step (default 0). */
  shot?: number;
  /** The state to start from; `init(level)` runs first when absent. */
  state?: readonly string[];
  sizing?: ChunkSizing;
  /** Forces K for every stepping chunk (tests and benchmarks). */
  fixedTicks?: number;
  onFrame?: (frame: TraceFrame) => void;
  onEvent?: (event: TraceEvent) => void;
  /** Lines that are neither frames nor events (the level header of `init`, the VM's own output). */
  onLine?: (line: string) => void;
  onChunk?: (chunk: ChunkReport) => void;
  now?: () => number;
}

/** Runs `engine` with the program's line parsing and a report per run. */
class Runs<Level, Inputs> {
  readonly chunks: ChunkReport[] = [];
  private readonly engine: VmEngine;
  private readonly program: ChunkProgram<Level, Inputs>;
  private readonly options: ShotOptions;
  private readonly now: () => number;
  private readonly onPrint: (text: string) => void;

  constructor(engine: VmEngine, program: ChunkProgram<Level, Inputs>, options: ShotOptions) {
    this.engine = engine;
    this.program = program;
    this.options = options;
    this.now = options.now ?? (() => performance.now());
    this.onPrint = (text) => {
      const line = text.trimEnd();
      const parsed = program.parseLine(line);
      if (parsed?.kind === 'frame') options.onFrame?.(parsed.frame);
      else if (parsed?.kind === 'event') options.onEvent?.(parsed.event);
      else options.onLine?.(line);
    };
  }

  run(entry: Entry, args: string, ticks: number, reserveCells: number): string[] {
    const t = this.now();
    const r = this.engine.run(args, { reserveCells, onPrint: this.onPrint }, entry);
    const chunk: ChunkReport = {
      index: this.chunks.length,
      ticks,
      steps: r.steps,
      memoryCells: r.memoryCells,
      execCells: r.execCells,
      reserveCells,
      ms: this.now() - t,
      wasmBytes: this.engine.memoryBytes(),
    };
    this.chunks.push(chunk);
    this.options.onChunk?.(chunk);
    return this.program.payload?.(entry, r.returned) ?? r.returned;
  }

  result(state: string[], t0: number): ShotResult {
    const { chunks } = this;
    return { state, chunks, steps: chunks.reduce((a, c) => a + c.steps, 0), ms: this.now() - t0 };
  }

  get t(): number {
    return this.now();
  }
}

/** `init(level)`: the state before the first shot; its lines (the level header) go to `onLine`. */
export function runInit<Level, Inputs>(
  engine: VmEngine,
  program: ChunkProgram<Level, Inputs>,
  level: Level,
  options: ShotOptions = {},
): ShotResult {
  const runs = new Runs(engine, program, options);
  const t0 = runs.t;
  return runs.result(runs.run('init', program.initArgs(level), 0, 0), t0);
}

export function runShot<Level, Inputs>(
  engine: VmEngine,
  program: ChunkProgram<Level, Inputs>,
  level: Level,
  inputs: Inputs,
  options: ShotOptions = {},
): ShotResult {
  const sizing = options.sizing ?? DEFAULT_SIZING;
  const shot = options.shot ?? 0;
  const runs = new Runs(engine, program, options);
  const t0 = runs.t;
  let state = options.state === undefined ? runs.run('init', program.initArgs(level), 0, 0) : [...options.state];
  let prev: ChunkMeasure | null = null;
  for (let remaining = program.remainingTicks(level, state, shot); remaining > 0; ) {
    const plan = planChunk(prev, remaining, sizing, options.fixedTicks);
    state = runs.run('chunk', program.chunkArgs(level, state, inputs, shot, plan.ticks), plan.ticks, plan.reserveCells);
    prev = runs.chunks[runs.chunks.length - 1];
    const left = program.remainingTicks(level, state, shot);
    // Fewer ticks left than planned is an early stop (the shot ended); more is a bug.
    if (left > remaining - plan.ticks) {
      throw new Error(`${program.name}: stepped ${remaining - left} ticks, asked ${plan.ticks}`);
    }
    remaining = left;
  }
  return runs.result(state, t0);
}

/** The outputs of a finished level (`program.outputsArgs`, the `outputs` executable). */
export function runOutputs<Level, Inputs>(
  engine: VmEngine,
  program: ChunkProgram<Level, Inputs>,
  state: readonly string[],
  inputs: Inputs,
  options: ShotOptions = {},
): ShotResult {
  if (program.outputsArgs === undefined) throw new Error(`${program.name} has no outputs executable`);
  const runs = new Runs(engine, program, options);
  const t0 = runs.t;
  return runs.result(runs.run('outputs', program.outputsArgs(state, inputs), 0, 0), t0);
}
