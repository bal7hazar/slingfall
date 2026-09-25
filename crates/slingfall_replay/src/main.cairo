//! Proof build: `main(level, inputs) -> outputs` at 60 Hz, no prints (`docs/DESIGN.md` D1).
//! Lot G4. The level logic is `slingfall_game::play::play` (lot G4b), shared with the trace build,
//! the chunked build and the contract; this file is only the executable entry point.

use slingfall_game::errors;
use slingfall_game::play::{NoopObserver, decode, play};
use slingfall_level::inputs::Inputs;
use slingfall_level::level::Level;
use slingfall_level::outputs::OutputsTrait;

#[cfg(test)]
mod tests;

/// Proof build. Arguments: `level` = the `Serde` felts of one `Level`, `inputs` = those of one
/// `Inputs` (both length-prefixed arrays on the command line). Returns the 10 felts of `Outputs`.
///
/// # Panics
/// `errors::LEVEL` / `errors::INPUTS` for felts that are not exactly one value; the level crate's
/// `level: *` / `inputs: *` messages for values that break its rules.
#[executable]
pub fn main(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252> {
    let level: Level = decode(level.span(), errors::LEVEL);
    let inputs: Inputs = decode(inputs.span(), errors::INPUTS);
    let mut obs: NoopObserver = Default::default();
    play(@level, @inputs, ref obs).to_felts()
}
