import {
  TRACE_VERSION,
  type Shape,
  type Trace,
  type TraceEvent,
  type TraceFrame,
  type TraceLevel,
} from './types';

/**
 * Where the renderer gets its frames from: a recorded trace (a JSON file emitted from
 * `main_trace` through `scarb execute`), or the cairo-vm worker running the chunked replay live
 * (`WorkerTraceSource`, `src/vm/`, docs/DESIGN.md D8; wired into the app by lot G6b). Frames
 * arrive in tick order.
 */
export interface TraceSource {
  readonly kind: 'recorded' | 'worker';
  /** The level the frames belong to; resolves before the first frame is yielded. */
  level(): Promise<TraceLevel>;
  /** Yields the frames incrementally; the iterator ends with the trace. */
  frames(): AsyncIterable<TraceFrame>;
  /** Events so far: those with `tick` up to the latest yielded frame are present. */
  readonly events: readonly TraceEvent[];
}

/** A shot replayed live in the cairo-vm worker (lot G1c). */
export { WorkerTraceSource } from '../vm';

/** Fetches a JSON document; injectable so that tests read fixtures without a browser. */
export type JsonLoader = (url: string) => Promise<unknown>;

const fetchJson: JsonLoader = async (url) => {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`cannot load trace ${url}: HTTP ${response.status}`);
  }
  return response.json();
};

/** A trace recorded ahead of time and served as a JSON file. */
export class RecordedTraceSource implements TraceSource {
  readonly kind = 'recorded';
  private readonly url: string;
  private readonly load: JsonLoader;
  private trace: Promise<Trace> | undefined;
  private loaded: Trace | undefined;

  constructor(url: string, load: JsonLoader = fetchJson) {
    this.url = url;
    this.load = load;
  }

  get events(): readonly TraceEvent[] {
    return this.loaded?.events ?? [];
  }

  async level(): Promise<TraceLevel> {
    return (await this.fetchTrace()).level;
  }

  async *frames(): AsyncIterable<TraceFrame> {
    yield* (await this.fetchTrace()).frames;
  }

  private fetchTrace(): Promise<Trace> {
    this.trace ??= this.load(this.url).then((doc) => (this.loaded = parseTrace(doc)));
    return this.trace;
  }
}

const RAW_PATTERN = /^-?\d+$/;
const I64_MIN = -(2n ** 63n);
const I64_MAX = 2n ** 63n - 1n;

function fail(path: string, expected: string): never {
  throw new Error(`not a trace: ${path} must be ${expected}`);
}

function record(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) fail(path, 'an object');
  return value as Record<string, unknown>;
}

function array(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) fail(path, 'an array');
  return value;
}

function int(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    fail(path, 'a non-negative integer');
  }
  return value;
}

function raw(value: unknown, path: string): string {
  if (typeof value !== 'string' || !RAW_PATTERN.test(value)) fail(path, 'a decimal string');
  const n = BigInt(value);
  if (n < I64_MIN || n > I64_MAX) fail(path, 'within the i64 range');
  return value;
}

function checkVec(value: unknown, path: string): void {
  const v = record(value, path);
  raw(v.x, `${path}.x`);
  raw(v.y, `${path}.y`);
}

function checkPose(v: Record<string, unknown>, path: string): void {
  for (const key of ['x', 'y', 're', 'im']) raw(v[key], `${path}.${key}`);
}

function checkShape(value: unknown, path: string): Shape {
  const s = record(value, path);
  switch (s.type) {
    case 'ball':
      raw(s.radius, `${path}.radius`);
      break;
    case 'cuboid':
      raw(s.hx, `${path}.hx`);
      raw(s.hy, `${path}.hy`);
      break;
    case 'polygon':
      array(s.vertices, `${path}.vertices`).forEach((v, i) => checkVec(v, `${path}.vertices[${i}]`));
      break;
    case 'halfspace':
      checkVec(s.normal, `${path}.normal`);
      break;
    default:
      fail(`${path}.type`, 'ball, cuboid, polygon or halfspace');
  }
  return s as unknown as Shape;
}

const BODY_KINDS = ['static', 'block', 'core'];
const EVENT_KINDS = ['damage', 'destroyed', 'score', 'shot_end'];

function checkLevel(value: unknown): TraceLevel {
  const level = record(value, 'level');
  const bounds = record(level.bounds, 'level.bounds');
  for (const key of ['min_x', 'min_y', 'max_x', 'max_y']) raw(bounds[key], `level.bounds.${key}`);
  checkVec(level.sling_anchor, 'level.sling_anchor');
  raw(level.gravity_y, 'level.gravity_y');
  raw(level.launch_scale, 'level.launch_scale');
  int(level.pull_radius, 'level.pull_radius');
  int(level.shots, 'level.shots');
  array(level.bodies, 'level.bodies').forEach((value, i) => {
    const path = `level.bodies[${i}]`;
    const body = record(value, path);
    int(body.handle, `${path}.handle`);
    if (!BODY_KINDS.includes(body.kind as string)) fail(`${path}.kind`, BODY_KINDS.join(', '));
    if (typeof body.material !== 'string') fail(`${path}.material`, 'a string');
    checkShape(body.shape, `${path}.shape`);
    checkPose(record(body.pose, `${path}.pose`), `${path}.pose`);
  });
  return level as unknown as TraceLevel;
}

function checkFrames(value: unknown): TraceFrame[] {
  let previous = -1;
  array(value, 'frames').forEach((value, i) => {
    const path = `frames[${i}]`;
    const frame = record(value, path);
    const tick = int(frame.tick, `${path}.tick`);
    if (tick <= previous) fail(`${path}.tick`, 'greater than the previous tick');
    previous = tick;
    array(frame.bodies, `${path}.bodies`).forEach((value, j) => {
      const body = record(value, `${path}.bodies[${j}]`);
      int(body.handle, `${path}.bodies[${j}].handle`);
      if (typeof body.asleep !== 'boolean') fail(`${path}.bodies[${j}].asleep`, 'a boolean');
      checkPose(body, `${path}.bodies[${j}]`);
    });
  });
  return value as TraceFrame[];
}

function checkEvents(value: unknown): TraceEvent[] {
  array(value, 'events').forEach((value, i) => {
    const event = record(value, `events[${i}]`);
    int(event.tick, `events[${i}].tick`);
    if (!EVENT_KINDS.includes(event.kind as string)) fail(`events[${i}].kind`, EVENT_KINDS.join(', '));
  });
  return value as TraceEvent[];
}

/**
 * Checks the shape of a trace document (not the physics: the values come from the Cairo replay);
 * every scalar must be a decimal string within `i64`.
 */
export function parseTrace(doc: unknown): Trace {
  const trace = record(doc, 'document');
  if (trace.version !== TRACE_VERSION) fail('version', String(TRACE_VERSION));
  return {
    version: TRACE_VERSION,
    level: checkLevel(trace.level),
    frames: checkFrames(trace.frames),
    events: checkEvents(trace.events),
  };
}
