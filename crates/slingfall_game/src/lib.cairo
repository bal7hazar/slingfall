//! Slingfall level logic as a library (`docs/DESIGN.md` D1): the code the proof build, the trace
//! build, the chunked build and the contract's `simulate` share. `play` with an `Observer`, the
//! per-shot stepping `step_shot`, and the chunked `ChunkState` (lot G4b). The executables and the
//! trace observer are in the nested `slingfall_replay` package; the contract's hook calls `play`
//! with the `NoopObserver`. No `starknet` dependency (`AGENTS.md` §7).

pub mod chunk;
pub mod errors;
pub mod fixtures;
pub mod play;

#[cfg(test)]
mod tests {
    /// Empty probe: the fixed overhead snforge charges to any test in this crate.
    #[test]
    fn steps_baseline() {}
}
