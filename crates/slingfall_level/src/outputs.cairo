//! `Outputs`, the 10-felt result of a replay (`docs/DESIGN.md` D4).

use crate::errors;

/// Number of felts of `Outputs`.
pub const OUTPUTS_LEN: usize = 10;
/// Position of `won` among the felts of `Outputs`.
const WON_INDEX: usize = 6;

/// What a proof commits to. Felt order: `[version, level_hash, seed, player, inputs_hash, score,
/// won, shots_used, ticks_run, final_state_hash]`. `final_state_hash` is the Poseidon hash of the
/// raw poses of the remaining dynamic bodies.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Outputs {
    pub version: u16,
    pub level_hash: felt252,
    pub seed: felt252,
    pub player: felt252,
    pub inputs_hash: felt252,
    pub score: u32,
    pub won: bool,
    pub shots_used: u8,
    pub ticks_run: u32,
    pub final_state_hash: felt252,
}

pub trait OutputsTrait {
    /// The 10 felts of D4, written field by field (no `Serde` machinery: one array build).
    fn to_felts(self: Outputs) -> Array<felt252>;
    /// Inverse of `to_felts`. Panics with `errors::OUTPUTS_LENGTH` unless there are exactly
    /// `OUTPUTS_LEN` felts, and with `errors::OUTPUTS_FIELD` when a felt does not fit its field
    /// (`won` must be 0 or 1).
    fn from_felts(felts: Span<felt252>) -> Outputs;
}

impl OutputsImpl of OutputsTrait {
    fn to_felts(self: Outputs) -> Array<felt252> {
        array![
            self.version.into(), self.level_hash, self.seed, self.player, self.inputs_hash,
            self.score.into(), if self.won {
                1
            } else {
                0
            }, self.shots_used.into(),
            self.ticks_run.into(), self.final_state_hash,
        ]
    }

    fn from_felts(felts: Span<felt252>) -> Outputs {
        if felts.len() != OUTPUTS_LEN {
            core::panic_with_felt252(errors::OUTPUTS_LENGTH);
        }
        // `Serde` reads any non-zero felt as `true`: `won` is checked here so that
        // `to_felts(from_felts(f)) == f`.
        let won = *felts[WON_INDEX];
        if won != 0 && won != 1 {
            core::panic_with_felt252(errors::OUTPUTS_FIELD);
        }
        let mut felts = felts;
        // `Serde` fails (`None`) for any other felt out of range of its field; the length was
        // checked, so that is the only way to fail here.
        Serde::<Outputs>::deserialize(ref felts).expect(errors::OUTPUTS_FIELD)
    }
}

#[cfg(test)]
mod tests {
    use slingfall_testing::opaque;
    use crate::hash::to_felts as serde_felts;
    use super::{OUTPUTS_LEN, Outputs, OutputsTrait};

    fn sample(won: bool) -> Outputs {
        Outputs {
            version: 1,
            level_hash: 0x11,
            seed: 0,
            player: 0x1234,
            inputs_hash: 0x22,
            score: 1_650,
            won,
            shots_used: 2,
            ticks_run: 431,
            final_state_hash: 0x33,
        }
    }

    #[test]
    fn test_to_felts_order() {
        // [version, level_hash, seed, player, inputs_hash, score, won, shots_used, ticks_run,
        // final_state_hash]
        let expected: Array<felt252> = array![1, 0x11, 0, 0x1234, 0x22, 1650, 1, 2, 431, 0x33];
        assert_eq!(sample(true).to_felts(), expected);
        assert_eq!(sample(true).to_felts().len(), OUTPUTS_LEN);
        assert_eq!(*sample(false).to_felts()[6], 0);
    }

    #[test]
    fn test_to_felts_is_the_serde_layout() {
        for won in array![false, true] {
            assert_eq!(sample(won).to_felts(), serde_felts(@sample(won)));
        }
    }

    #[test]
    fn test_from_felts_round_trip() {
        let extremes = Outputs {
            version: 0xffff,
            level_hash: -1,
            seed: -2,
            player: -3,
            inputs_hash: -4,
            score: 0xffffffff,
            won: true,
            shots_used: 0xff,
            ticks_run: 0xffffffff,
            final_state_hash: -5,
        };
        let cases: Array<Outputs> = array![sample(true), sample(false), extremes];
        for outputs in cases {
            assert_eq!(OutputsTrait::from_felts(outputs.to_felts().span()), outputs);
        }
    }

    #[test]
    #[should_panic(expected: ('outputs: length',))]
    fn test_from_felts_too_short() {
        let mut felts = sample(true).to_felts();
        let _ = felts.pop_front();
        OutputsTrait::from_felts(felts.span());
    }

    #[test]
    #[should_panic(expected: ('outputs: length',))]
    fn test_from_felts_too_long() {
        let mut felts = sample(true).to_felts();
        felts.append(0);
        OutputsTrait::from_felts(felts.span());
    }

    #[test]
    #[should_panic(expected: ('outputs: field',))]
    fn test_from_felts_won_not_a_bool() {
        let felts: Array<felt252> = array![1, 0x11, 0, 0x1234, 0x22, 1650, 2, 2, 431, 0x33];
        OutputsTrait::from_felts(felts.span());
    }

    #[test]
    #[should_panic(expected: ('outputs: field',))]
    fn test_from_felts_version_out_of_range() {
        let felts: Array<felt252> = array![0x10000, 0x11, 0, 0x1234, 0x22, 1650, 1, 2, 431, 0x33];
        OutputsTrait::from_felts(felts.span());
    }

    #[test]
    fn steps_outputs_to_felts() {
        opaque(opaque(sample(true)).to_felts());
    }

    #[test]
    fn steps_outputs_from_felts() {
        let felts = opaque(sample(true).to_felts());
        opaque(OutputsTrait::from_felts(felts.span()));
    }
}
