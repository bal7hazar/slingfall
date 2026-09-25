# slingfall_testing

Development helpers shared by the tests and step probes of every crate (a dev-dependency only):
`opaque` routes probe inputs through a call the compiler cannot inline, so constant folding cannot
erase the measured work; `abs_diff`, `within`, `vec2_within`, `assert_approx` and
`assert_vec2_approx` compare raw Q32.32 values within a tolerance in raw units. Adapted from
rapier-cairo's `rapier_testing` and `rapier_golden::compare`. Test:
`snforge test -p slingfall_testing`.
