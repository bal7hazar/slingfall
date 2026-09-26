// How the worker drives one chunked executable: the argument felts of `init` and `step_chunk`,
// when a shot is over, and how its `println!` lines become frames and events. Two programs: the
// slingfall replay (lot G4's `init` / `step_chunk`, trace lines v1) and the ball_drop stand-in
// of lot G1c (kept for the runner's bit-exactness tests and `vm/scripts/bench.mjs`).
import { SpikeTickLineParser, parseTraceLine, type TraceLine } from '../trace/lines.ts';

/** The executables of a program: `init`, `step_chunk` and the outputs of a finished level. */
export type Entry = 'init' | 'chunk' | 'outputs';

/** A chunked executable (docs/DESIGN.md D1: `init(level) -> state`, `step_chunk(state, inputs, k) -> state'`). */
export interface ChunkProgram<Level = unknown, Inputs = unknown> {
  readonly name: string;
  /** Arguments of `init(level)`, as whitespace-separated decimal felts. */
  initArgs(level: Level): string;
  /** Arguments of `step_chunk` for `k` ticks of shot `shot` (0-based). */
  chunkArgs(level: Level, state: readonly string[], inputs: Inputs, shot: number, k: number): string;
  /** Ticks of shot `shot` left to step from `state`, at most (0: the shot is over). */
  remainingTicks(level: Level, state: readonly string[], shot: number): number;
  /** Arguments of the `outputs` executable (programs that have one). */
  outputsArgs?(state: readonly string[], inputs: Inputs): string;
  /** The state (or outputs) in the felts a run of `entry` returned; all of them when absent. */
  payload?(entry: Entry, returned: readonly string[]): string[];
  /** The observer's lines (`src/trace/lines.ts`); `null` for any other line. */
  parseLine(line: string): TraceLine | null;
}

// ------------------------------------------------------------------------------ slingfall

/** Starknet's field prime: a negative integer `x` is the felt `P - |x|`. */
export const P = 2n ** 251n + 17n * 2n ** 192n + 1n;

/** An integer as a canonical decimal felt (`tools/tracec/tracec.py`'s `felt`). */
export function felt(value: bigint | number | string): string {
  const v = BigInt(value) % P;
  return (v < 0n ? v + P : v).toString();
}

/** A felt read back as a signed integer (`> P / 2` is negative). */
export function signed(value: string): bigint {
  const v = BigInt(value);
  return v > P / 2n ? v - P : v;
}

/** The `player` felt of the MVP until a wallet signs in: the short string `'player'` (tracec's default). */
export const DEFAULT_PLAYER = '123610794124658';

/** The level as `levelc.py to-felts` writes it (`fixtures/levels/*.felts.json`). */
export interface SlingfallLevel {
  /** The `Level` felts, decimal. */
  felts: readonly string[];
  /** Print the trace lines of the ticks (default true). */
  trace?: boolean;
}

/** `Shot` of docs/DESIGN.md D3 (`ability_tick` is 0 in the MVP). */
export interface ShotInput {
  pull_x: number;
  pull_y: number;
  /** Ticks before the launch, 0-60 (default 0). */
  delay?: number;
}

/** `Inputs { player, shots }` (D3): the shots played so far. */
export interface SlingfallInputs {
  player: string;
  shots: readonly ShotInput[];
}

/** `Serde` felts of `Inputs`. */
export function inputsFelts(inputs: SlingfallInputs): string[] {
  const felts = [felt(inputs.player), String(inputs.shots.length)];
  for (const s of inputs.shots) felts.push(felt(s.pull_x), felt(s.pull_y), String(s.delay ?? 0), '0');
  return felts;
}

/** A length-prefixed `Array<felt252>` argument. */
const array = (felts: readonly string[]) => `${felts.length} ${felts.join(' ')}`;

/** `Level` felt offsets (D2 `Serde` order: version, level_id, seed, gravity_y, shots, tick_cap, ...). */
const LEVEL_SEED = 2;
const LEVEL_SHOTS = 4;
const LEVEL_TICK_CAP = 5;
/** D3: a shot's delay is at most 60 ticks, and the delay ticks count in `shot_ticks`. */
const MAX_DELAY = 60;

/** The 7-felt header of `ChunkState` (`crates/slingfall_replay/README.md`). */
export interface ChunkHeader {
  version: number;
  /** Shots finished: shot `s` is over when this is `s + 1`. */
  shotsUsed: number;
  /** The level is over (won or out of shots): stop. */
  over: boolean;
  launched: boolean;
  shotTicks: number;
  /** Ticks since the start of the level (the last frame's tick; `Outputs.ticks_run`). */
  tick: number;
  score: number;
}

export const CHUNK_STATE_VERSION = 1;

/**
 * Felts of the binding header each executable returns before its state or outputs
 * (`crates/slingfall_replay/README.md`, lot P1b): `init` `[level_hash]`, `step_chunk`
 * `[state_in_hash, inputs_hash, shot, k]`, `outputs` `[state_in_hash, inputs_hash]`.
 */
export const BINDING_HEADER: Readonly<Record<Entry, number>> = { init: 1, chunk: 4, outputs: 2 };

/** A run's returned felts without the binding header of `entry`. */
export function stripBindingHeader(entry: Entry, returned: readonly string[]): string[] {
  const n = BINDING_HEADER[entry];
  if (returned.length < n) throw new Error(`${entry}: ${returned.length} felts, shorter than its ${n}-felt binding header`);
  return returned.slice(n);
}

export function readChunkHeader(state: readonly string[]): ChunkHeader {
  if (state.length < 7 || Number(state[0]) !== CHUNK_STATE_VERSION) {
    throw new Error(`not a ChunkState of version ${CHUNK_STATE_VERSION}: ${state.slice(0, 7).join(' ')}`);
  }
  return {
    version: Number(state[0]),
    shotsUsed: Number(state[1]),
    over: state[2] !== '0',
    launched: state[3] !== '0',
    shotTicks: Number(state[4]),
    tick: Number(state[5]),
    score: Number(state[6]),
  };
}

/** The level fields the shot loop needs, read from the level felts. */
export function levelInfo(level: SlingfallLevel): { seed: string; shots: number; tickCap: number } {
  return {
    seed: level.felts[LEVEL_SEED],
    shots: Number(level.felts[LEVEL_SHOTS]),
    tickCap: Number(level.felts[LEVEL_TICK_CAP]),
  };
}

/** docs/DESIGN.md D4, in felt order. */
export const OUTPUT_FIELDS = [
  'version',
  'level_hash',
  'seed',
  'player',
  'inputs_hash',
  'score',
  'won',
  'shots_used',
  'ticks_run',
  'final_state_hash',
] as const;

export type Outputs = Record<(typeof OUTPUT_FIELDS)[number], string>;

/** The 10 felts of `Outputs` (what a proof of the level carries), by name. */
export function decodeOutputs(felts: readonly string[]): Outputs {
  if (felts.length !== OUTPUT_FIELDS.length) throw new Error(`outputs: ${felts.length} felts, expected ${OUTPUT_FIELDS.length}`);
  return Object.fromEntries(OUTPUT_FIELDS.map((name, i) => [name, felts[i]])) as Outputs;
}

export const slingfallProgram: ChunkProgram<SlingfallLevel, SlingfallInputs> = {
  name: 'slingfall',
  initArgs: (level) => array(level.felts),
  chunkArgs: (level, state, inputs, shot, k) =>
    `${array(state)} ${array(inputsFelts(inputs))} ${shot} ${k} ${level.trace === false ? 0 : 1}`,
  // The shot's length is not known ahead (calm, asleep, spent pebble, cap: D5): the bound is the
  // tick cap plus the longest delay, and the header says when it is over.
  remainingTicks: (level, state, shot) => {
    const h = readChunkHeader(state);
    if (h.over || h.shotsUsed !== shot) return 0;
    return Math.max(1, levelInfo(level).tickCap + MAX_DELAY - h.shotTicks);
  },
  outputsArgs: (state, inputs) => `${array(state)} ${array(inputsFelts(inputs))}`,
  payload: stripBindingHeader,
  parseLine: parseTraceLine,
};

// ------------------------------------------------------------------------------ ball_drop

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
const spikeLines = new SpikeTickLineParser();

export const ballDropProgram: ChunkProgram<BallDropLevel, null> = {
  name: 'ball_drop',
  initArgs: (level) => `${MODE_INIT} ${level.scene} 0 ${traceFlag(level)} 0`,
  chunkArgs: (level, state, _inputs, _shot, k) =>
    `${MODE_CHUNK} ${level.scene} ${k} ${traceFlag(level)} ${state.length} ${state.join(' ')}`,
  remainingTicks: (level, state) => level.ticks - Number(state[STATE_TICK]),
  // The spike prints the y of body 0 (the ball) only: x = 0 and an identity rotation fill the
  // placeholder frame.
  parseLine: (line) => {
    const sample = spikeLines.parse(line);
    if (sample === null) return null;
    const { tick, y } = sample;
    return { kind: 'frame', frame: { tick, bodies: [{ handle: 0, x: '0', y, re: ONE_RAW, im: '0', asleep: false }] } };
  },
};

/** Programs a worker can be loaded with, by name (functions do not cross `postMessage`). */
export const PROGRAMS: Record<string, ChunkProgram> = {
  ball_drop: ballDropProgram as ChunkProgram,
  slingfall: slingfallProgram as ChunkProgram,
};
