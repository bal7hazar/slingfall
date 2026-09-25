// Q32.32 arithmetic on raw values in `BigInt`, with the rounding of the Cairo `fixed` crate.

export const FRACTION_BITS = 32n;

/** 1.0 as a raw Q32.32 value. */
export const ONE_RAW = 1n << FRACTION_BITS;

/**
 * Product of two raw values: the exact product of the integers, floored, then one rescale.
 * `BigInt` `>>` is an arithmetic shift, so negative products round toward minus infinity.
 */
export function mulFloor(a: bigint, b: bigint): bigint {
  return (a * b) >> FRACTION_BITS;
}

/** Smallest `s` with `s * s >= n`, for `n >= 0` (Newton iteration on integers). */
export function isqrtCeil(n: bigint): bigint {
  if (n < 0n) throw new RangeError('isqrtCeil of a negative number');
  if (n < 2n) return n;
  let s = 1n << BigInt((n.toString(2).length + 1) >> 1);
  for (;;) {
    const next = (s + n / s) >> 1n;
    if (next >= s) break;
    s = next;
  }
  // `s` is now floor(sqrt(n)).
  return s * s === n ? s : s + 1n;
}
