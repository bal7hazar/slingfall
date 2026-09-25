import {
  TRACE_VERSION,
  type BodyKind,
  type BodyPose,
  type LevelBody,
  type RawFixed,
  type Shape,
  type Trace,
  type TraceEvent,
  type TraceFrame,
  type TraceLevel,
} from './types.ts';

/** One observer line of the trace build, reduced to what the spike prints. */
export interface TickSample {
  tick: number;
  y: RawFixed;
}

/**
 * Turns a line printed by the ball_drop stand-in (`println!`, captured by the worker of lot
 * G1c) into a sample, or `null` for a line that is not a tick.
 */
export interface TickLineParser {
  parse(line: string): TickSample | null;
}

/** The spike's format (docs/research/03-spike-wasm-vm.md): `tick <i> y <raw>`. */
export class SpikeTickLineParser implements TickLineParser {
  private static readonly PATTERN = /^tick (\d+) y (-?\d+)$/;

  parse(line: string): TickSample | null {
    const match = SpikeTickLineParser.PATTERN.exec(line.trim());
    return match ? { tick: Number(match[1]), y: match[2] } : null;
  }
}

// --------------------------------------------------------------------------- trace lines v1

/** Version of the replay's trace lines (`crates/slingfall_replay/README.md`, "Trace lines v1"). */
export const LINES_VERSION = 1;

/** The `level` header line: the `Level` fields the client draws and aims with. */
export interface LevelLine {
  gravity_y: RawFixed;
  launch_scale: RawFixed;
  pull_radius: number;
  shots: number;
  bounds: TraceLevel['bounds'];
  sling_anchor: TraceLevel['sling_anchor'];
  bodies: number;
}

/** A `body` header line; `material` is the level's material index. */
export interface BodyLine {
  handle: number;
  kind: BodyKind;
  material: number;
  pose: LevelBody['pose'];
  shape: Shape;
}

/** One parsed line of the trace build (`main_trace`, `init`, `step_chunk` with `trace = 1`). */
export type TraceLine =
  | { kind: 'version'; version: number }
  | { kind: 'level'; level: LevelLine }
  | { kind: 'material'; index: number; score: number }
  | { kind: 'body'; body: BodyLine }
  | { kind: 'frame'; frame: TraceFrame }
  | { kind: 'event'; event: TraceEvent };

const KINDS: readonly BodyKind[] = ['static', 'block', 'core'];
/** Material names by their D7 score (as `tools/tracec/tracec.py`); static bodies are `ground`. */
const MATERIAL_NAMES: Readonly<Record<number, string>> = { 50: 'timber', 100: 'frost', 150: 'slate', 1000: 'core' };
const RAW = /^-?\d+$/;
const INT = /^\d+$/;

class LineError extends Error {}

function raw(token: string | undefined): RawFixed {
  if (token === undefined || !RAW.test(token)) throw new LineError();
  return token;
}

function int(token: string | undefined): number {
  if (token === undefined || !INT.test(token)) throw new LineError();
  return Number(token);
}

function shape(t: string[], at: number): Shape {
  switch (t[at]) {
    case 'ball':
      return { type: 'ball', radius: raw(t[at + 1]) };
    case 'cuboid':
      return { type: 'cuboid', hx: raw(t[at + 1]), hy: raw(t[at + 2]) };
    case 'polygon': {
      const n = int(t[at + 1]);
      const vertices = [];
      for (let i = 0; i < n; i++) vertices.push({ x: raw(t[at + 2 + 2 * i]), y: raw(t[at + 3 + 2 * i]) });
      return { type: 'polygon', vertices };
    }
    case 'halfspace':
      return { type: 'halfspace', normal: { x: raw(t[at + 1]), y: raw(t[at + 2]) } };
    default:
      throw new LineError();
  }
}

function frame(t: string[]): TraceFrame {
  if ((t.length - 2) % 6 !== 0) throw new LineError();
  const bodies: BodyPose[] = [];
  for (let i = 2; i < t.length; i += 6) {
    const asleep = t[i + 5];
    if (asleep !== '0' && asleep !== '1') throw new LineError();
    bodies.push({ handle: int(t[i]), x: raw(t[i + 1]), y: raw(t[i + 2]), re: raw(t[i + 3]), im: raw(t[i + 4]), asleep: asleep === '1' });
  }
  return { tick: int(t[1]), bodies };
}

function parseTokens(t: string[]): TraceLine | null {
  switch (t[0]) {
    case 'trace':
      return { kind: 'version', version: int(t[1]) };
    case 'level':
      return {
        kind: 'level',
        level: {
          gravity_y: raw(t[1]),
          launch_scale: raw(t[2]),
          pull_radius: int(t[3]),
          shots: int(t[4]),
          bounds: { min_x: raw(t[5]), min_y: raw(t[6]), max_x: raw(t[7]), max_y: raw(t[8]) },
          sling_anchor: { x: raw(t[9]), y: raw(t[10]) },
          bodies: int(t[11]),
        },
      };
    case 'material':
      return { kind: 'material', index: int(t[1]), score: int(t[2]) };
    case 'body': {
      const kind = KINDS[int(t[2])];
      if (kind === undefined) throw new LineError();
      return {
        kind: 'body',
        body: {
          handle: int(t[1]),
          kind,
          material: int(t[3]),
          pose: { x: raw(t[4]), y: raw(t[5]), re: raw(t[6]), im: raw(t[7]) },
          shape: shape(t, 8),
        },
      };
    }
    case 'frame':
      return { kind: 'frame', frame: frame(t) };
    case 'damage':
      return { kind: 'event', event: { tick: int(t[1]), kind: 'damage', handle: int(t[2]), hp: int(t[3]) } };
    case 'destroyed':
      return { kind: 'event', event: { tick: int(t[1]), kind: 'destroyed', handle: int(t[2]) } };
    case 'score':
      return { kind: 'event', event: { tick: int(t[1]), kind: 'score', points: int(t[2]), total: int(t[3]) } };
    case 'shot_end':
      return { kind: 'event', event: { tick: int(t[1]), kind: 'shot_end', shot: int(t[2]) } };
    default:
      return null;
  }
}

/**
 * Parses one line of the trace build (the runner hands `println!` text over with its newline).
 * `null` for a line that is not a trace line (the VM's own output, blank lines) and for a
 * malformed one: the page ignores what it cannot read, the tests assert the counts.
 */
export function parseTraceLine(line: string): TraceLine | null {
  const tokens = line.trim().split(/\s+/);
  try {
    return parseTokens(tokens);
  } catch (e) {
    if (e instanceof LineError) return null;
    throw e;
  }
}

/**
 * Assembles the `TraceLevel` from the header lines (`trace`, `level`, `material`, `body`) that
 * `init` and `main_trace` print. Material names follow `tools/tracec/tracec.py`.
 */
export class LevelHeader {
  private version: number | null = null;
  private line: LevelLine | null = null;
  private readonly materials = new Map<number, number>();
  private readonly bodies: BodyLine[] = [];

  /** Takes a parsed line; returns whether it was a header line. */
  push(parsed: TraceLine): boolean {
    switch (parsed.kind) {
      case 'version':
        this.version = parsed.version;
        return true;
      case 'level':
        this.line = parsed.level;
        return true;
      case 'material':
        this.materials.set(parsed.index, parsed.score);
        return true;
      case 'body':
        this.bodies.push(parsed.body);
        return true;
      default:
        return false;
    }
  }

  /** The level; throws when the header is missing, of another version or incomplete. */
  level(): TraceLevel {
    if (this.version === null || this.line === null) throw new Error('trace lines: no `trace` / `level` header line');
    if (this.version !== LINES_VERSION) throw new Error(`trace lines: version ${this.version}, expected ${LINES_VERSION}`);
    const { bodies: count, ...fields } = this.line;
    if (this.bodies.length !== count) throw new Error(`trace lines: ${this.bodies.length} body lines, level has ${count}`);
    return {
      bounds: fields.bounds,
      sling_anchor: fields.sling_anchor,
      gravity_y: fields.gravity_y,
      launch_scale: fields.launch_scale,
      pull_radius: fields.pull_radius,
      shots: fields.shots,
      bodies: this.bodies.map((b) => ({
        handle: b.handle,
        kind: b.kind,
        shape: b.shape,
        material: b.kind === 'static' ? 'ground' : (MATERIAL_NAMES[this.materials.get(b.material) ?? -1] ?? `m${b.material}`),
        pose: b.pose,
      })),
    };
  }
}

/** The tick-0 frame: every dynamic body asleep at its level pose (levels start pre-slept, D2). */
export function startFrame(level: TraceLevel): TraceFrame {
  return {
    tick: 0,
    bodies: level.bodies.filter((b) => b.kind !== 'static').map((b) => ({ handle: b.handle, ...b.pose, asleep: true })),
  };
}

/** Trace format v1 from the lines of a whole `main_trace` run (`tracec.py trace`'s TypeScript twin). */
export function linesToTrace(lines: Iterable<string>): Trace {
  const header = new LevelHeader();
  const frames: TraceFrame[] = [];
  const events: TraceEvent[] = [];
  for (const line of lines) {
    const parsed = parseTraceLine(line);
    if (parsed === null || header.push(parsed)) continue;
    if (parsed.kind === 'frame') frames.push(parsed.frame);
    else if (parsed.kind === 'event') events.push(parsed.event);
  }
  const level = header.level();
  return { version: TRACE_VERSION, level, frames: [startFrame(level), ...frames], events };
}
