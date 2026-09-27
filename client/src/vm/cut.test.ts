import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { predictContactTick, slingfallContactTick, traceLevelFromFelts } from './cut';
import { DEFAULT_PLAYER } from './program';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const felts = (name: string) => JSON.parse(readFileSync(root(`fixtures/levels/${name}.felts.json`), 'utf8')).felts as string[];
const level = (name: string) => traceLevelFromFelts(felts(name));
/** A `ChunkState` header (`program.ts`) `shotTicks` into a shot; the rest of the state is not read. */
const header = (shotTicks: number) => ['1', '0', '0', '0', String(shotTicks), '0', '0'];

describe('traceLevelFromFelts', () => {
  it('reads the fields and bodies the arc needs (pile10)', () => {
    const l = level('pile10');
    expect(l).toMatchObject({
      gravity_y: '-42133629174', // -9.81
      launch_scale: '85899346', // 0.02
      pull_radius: 1024,
      shots: 3,
      sling_anchor: { x: '12884901888', y: '10737418240' }, // (3, 2.5)
      bounds: { min_x: '-42949672960', min_y: '-42949672960', max_x: '214748364800', max_y: '171798691840' },
    });
    expect(l.bodies.map((b) => [b.handle, b.kind, b.shape.type])).toEqual([
      [0, 'static', 'halfspace'],
      ...Array.from({ length: 9 }, (_, i) => [i + 1, 'block', 'cuboid']),
      [10, 'core', 'ball'],
    ]);
  });

  it('reads every level to its last felt', () => {
    for (const name of ['pile10', 'cores3', 'tower', 'bridge', 'twin', 'one_block']) {
      expect(level(name).bodies.length).toBeGreaterThan(1);
    }
    expect(() => traceLevelFromFelts([...felts('pile10'), '0'])).toThrow('1 trailing felts');
    expect(() => traceLevelFromFelts(felts('pile10').slice(0, -1))).toThrow('unexpected end');
  });
});

describe('predictContactTick', () => {
  // [level, pull, predicted tick, first tick whose step cost jumps in a K = 1 run (lot Q2, alpha.5)]:
  // the prediction is never after the engine's contact, at most one tick before it.
  it.each([
    ['pile10', -1022, -63, 42, 43], // the owner's shot (QA M4)
    ['pile10', -1019, -72, 42, 43], // the cap shot
    ['pile10', -604, -392, 82, 83],
    ['cores3', -653, -304, 79, 80],
    ['tower', -604, -392, 78, 79],
    ['bridge', -463, -552, 120, 120],
    ['twin', -503, -327, 77, 77],
    ['twin', -543, -472, 118, 119], // on the level's poses; the second pile is untouched by the first shot
  ])('%s (%i, %i): tick %i (engine: %i)', (name, x, y, tick, engine) => {
    expect(predictContactTick(level(name), { pull_x: x, pull_y: y })).toBe(tick);
    expect(tick).toBeLessThanOrEqual(engine);
    expect(tick).toBeGreaterThanOrEqual(engine - 1);
  });

  it('is null for a shot that reaches no block or core (a miss lands on the ground)', () => {
    expect(predictContactTick(level('pile10'), { pull_x: -150, pull_y: -150 })).toBeNull();
    expect(predictContactTick(level('one_block'), { pull_x: -150, pull_y: -150 })).toBeNull();
    // Out of the bounds (upwards and out of the right edge) before any body.
    expect(predictContactTick(level('pile10'), { pull_x: -1024, pull_y: 0 })).toBeNull();
  });

  it('counts the delay ticks and clamps the pull to the disk (D3)', () => {
    const l = level('pile10');
    expect(predictContactTick(l, { pull_x: -604, pull_y: -392, delay: 30 })).toBe(30 + 82);
    expect(predictContactTick(l, { pull_x: -2044, pull_y: -126 })).toBe(predictContactTick(l, { pull_x: -1022, pull_y: -63 }));
  });

  it('meets the bodies at the poses of the last frame, without the destroyed ones', () => {
    const l = level('pile10');
    const pose = (handle: number) => ({ handle, ...l.bodies[handle].pose, asleep: true });
    const all = l.bodies.slice(1).map((b) => pose(b.handle));
    expect(predictContactTick(l, { pull_x: -604, pull_y: -392 }, all)).toBe(82);
    // The core (handle 10) destroyed: the reference arc passes over the pile and lands behind it.
    expect(predictContactTick(l, { pull_x: -604, pull_y: -392 }, all.slice(0, -1))).toBeNull();
    // Only the core left, moved to (15.5, 5.3), where the arc is at tick 62 (15.48, 5.34): its box
    // grown by the pebble (0.4 + 0.25 m around it) is entered 3 ticks (0.6 m) earlier.
    const moved = { ...pose(10), x: String((155n * 2n ** 32n) / 10n), y: String((53n * 2n ** 32n) / 10n) };
    expect(predictContactTick(l, { pull_x: -604, pull_y: -392 }, [moved])).toBe(59);
  });
});

describe('slingfallContactTick', () => {
  const inputs = { player: DEFAULT_PLAYER, shots: [{ pull_x: -150, pull_y: -150 }, { pull_x: -604, pull_y: -392 }] };
  const pile10 = { felts: felts('pile10') };

  it('counts from the state: ticks left to the contact, null once it is behind', () => {
    expect(slingfallContactTick(pile10, inputs, 1, header(0))).toBe(82);
    expect(slingfallContactTick(pile10, inputs, 1, header(80))).toBe(2);
    expect(slingfallContactTick(pile10, inputs, 1, header(82))).toBeNull();
    expect(slingfallContactTick(pile10, inputs, 0, header(0))).toBeNull();
    expect(slingfallContactTick(pile10, inputs, 2, header(0))).toBeNull();
  });
});
