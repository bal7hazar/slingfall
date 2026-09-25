import { ONE_RAW, isqrtCeil, mulFloor } from '../aim/fixed';
import { TICK_DT_RAW, launchVelocity } from '../aim/arc';
import {
  TRACE_VERSION,
  type BodyPose,
  type LevelBody,
  type PoseRaw,
  type Trace,
  type TraceEvent,
  type TraceFrame,
} from './types';

// Hand-made trace `pile10`, generated in `BigInt` from a fixed script (no floats in the state, no
// trigonometry): the fixture of the renderer until lot G4's trace build emits real ones. It is
// NOT physics. A pebble flies along the exact aim arc, hits block 4, and three blocks of a pile
// (4, 6, 7; asleep until then) wake up, fall to the right and go back to sleep; the frost roof
// (7) is destroyed on landing. `synth.test.ts` rewrites the fixture files when they are missing.

const q = (metres: number): bigint => BigInt(Math.round(metres * 2 ** 32));
const raw = (value: bigint): string => value.toString();

const FRAME_COUNT = 160;
const PEBBLE_HANDLE = 11;
const CONTACT_X = q(9.25); // left face of block 4 (x = 9.5) minus the pebble radius
const PULL = { x: -775, y: -270 };

const IDENTITY: PoseRaw = { x: '0', y: '0', re: raw(ONE_RAW), im: '0' };
const at = (x: number, y: number): PoseRaw => ({ ...IDENTITY, x: raw(q(x)), y: raw(q(y)) });
const vec = (x: number, y: number) => ({ x: raw(q(x)), y: raw(q(y)) });

function body(
  handle: number,
  kind: LevelBody['kind'],
  material: string,
  shape: LevelBody['shape'],
  x: number,
  y: number,
): LevelBody {
  return { handle, kind, shape, material, pose: at(x, y) };
}

const cuboid = (hx: number, hy: number): LevelBody['shape'] => ({
  type: 'cuboid',
  hx: raw(q(hx)),
  hy: raw(q(hy)),
});

const BODIES: LevelBody[] = [
  body(0, 'static', 'ground', { type: 'halfspace', normal: vec(0, 1) }, 0, 0),
  body(1, 'block', 'slate', cuboid(0.25, 1), 9, 1),
  body(2, 'block', 'slate', cuboid(0.25, 1), 12, 1),
  body(3, 'block', 'timber', cuboid(2, 0.2), 10.5, 2.2),
  body(4, 'block', 'timber', cuboid(0.5, 0.5), 10, 2.9),
  body(5, 'block', 'timber', cuboid(0.5, 0.5), 11, 2.9),
  body(6, 'block', 'frost', cuboid(0.5, 0.25), 10.5, 3.65),
  body(
    7,
    'block',
    'frost',
    { type: 'polygon', vertices: [vec(-0.6, -0.25), vec(0.6, -0.25), vec(0, 0.35)] },
    10.5,
    4.15,
  ),
  body(8, 'core', 'core', { type: 'ball', radius: raw(q(0.4)) }, 10.5, 0.4),
  body(9, 'block', 'slate', cuboid(0.4, 0.4), 20, 0.4),
  body(10, 'block', 'timber', cuboid(0.4, 0.4), 20, 1.2),
];

interface Mover {
  handle: number;
  x: bigint;
  y: bigint;
  vx: bigint;
  vy: bigint;
  re: bigint;
  im: bigint;
  /** Rotation per tick as a unit complex number. */
  spinRe: bigint;
  spinIm: bigint;
  /** Height of the centre when resting on the ground. */
  restY: bigint;
  flying: boolean;
}

/** A body at its level pose (or `start`), with velocity in m/s and a spin: sine of the angle per tick. */
function mover(
  handle: number,
  restY: number,
  velocity: { x: bigint; y: bigint },
  spin: bigint,
  start: { x: string; y: string } = BODIES[handle].pose,
): Mover {
  const sine = spin < 0n ? -spin : spin;
  return {
    handle,
    x: BigInt(start.x),
    y: BigInt(start.y),
    vx: velocity.x,
    vy: velocity.y,
    re: ONE_RAW,
    im: 0n,
    spinRe: isqrtCeil(ONE_RAW * ONE_RAW - sine * sine),
    spinIm: spin,
    restY: q(restY),
    flying: true,
  };
}

/** One semi-implicit Euler tick (the aim arc's formula), then rotation and landing. */
function advance(m: Mover, gravityDv: bigint): void {
  m.vy += gravityDv;
  m.x += mulFloor(m.vx, TICK_DT_RAW);
  m.y += mulFloor(m.vy, TICK_DT_RAW);
  const re = mulFloor(m.re, m.spinRe) - mulFloor(m.im, m.spinIm);
  const im = mulFloor(m.re, m.spinIm) + mulFloor(m.im, m.spinRe);
  m.re = re;
  m.im = im;
  if (m.y <= m.restY) {
    m.y = m.restY;
    m.vx = m.vy = 0n;
    m.re = ONE_RAW;
    m.im = 0n;
    m.flying = false;
  }
}

const poseOf = (m: Mover, asleep: boolean): BodyPose => ({
  handle: m.handle,
  x: raw(m.x),
  y: raw(m.y),
  re: raw(m.re),
  im: raw(m.im),
  asleep,
});

export function buildPile10(): Trace {
  const gravityY = q(-9.81);
  const launchScale = q(0.02);
  const gravityDv = mulFloor(gravityY, TICK_DT_RAW);
  const anchor = { x: q(-6), y: q(2.5) };

  const level = {
    bounds: { min_x: raw(q(-12)), min_y: raw(q(-4)), max_x: raw(q(26)), max_y: raw(q(14)) },
    sling_anchor: { x: raw(anchor.x), y: raw(anchor.y) },
    gravity_y: raw(gravityY),
    launch_scale: raw(launchScale),
    pull_radius: 1024,
    shots: 3,
    bodies: BODIES,
  };

  const v0 = launchVelocity(PULL, launchScale);
  const pebble = mover(PEBBLE_HANDLE, 0.25, v0, 0n, { x: raw(anchor.x), y: raw(anchor.y) });
  const v = (x: number, y: number) => ({ x: q(x), y: q(y) });
  const knocked = [
    mover(4, 0.5, v(5, 1), q(0.03)),
    mover(6, 0.25, v(4.5, 0.5), -q(0.025)),
    mover(7, 0.25, v(5.5, 1.5), q(0.035)),
  ];

  const frames: TraceFrame[] = [];
  const events: TraceEvent[] = [];
  let hitTick = -1;
  let roofLanded = false;

  for (let tick = 0; tick < FRAME_COUNT; tick++) {
    if (tick > 0) {
      if (pebble.flying) advance(pebble, gravityDv);
      if (hitTick < 0 && pebble.x >= CONTACT_X) {
        hitTick = tick;
        pebble.vx = -mulFloor(pebble.vx, q(0.2));
        pebble.vy = mulFloor(pebble.vy, q(0.5));
        events.push({ tick, kind: 'damage', handle: 4, hp: 62 });
      }
      if (hitTick >= 0) for (const m of knocked) if (m.flying) advance(m, gravityDv);
      if (hitTick >= 0 && tick === hitTick + 3) events.push({ tick, kind: 'damage', handle: 6, hp: 25 });
    }

    const roof = knocked[2];
    if (hitTick >= 0 && !roof.flying && !roofLanded) {
      roofLanded = true;
      events.push({ tick, kind: 'damage', handle: 7, hp: 0 });
      events.push({ tick, kind: 'destroyed', handle: 7 });
      events.push({ tick, kind: 'score', points: 100, total: 100 });
    }

    const bodies: BodyPose[] = [];
    for (const def of BODIES) {
      if (def.kind === 'static' || (def.handle === 7 && roofLanded)) continue;
      const m = knocked.find((k) => k.handle === def.handle);
      if (m) {
        bodies.push(poseOf(m, !(hitTick >= 0 && m.flying)));
      } else {
        bodies.push({ handle: def.handle, ...def.pose, asleep: true });
      }
    }
    bodies.push(poseOf(pebble, !pebble.flying));
    frames.push({ tick, bodies });
  }
  events.push({ tick: FRAME_COUNT - 1, kind: 'shot_end', shot: 0 });

  return { version: TRACE_VERSION, level, frames, events };
}

/** One line per frame and per event: readable diffs, still plain JSON. */
export function formatTrace(trace: Trace): string {
  const lines = (items: readonly unknown[]) => items.map((i) => `    ${JSON.stringify(i)}`).join(',\n');
  return [
    '{',
    `  "version": ${trace.version},`,
    `  "level": ${JSON.stringify(trace.level)},`,
    `  "frames": [\n${lines(trace.frames)}\n  ],`,
    `  "events": [\n${lines(trace.events)}\n  ]`,
    '}',
    '',
  ].join('\n');
}
