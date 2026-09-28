//! The measured alternatives and size fixtures of the S36a spike
//! (`docs/research/07-split-game-step.md`, "Layouts" and "Inventory"): layouts (a), (c), (d), (f),
//! the tick-hook emulation and the `Plus*` /
//! `Stage*` fixtures. Built only with the feature `probes` (`snforge test --features probes`);
//! `crate::lean` and `crate::classes` are the game's layouts.

pub mod hashes;
pub mod inventory;
pub mod layouts;
pub mod stages;
pub mod world;
