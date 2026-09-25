import { describe, expect, it } from 'vitest';
import { ballDropProgram } from './program';

const frameOf = (line: string) => {
  const sample = ballDropProgram.lines.parse(line);
  return sample === null ? null : ballDropProgram.frame(sample);
};

describe('ballDropProgram', () => {
  const level = { scene: 3, ticks: 120 };

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
    expect(ballDropProgram.chunkArgs(level, ['7', '40', '-1'], null, 10)).toBe('2 3 10 1 3 7 40 -1');
  });

  it('reads the tick counter of the state', () => {
    expect(ballDropProgram.remainingTicks(level, ['v', '0'])).toBe(120);
    expect(ballDropProgram.remainingTicks(level, ['v', '115'])).toBe(5);
    expect(ballDropProgram.remainingTicks(level, ['v', '120'])).toBe(0);
  });
});
