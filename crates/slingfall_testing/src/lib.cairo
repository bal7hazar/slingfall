//! Shared helpers for tests and step probes across the slingfall workspace (from
//! rapier-cairo's `rapier_testing` and `rapier_golden::compare`).

use fixed::Fixed;
use glam::Vec2;

/// Returns its argument through a call the compiler cannot inline.
///
/// Step probes must route their inputs through this function, otherwise constant
/// folding can erase the very computation the probe is meant to measure.
#[inline(never)]
pub fn opaque<T>(value: T) -> T {
    value
}

/// Absolute difference `|a - b|` of two raw Q32.32 values, without overflow for any pair of `i64`.
pub fn abs_diff(a: i64, b: i64) -> u64 {
    let (hi, lo) = if a < b {
        (b, a)
    } else {
        (a, b)
    };
    // `hi - lo` lies in `[0, 2^64)`: both conversions below always succeed.
    let wide: i128 = hi.into() - lo.into();
    let wide: u128 = wide.try_into().unwrap();
    wide.try_into().unwrap()
}

/// `true` when `actual` is within `tolerance` raw units of `expected` (bounds included).
pub fn within(actual: Fixed, expected: Fixed, tolerance: u64) -> bool {
    abs_diff(actual.raw, expected.raw) <= tolerance
}

/// Component-wise [`within`] for vectors.
pub fn vec2_within(actual: Vec2, expected: Vec2, tolerance: u64) -> bool {
    within(actual.x, expected.x, tolerance) && within(actual.y, expected.y, tolerance)
}

/// Panics unless `actual` is within `tolerance` raw units of `expected`.
pub fn assert_approx(actual: Fixed, expected: Fixed, tolerance: u64) {
    assert!(
        within(actual, expected, tolerance),
        "{} is not within {} raw units of {}",
        actual.raw,
        tolerance,
        expected.raw,
    );
}

/// Panics unless every component of `actual` is within `tolerance` raw units of `expected`.
pub fn assert_vec2_approx(actual: Vec2, expected: Vec2, tolerance: u64) {
    assert_approx(actual.x, expected.x, tolerance);
    assert_approx(actual.y, expected.y, tolerance);
}

#[cfg(test)]
mod tests {
    use fixed::Fixed;
    use glam::Vec2;
    use super::{abs_diff, assert_approx, assert_vec2_approx, opaque, vec2_within, within};

    /// Empty probe: the fixed overhead snforge charges to any test. Subtract it from the other
    /// entries of `steps/` to obtain the net cost of an operation.
    #[test]
    fn steps_baseline() {}

    #[test]
    fn test_opaque_is_identity() {
        assert_eq!(opaque(42_u64), 42);
    }

    #[test]
    fn test_abs_diff_extremes() {
        let cases: Array<(i64, i64, u64)> = array![
            (0, 0, 0), (3, -4, 7), (-4, 3, 7),
            (0x7fffffffffffffff, -0x8000000000000000, 0xffffffffffffffff),
        ];
        for (a, b, expected) in cases {
            assert_eq!(abs_diff(a, b), expected);
        }
    }

    #[test]
    fn test_within_bounds_included() {
        let one = Fixed { raw: 1 };
        let three = Fixed { raw: 3 };
        assert!(within(three, one, 2));
        assert!(!within(three, one, 1));
        assert!(vec2_within(Vec2 { x: one, y: three }, Vec2 { x: three, y: one }, 2));
        assert_approx(one, three, 2);
        assert_vec2_approx(Vec2 { x: one, y: one }, Vec2 { x: three, y: three }, 2);
    }

    #[test]
    #[should_panic]
    fn test_assert_approx_panics_outside() {
        assert_approx(Fixed { raw: 0 }, Fixed { raw: 3 }, 2);
    }
}
