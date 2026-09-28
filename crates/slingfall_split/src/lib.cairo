//! The game's chunk on declared classes (SNIP-36 path), sizes and steps measured
//! (`docs/research/07-split-game-step.md`). Not published.
//!
//! * [`lean::WorldClass`]: layout (e), the game's layout. The class keeps the world for the chunk,
//!   calls [`lean::RulesClass`] once per tick and crosses the world to [`classes::EditClass`] on
//!   the ticks that edit it. Its size is gated at 78,000 CASM felts (`tools/classsize`), every
//!   other class at 73,728.
//! * [`classes::FallbackGame`] with [`classes::StepClass`]: layout (b), the fallback that passes
//!   73,728 everywhere, at twice the steps.
//! * [`chain::SplitChain`]: the three proven transactions (`init`, `step_chunk`, `outputs`).
//! * [`hashes`]: every declared class's hash, pinned in one module.
//! * `probes` (feature `probes`): the measured alternatives, never in the default build.

pub mod chain;
pub mod chunk;
pub mod classes;
pub mod hashes;
pub mod init;
pub mod lean;
#[cfg(feature: 'probes')]
pub mod probes;
pub mod rules;
pub mod world;
