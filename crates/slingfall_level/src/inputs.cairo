//! `Inputs` and `Shot` (`docs/DESIGN.md` D3): the player and the quantised pull of each shot.

use crate::errors;
use crate::hash::serde_hash;
use crate::level::Level;

/// Largest pull component, in pull units: a shot's `pull_x` and `pull_y` lie in
/// `[-PULL_MAX, PULL_MAX]`. Also the upper bound of `Level.pull_radius`.
pub const PULL_MAX: i16 = 1024;
/// Largest `Shot.delay`, in ticks before the release.
pub const DELAY_MAX: u16 = 60;

/// One shot: the pull of the sling, the ticks to wait before the release, and the reserved
/// ability tick (`0` = none, ignored in the MVP). Four felts.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Shot {
    pub pull_x: i16,
    pub pull_y: i16,
    pub delay: u16,
    pub ability_tick: u16,
}

/// The proven inputs of a replay. `player` is committed so that a proof cannot be resubmitted by
/// someone else.
#[derive(Drop, Serde, PartialEq, Debug)]
pub struct Inputs {
    pub player: felt252,
    pub shots: Array<Shot>,
}

pub trait InputsTrait {
    /// `inputs_hash`: `poseidon_hash_span` of the `Serde` felts (`player`, shot count, shots).
    fn hash(self: @Inputs) -> felt252;
    /// Panics (`errors::INPUTS_*`) unless there are at most `level.shots` shots, each with a pull
    /// inside `[-PULL_MAX, PULL_MAX]²` and a delay of at most `DELAY_MAX`. Fewer shots than
    /// `level.shots` is allowed.
    fn validate(self: @Inputs, level: @Level);
}

impl InputsImpl of InputsTrait {
    fn hash(self: @Inputs) -> felt252 {
        serde_hash(self)
    }

    fn validate(self: @Inputs, level: @Level) {
        let shots = self.shots.span();
        if shots.len() > (*level.shots).into() {
            core::panic_with_felt252(errors::INPUTS_SHOTS);
        }
        for shot in shots {
            let Shot { pull_x, pull_y, delay, .. } = *shot;
            if pull_x < -PULL_MAX || pull_x > PULL_MAX || pull_y < -PULL_MAX || pull_y > PULL_MAX {
                core::panic_with_felt252(errors::INPUTS_PULL);
            }
            if delay > DELAY_MAX {
                core::panic_with_felt252(errors::INPUTS_DELAY);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use slingfall_testing::opaque;
    use crate::hash::to_felts;
    use crate::level::tests::minimal_level;
    use super::{DELAY_MAX, Inputs, InputsTrait, PULL_MAX, Shot};

    const PLAYER: felt252 = 0x1234;

    fn shot(pull_x: i16, pull_y: i16, delay: u16) -> Shot {
        Shot { pull_x, pull_y, delay, ability_tick: 0 }
    }

    /// Inputs of `PLAYER` with the given shots, validated against a 3-shot level.
    fn validate(shots: Array<Shot>) {
        Inputs { player: PLAYER, shots }.validate(@minimal_level(3, 360, 1024, array![]));
    }

    #[test]
    fn test_felt_layout_and_negative_values() {
        // `[player, shot count, (pull_x, pull_y, delay, ability_tick)...]`, negative = `P - x`.
        let inputs = Inputs {
            player: PLAYER,
            shots: array![
                Shot { pull_x: -1, pull_y: 1024, delay: 60, ability_tick: 0 },
                Shot { pull_x: -1024, pull_y: 0, delay: 0, ability_tick: 7 },
            ],
        };
        assert_eq!(to_felts(@inputs), array![0x1234, 2, -1, 1024, 60, 0, -1024, 0, 0, 7]);
    }

    #[test]
    fn test_serde_round_trip() {
        let cases: Array<Array<Shot>> = array![
            array![], array![shot(-1024, 1024, 60)],
            array![shot(0, -1, 0), shot(1, 0, 1), shot(-5, 5, 9)],
        ];
        for shots in cases {
            let inputs = Inputs { player: PLAYER, shots };
            let felts = to_felts(@inputs);
            let mut span = felts.span();
            let back: Inputs = Serde::deserialize(ref span).unwrap();
            assert!(span.is_empty());
            assert_eq!(back, inputs);
        }
        let shot = Shot { pull_x: -3, pull_y: 4, delay: 5, ability_tick: 6 };
        let felts = to_felts(@shot);
        let mut span = felts.span();
        assert_eq!(Serde::<Shot>::deserialize(ref span).unwrap(), shot);
    }

    /// Golden `inputs_hash`: `tools/levelc/poseidon.py`'s `hash_span` of the same felts.
    #[test]
    fn test_inputs_hash_is_golden() {
        let inputs = Inputs { player: PLAYER, shots: array![shot(-100, 200, 3)] };
        let golden: felt252 = 0x4e24633b5c10cdb028cc0754eceb282d75631fb8a416890dea0e4ef604e45a0;
        assert_eq!(inputs.hash(), golden);
        let other = Inputs { player: PLAYER + 1, shots: array![shot(-100, 200, 3)] };
        assert!(other.hash() != golden);
    }

    #[test]
    fn test_validate_accepts_boundaries() {
        validate(array![]);
        validate(array![shot(0, 0, 0)]);
        // Every corner of `[-PULL_MAX, PULL_MAX]²`, the largest delay, three shots (=
        // level.shots).
        validate(
            array![
                shot(-PULL_MAX, -PULL_MAX, DELAY_MAX), shot(PULL_MAX, PULL_MAX, 0),
                shot(-PULL_MAX, PULL_MAX, 1),
            ],
        );
    }

    #[test]
    #[should_panic(expected: ('inputs: pull',))]
    fn test_validate_pull_x_above_max() {
        validate(array![shot(PULL_MAX + 1, 0, 0)]);
    }

    #[test]
    #[should_panic(expected: ('inputs: pull',))]
    fn test_validate_pull_x_below_min() {
        validate(array![shot(-PULL_MAX - 1, 0, 0)]);
    }

    #[test]
    #[should_panic(expected: ('inputs: pull',))]
    fn test_validate_pull_y_above_max() {
        validate(array![shot(0, 0, 0), shot(0, PULL_MAX + 1, 0)]);
    }

    #[test]
    #[should_panic(expected: ('inputs: pull',))]
    fn test_validate_pull_y_below_min() {
        validate(array![shot(0, -PULL_MAX - 1, 0)]);
    }

    #[test]
    #[should_panic(expected: ('inputs: pull',))]
    fn test_validate_pull_extreme_i16() {
        validate(array![shot(-0x8000, 0, 0)]);
    }

    #[test]
    #[should_panic(expected: ('inputs: delay',))]
    fn test_validate_delay_above_max() {
        validate(array![shot(0, 0, DELAY_MAX + 1)]);
    }

    #[test]
    #[should_panic(expected: ('inputs: shots',))]
    fn test_validate_more_shots_than_the_level() {
        validate(array![shot(0, 0, 0), shot(0, 0, 0), shot(0, 0, 0), shot(0, 0, 0)]);
    }

    #[test]
    fn steps_inputs_hash__3_shots() {
        let inputs = opaque(
            Inputs {
                player: PLAYER, shots: array![shot(-100, 200, 3), shot(0, 512, 0), shot(1, 2, 60)],
            },
        );
        opaque(inputs.hash());
    }

    #[test]
    fn steps_inputs_validate__3_shots() {
        let inputs = opaque(
            Inputs {
                player: PLAYER, shots: array![shot(-100, 200, 3), shot(0, 512, 0), shot(1, 2, 60)],
            },
        );
        let level = opaque(minimal_level(3, 360, 1024, array![]));
        inputs.validate(@level);
    }
}
