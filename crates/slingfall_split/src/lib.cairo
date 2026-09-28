//! Spike S36a: the game's chunk on declared classes (SNIP-36 path), sizes and steps measured
//! (`docs/research/07-split-game-step.md`). Not published; built as its own workspace on
//! rapier2d alpha.7 (the game crates through `shims/`) until lot B5 bumps the root workspace.

pub mod chunk;
pub mod classes;
pub mod hashes;
pub mod init;
pub mod inventory;
pub mod lean;
pub mod rules;
pub mod stages;
pub mod world;
