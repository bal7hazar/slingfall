// How the worker drives one chunked executable: the argument felts of `init` and `step_chunk`,
// when a shot is over, and how its `println!` lines become frames. The ball_drop stand-in is the
// only program until lot G4's replay executable and its observer format replace it.
import { SpikeTickLineParser, type TickLineParser, type TickSample } from '../trace/lines.ts';
import type { TraceFrame } from '../trace/types';

/** A chunked executable (docs/DESIGN.md D1: `init(level) -> state`, `step_chunk(state, inputs, k) -> state'`). */
export interface ChunkProgram<Level = unknown, Inputs = unknown> {
  readonly name: string;
  /** Arguments of `init(level)`, as whitespace-separated decimal felts. */
  initArgs(level: Level): string;
  /** Arguments of `step_chunk(state, inputs, k)`. */
  chunkArgs(level: Level, state: readonly string[], inputs: Inputs, k: number): string;
  /** Ticks left to step from `state` (0: the shot is over). */
  remainingTicks(level: Level, state: readonly string[]): number;
  /** The observer's line format (`src/trace/lines.ts`). */
  readonly lines: TickLineParser;
  /** The frame of one parsed tick line. */
  frame(sample: TickSample): TraceFrame;
}

const ONE_RAW = '4294967296';

/** Level of the ball_drop stand-in: a scene (3 = pile12) and a fixed number of ticks. */
export interface BallDropLevel {
  scene: number;
  ticks: number;
  /** Print one tick line per step (default true). */
  trace?: boolean;
}

// `main(mode: u8, scene: u8, steps: u32, trace: u8, state: Array<felt252>)`.
const MODE_INIT = 1;
const MODE_CHUNK = 2;
/** `ChunkState.tick` is the second felt of the state (after the layout version). */
const STATE_TICK = 1;

const traceFlag = (level: BallDropLevel) => (level.trace === false ? 0 : 1);

export const ballDropProgram: ChunkProgram<BallDropLevel, null> = {
  name: 'ball_drop',
  initArgs: (level) => `${MODE_INIT} ${level.scene} 0 ${traceFlag(level)} 0`,
  chunkArgs: (level, state, _inputs, k) =>
    `${MODE_CHUNK} ${level.scene} ${k} ${traceFlag(level)} ${state.length} ${state.join(' ')}`,
  remainingTicks: (level, state) => level.ticks - Number(state[STATE_TICK]),
  lines: new SpikeTickLineParser(),
  // The spike prints the y of body 0 (the ball) only: x = 0 and an identity rotation fill the
  // placeholder frame until G4's observer prints every awake body's pose.
  frame: ({ tick, y }) => ({
    tick,
    bodies: [{ handle: 0, x: '0', y, re: ONE_RAW, im: '0', asleep: false }],
  }),
};

/** Programs a worker can be loaded with, by name (functions do not cross `postMessage`). */
export const PROGRAMS: Record<string, ChunkProgram> = {
  ball_drop: ballDropProgram as ChunkProgram,
};
