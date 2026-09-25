import { describe, expect, it } from 'vitest';
import { fixedToNumber } from './types';

describe('fixedToNumber', () => {
  it.each([
    ['0', 0],
    ['4294967296', 1],
    ['-4294967296', -1],
    ['2147483648', 0.5],
    ['-2147483648', -0.5],
    ['1', 2 ** -32],
    ['-1', -(2 ** -32)],
    ['-9223372036854775808', -(2 ** 31)], // i64::MIN
    ['9223372036854775807', 2 ** 31], // i64::MAX, rounded to the nearest f64
    ['9007199254740993', 2 ** 21 + 2 ** -32], // 2^53 + 1: exact, a direct Number(raw) would round
  ])('%s -> %d', (raw, expected) => {
    expect(fixedToNumber(raw)).toBe(expected);
  });

  it('rejects a value that is not an integer string', () => {
    expect(() => fixedToNumber('1.5')).toThrow();
  });
});
