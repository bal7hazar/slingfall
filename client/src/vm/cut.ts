// The predicted contact tick of a shot (QA M4, lot Q2): the chunk loop ends the flight chunk just
// before the pebble reaches the structure, so that the impact, whose ticks cost ~10x a flight
// tick, opens a fresh chunk sized for it (`sizing.ts`, `ContactCut`). The tick comes from the aim
// preview's exact arc (`aim/arc.ts`, bit-exact with the engine's free flight) against the boxes of
// `aim/contact.ts`. It only moves chunk boundaries, never results (chunking is bit-exact).
//
// Imports `aim/` without `.ts` extensions, so plain Node cannot load this module: the Web Worker
// (`worker.ts`, bundled by Vite) and Vitest do; `serve.ts` and `shot.ts` take a predictor.
import { arcParamsFromLevel, flightArc } from '../aim/arc';
import { bodyAabb, containsPoint, type Aabb } from '../aim/contact';
import { clampPull } from '../aim/pull';
import type { BodyKind, BodyPose, LevelBody, Shape, TraceLevel } from '../trace/types';
import { readChunkHeader, signed, type ShotInput, type SlingfallInputs, type SlingfallLevel } from './program.ts';

const KINDS: readonly BodyKind[] = ['static', 'block', 'core'];
/** `Material` of docs/DESIGN.md D2: 7 felts. */
const MATERIAL_FELTS = 7;
/**
 * The pebble's radius (D12: 0.25 m), raw. The arc is the pebble's centre, so each box grows by it:
 * without it, pile10's reference arc passes 5 cm over the core's box while the pebble touches it.
 */
const PEBBLE_RADIUS_RAW = 1n << 30n;

/**
 * The `Level` felts (docs/DESIGN.md D2, `levelc.py felts_to_level`) as the `TraceLevel` the arc
 * reads: body `i` has handle `i` (the pebble of shot `s` is `bodies + s`); materials are not named.
 */
export function traceLevelFromFelts(felts: readonly string[]): TraceLevel {
  let at = 0;
  const next = () => {
    if (at >= felts.length) throw new Error('level felts: unexpected end');
    return felts[at++];
  };
  const raw = () => signed(next()).toString();
  const int = () => Number(next());
  const vec = () => ({ x: raw(), y: raw() });
  next(); // version
  next(); // level_id
  next(); // seed
  const gravity_y = raw();
  const shots = int();
  next(); // tick_cap
  const bounds = { min_x: raw(), min_y: raw(), max_x: raw(), max_y: raw() };
  const sling_anchor = vec();
  const pull_radius = int();
  const launch_scale = raw();
  const projectiles = int();
  at += projectiles;
  const materials = int();
  at += materials * MATERIAL_FELTS;
  const bodies: LevelBody[] = [];
  for (let handle = 0, n = int(); handle < n; handle++) {
    const kind = KINDS[int()];
    if (kind === undefined) throw new Error(`level felts: body ${handle} has no valid kind`);
    const variant = int();
    let shape: Shape;
    if (variant === 0) shape = { type: 'ball', radius: raw() };
    else if (variant === 1) shape = { type: 'cuboid', hx: raw(), hy: raw() };
    else if (variant === 2) shape = { type: 'polygon', vertices: Array.from({ length: int() }, vec) };
    else shape = { type: 'halfspace', normal: vec() };
    const pose = { x: raw(), y: raw(), re: raw(), im: raw() };
    next(); // material
    bodies.push({ handle, kind, shape, material: '', pose });
  }
  if (at !== felts.length) throw new Error(`level felts: ${felts.length - at} trailing felts`);
  return { bounds, sling_anchor, gravity_y, launch_scale, pull_radius, shots, bodies };
}

/**
 * Shot tick (delay included, 1-based) of the first arc point inside the box of a block or core
 * grown by the pebble's radius, or `null` when the arc leaves the bounds, meets only a static body
 * (the ground: cheap contacts, and the arc is wrong after it) or reaches nothing within
 * `MAX_ARC_TICKS`. `poses` (the last frame of the previous shot) replace the level's poses and
 * drop the dynamic bodies they lack (destroyed); without them, the level's settled poses.
 */
export function predictContactTick(level: TraceLevel, shot: ShotInput, poses?: readonly BodyPose[]): number | null {
  const byHandle = poses === undefined ? undefined : new Map(poses.map((p) => [p.handle, p]));
  const bounds: Aabb = {
    minX: BigInt(level.bounds.min_x),
    minY: BigInt(level.bounds.min_y),
    maxX: BigInt(level.bounds.max_x),
    maxY: BigInt(level.bounds.max_y),
  };
  const boxes: { box: Aabb; dynamic: boolean }[] = [];
  for (const body of level.bodies) {
    const moved = byHandle?.get(body.handle);
    if (byHandle !== undefined && body.kind !== 'static' && moved === undefined) continue;
    const box = bodyAabb(moved === undefined ? body : { ...body, pose: moved }, bounds);
    if (box === undefined) continue;
    const r = PEBBLE_RADIUS_RAW;
    boxes.push({
      box: { minX: box.minX - r, minY: box.minY - r, maxX: box.maxX + r, maxY: box.maxY + r },
      dynamic: body.kind !== 'static',
    });
  }
  const params = { ...arcParamsFromLevel(level), obstacles: boxes.map((b) => b.box) };
  const arc = flightArc(params, clampPull(shot.pull_x, shot.pull_y, level.pull_radius));
  const end = arc.at(-1);
  if (end === undefined || !boxes.some((b) => b.dynamic && containsPoint(b.box, end.x, end.y))) return null;
  return (shot.delay ?? 0) + arc.length;
}

/**
 * `ShotOptions.predictContact` of the slingfall program: ticks from `state` to shot `shot`'s
 * predicted contact tick, `null` when none is predicted or it is behind `state`.
 */
export function slingfallContactTick(
  level: SlingfallLevel,
  inputs: SlingfallInputs,
  shot: number,
  state: readonly string[],
  poses?: readonly BodyPose[],
): number | null {
  const input = inputs.shots[shot];
  if (input === undefined) return null;
  const tick = predictContactTick(traceLevelFromFelts(level.felts), input, poses);
  if (tick === null) return null;
  const left = tick - readChunkHeader(state).shotTicks;
  return left > 0 ? left : null;
}
