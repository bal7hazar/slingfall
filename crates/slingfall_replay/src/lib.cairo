//! Slingfall replay: the same level logic in three builds (`docs/DESIGN.md` D1): the proof build
//! (`main`, no prints), the trace build (`main_trace`, the observer is the only place that prints)
//! and the chunked build (`init` / `step_chunk` on `rapier2d::WorldState`). Executable package,
//! kept out of the root workspace (`enable-gas = false`). Only the five executable entry points and
//! the `TraceObserver` live here; the level logic (`play`, `step_shot`, `ChunkState`) is the
//! `slingfall_game` library (lot G4b). Modules are pre-declared by the orchestrator
//! (`docs/PLAN.md`, lot G4).

pub mod chunk;
pub mod main;
pub mod outputs;
pub mod trace;

#[cfg(test)]
mod tests {
    /// Empty probe: the fixed overhead snforge charges to any test in this crate.
    #[test]
    fn steps_baseline() {}
}
