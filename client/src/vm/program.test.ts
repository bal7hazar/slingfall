import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  DEFAULT_PLAYER,
  P,
  ballDropProgram,
  decodeOutputs,
  felt,
  inputsFelts,
  levelInfo,
  readChunkHeader,
  signed,
  slingfallProgram,
  type SlingfallInputs,
  type SlingfallLevel,
} from './program';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const json = (path: string) => JSON.parse(readFileSync(root(path), 'utf8'));
/** `tracec.py args` writes `0x` felts; the runner takes decimals. */
const argsFixture = (name: string): string[] => (json(`client/vm/fixtures/${name}.args.json`) as string[]).map((h) => BigInt(h).toString());

const PILE10: SlingfallLevel = { felts: json('fixtures/levels/pile10.felts.json').felts };
const REFERENCE: SlingfallInputs = { player: DEFAULT_PLAYER, shots: [{ pull_x: -600, pull_y: -392 }] };
const THREE: SlingfallInputs = {
  player: DEFAULT_PLAYER,
  shots: [
    { pull_x: -150, pull_y: -150 },
    { pull_x: -200, pull_y: -200, delay: 3 },
    { pull_x: -600, pull_y: -392 },
  ],
};

/** `main(level, inputs)`'s arguments from the program's encoders: `init`'s, then the inputs array. */
const mainArgs = (level: SlingfallLevel, inputs: SlingfallInputs) => {
  const felts = inputsFelts(inputs);
  return [...slingfallProgram.initArgs(level).split(' '), String(felts.length), ...felts];
};

/** A `ChunkState` header followed by some body felts. */
const state = (shotsUsed: number, over: number, shotTicks = 0, tick = 0, score = 0) =>
  ['1', String(shotsUsed), String(over), '1', String(shotTicks), String(tick), String(score), '42', '43'];

describe('felts', () => {
  it('encodes negative integers as P - x and reads them back', () => {
    expect(felt(-600)).toBe((P - 600n).toString());
    expect(felt(1024)).toBe('1024');
    expect(felt(P + 5n)).toBe('5');
    expect(signed(felt(-392))).toBe(-392n);
    expect(signed('7')).toBe(7n);
  });

  it('reads the level fields of pile10', () => {
    expect(levelInfo(PILE10)).toEqual({ seed: '0', shots: 3, tickCap: 180 });
  });
});

describe('slingfallProgram arguments (against `tracec.py args`)', () => {
  it('pile10 with the reference shot', () => {
    expect(mainArgs(PILE10, REFERENCE)).toEqual(argsFixture('pile10-reference'));
  });

  it('pile10 with three shots, one delayed', () => {
    expect(mainArgs(PILE10, THREE)).toEqual(argsFixture('pile10-three'));
  });

  it('init takes the length-prefixed level', () => {
    const args = slingfallProgram.initArgs(PILE10).split(' ');
    expect(args[0]).toBe(String(PILE10.felts.length));
    expect(args.slice(1)).toEqual(PILE10.felts);
  });

  it('step_chunk: state, inputs, shot, k, trace', () => {
    const s = state(1, 0);
    const inputs = inputsFelts(THREE);
    expect(slingfallProgram.chunkArgs(PILE10, s, THREE, 1, 7)).toBe(
      [s.length, ...s, inputs.length, ...inputs, 1, 7, 1].join(' '),
    );
    expect(slingfallProgram.chunkArgs({ ...PILE10, trace: false }, s, THREE, 1, 7).endsWith(' 1 7 0')).toBe(true);
    expect(slingfallProgram.outputsArgs!(s, THREE)).toBe([s.length, ...s, inputs.length, ...inputs].join(' '));
  });
});

describe('ChunkState header', () => {
  it('decodes the 7-felt header', () => {
    expect(readChunkHeader(state(2, 1, 0, 431, 1350))).toEqual({
      version: 1,
      shotsUsed: 2,
      over: true,
      launched: true,
      shotTicks: 0,
      tick: 431,
      score: 1350,
    });
    expect(() => readChunkHeader(['2', ...state(0, 0).slice(1)])).toThrow('not a ChunkState of version 1');
    expect(() => readChunkHeader(['1', '0'])).toThrow('not a ChunkState');
  });

  it('bounds the ticks left of a shot until the header ends it', () => {
    // Cap 180 + the longest delay (60), minus the shot's ticks so far.
    expect(slingfallProgram.remainingTicks(PILE10, state(0, 0), 0)).toBe(240);
    expect(slingfallProgram.remainingTicks(PILE10, state(0, 0, 100), 0)).toBe(140);
    expect(slingfallProgram.remainingTicks(PILE10, state(0, 0, 500), 0)).toBe(1);
    // Shot 0 is over when shots_used is 1; nothing to step when the level is over.
    expect(slingfallProgram.remainingTicks(PILE10, state(1, 0), 0)).toBe(0);
    expect(slingfallProgram.remainingTicks(PILE10, state(1, 1), 1)).toBe(0);
  });
});

describe('outputs', () => {
  it('names the 10 felts of D4 (main_trace on pile10, reference shot)', () => {
    const recorded = readFileSync(root('client/vm/fixtures/pile10-reference.main_trace.txt'), 'utf8');
    const felts = recorded.split('Program output:')[1].trim().split(/\s+/).slice(1);
    const outputs = decodeOutputs(felts);
    expect(outputs.version).toBe('1');
    expect(BigInt(outputs.level_hash)).toBe(BigInt(json('fixtures/levels/pile10.felts.json').level_hash));
    expect(outputs.player).toBe(DEFAULT_PLAYER);
    expect([outputs.score, outputs.won, outputs.shots_used, outputs.ticks_run]).toEqual(['5200', '1', '1', '109']);
    expect(() => decodeOutputs(felts.slice(1))).toThrow('outputs: 9 felts, expected 10');
  });
});

describe('ballDropProgram', () => {
  const level = { scene: 3, ticks: 120 };
  const frameOf = (line: string) => {
    const parsed = ballDropProgram.parseLine(line);
    return parsed?.kind === 'frame' ? parsed.frame : null;
  };

  it('turns `tick <i> y <raw>` into a frame of body 0', () => {
    expect(frameOf('tick 12 y -702227152')).toEqual({
      tick: 12,
      bodies: [{ handle: 0, x: '0', y: '-702227152', re: '4294967296', im: '0', asleep: false }],
    });
    // The runner hands `println!` text over with its newline.
    expect(frameOf('tick 1 y 8582619724\n')?.tick).toBe(1);
  });

  it.each(['', 'tick', 'tick x y 1', 'tick 1 y', 'tick 1 y 1.5', 'tock 1 y 2'])('ignores %j', (line) =>
    expect(frameOf(line)).toBeNull(),
  );

  it('builds init and step_chunk arguments', () => {
    expect(ballDropProgram.initArgs(level)).toBe('1 3 0 1 0');
    expect(ballDropProgram.initArgs({ ...level, trace: false })).toBe('1 3 0 0 0');
    expect(ballDropProgram.chunkArgs(level, ['7', '40', '-1'], null, 0, 10)).toBe('2 3 10 1 3 7 40 -1');
  });

  it('reads the tick counter of the state', () => {
    expect(ballDropProgram.remainingTicks(level, ['v', '0'], 0)).toBe(120);
    expect(ballDropProgram.remainingTicks(level, ['v', '115'], 0)).toBe(5);
    expect(ballDropProgram.remainingTicks(level, ['v', '120'], 0)).toBe(0);
  });
});
