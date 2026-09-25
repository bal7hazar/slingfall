import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { LevelHeader, linesToTrace, parseTraceLine, startFrame } from './lines';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
/** `main_trace` on pile10 with the reference shot, `scarb execute --print-program-output` as printed. */
const recorded = () => readFileSync(root('client/vm/fixtures/pile10-reference.main_trace.txt'), 'utf8').split('\n');
/** The same lines through `tools/tracec/tracec.py trace` (G4). */
const reference = () => JSON.parse(readFileSync(root('fixtures/traces/pile10-reference.json'), 'utf8'));

describe('trace lines v1', () => {
  it('a recorded main_trace output gives tracec.py\'s trace, level, frames and events', () => {
    const trace = linesToTrace(recorded());
    const expected = reference();
    expect(trace.level).toEqual(expected.level);
    expect(trace.frames.length).toBe(192);
    expect(trace.frames).toEqual(expected.frames);
    expect(trace.events).toEqual(expected.events);
    expect(trace.events.at(-1)).toEqual({ tick: 191, kind: 'shot_end', shot: 0 });
  });

  it('parses each kind of line', () => {
    expect(parseTraceLine('trace 1\n')).toEqual({ kind: 'version', version: 1 });
    expect(parseTraceLine('material 3 1000')).toEqual({ kind: 'material', index: 3, score: 1000 });
    expect(parseTraceLine('body 7 1 2 10 -20 30 -40 polygon 2 1 2 -3 4')).toEqual({
      kind: 'body',
      body: {
        handle: 7,
        kind: 'block',
        material: 2,
        pose: { x: '10', y: '-20', re: '30', im: '-40' },
        shape: { type: 'polygon', vertices: [{ x: '1', y: '2' }, { x: '-3', y: '4' }] },
      },
    });
    expect(parseTraceLine('frame 4 11 -5 6 7 -8 0 12 1 2 3 4 1')).toEqual({
      kind: 'frame',
      frame: {
        tick: 4,
        bodies: [
          { handle: 11, x: '-5', y: '6', re: '7', im: '-8', asleep: false },
          { handle: 12, x: '1', y: '2', re: '3', im: '4', asleep: true },
        ],
      },
    });
    expect(parseTraceLine('frame 9')).toEqual({ kind: 'frame', frame: { tick: 9, bodies: [] } });
    expect(parseTraceLine('damage 83 5 298')).toEqual({ kind: 'event', event: { tick: 83, kind: 'damage', handle: 5, hp: 298 } });
    expect(parseTraceLine('destroyed 83 10')).toEqual({ kind: 'event', event: { tick: 83, kind: 'destroyed', handle: 10 } });
    expect(parseTraceLine('score 191 4000 5350')).toEqual({
      kind: 'event',
      event: { tick: 191, kind: 'score', points: 4000, total: 5350 },
    });
    expect(parseTraceLine('shot_end 191 2')).toEqual({ kind: 'event', event: { tick: 191, kind: 'shot_end', shot: 2 } });
  });

  it.each([
    '',
    '   Executing slingfall_replay',
    'Program output:',
    '5350',
    'frame 4 11 -5 6 7 -8',
    'frame 4 11 -5 6 7 -8 2',
    'frame x',
    'damage 83 5',
    'damage 83 -5 1',
    'body 1 3 0 0 0 1 0 ball 1',
    'body 1 1 0 0 0 1 0 capsule 1',
    'score 1 1.5 2',
  ])('ignores %j', (line) => expect(parseTraceLine(line)).toBeNull());

  it('the level header needs its version, level line and every body', () => {
    const header = new LevelHeader();
    expect(() => header.level()).toThrow('no `trace` / `level` header line');
    const lines = recorded().filter((l) => /^(trace|level|material|body) /.test(l));
    for (const line of lines.slice(0, -1)) header.push(parseTraceLine(line)!);
    expect(() => header.level()).toThrow('10 body lines, level has 11');
    header.push(parseTraceLine(lines.at(-1)!)!);
    expect(header.level()).toEqual(reference().level);
    header.push({ kind: 'version', version: 2 });
    expect(() => header.level()).toThrow('version 2, expected 1');
  });

  it('the start frame holds every dynamic body asleep at its level pose', () => {
    const level = reference().level;
    expect(startFrame(level)).toEqual(reference().frames[0]);
  });
});
