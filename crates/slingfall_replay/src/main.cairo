//! Proof build: `main(level, inputs) -> outputs` at 60 Hz, no prints (`docs/DESIGN.md` D1).
//! Lot G4.

/// Placeholder entry point with the D1 signature, so that the executable target builds before
/// G4: returns no outputs.
#[executable]
pub fn main(level: Array<felt252>, inputs: Array<felt252>) -> Array<felt252> {
    array![]
}
