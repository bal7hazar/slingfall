//! Class-size fixtures of the `Slingfall` contract (lot G7b): Starknet contracts that expose the
//! contract's code one layer at a time, so that `tools/classsize/classsize.py` can report what each
//! layer costs in Sierra felts, CASM felts and class bytes against the Starknet limits. Not
//! published, not deployed; the real contracts are `slingfall_contract::submit::Slingfall` and
//! `slingfall_contract::simulate::class::SlingfallSim`.
//!
//! Every fixture embeds `base::BaseComponent` (the registry, `submit` and the admin, i.e. the
//! `Slingfall` contract without `simulate`) and adds a `simulate` entry point whose hook grows
//! layer by layer (`hooks`):
//!
//! | fixture | `simulate` runs |
//! |---|---|
//! | `SizeA_Registry` | no `simulate` |
//! | `SizeB_Decode` | `simulate::run` with the stub hook: `Level` / `Inputs` decode and validate |
//! | `SizeC_World` | + the world built from the level, no step (`hooks::WorldHook`) |
//! | `SizeC2_GameNew` | + `GameTrait::new` (its `settle` runs one `World::step`) |
//! | `SizeD_OneStep` | + one `World::step_with_force_events` |
//! | `SizeD2_OneTick` | + a launch and one `GameTrait::tick` (damage, calm, score) |
//! | `SizeE_Simulate` | the real `simulate` (`ReplaySimulateHook`, `slingfall_game::play`) |
//!
//! The two-class layout measured here by lot G7b (`SplitCore` + `SplitSim`) is now the real
//! contract (lot G7c): `Slingfall` library-calls `SlingfallSim` (`slingfall_contract::simulate::
//! class`), and `tools/classsize` measures both. `SizeE_Simulate` stays the one-class reference
//! (same code as `SlingfallSim` plus the registry) of the class-size ladder and of the steps of
//! the library call.

pub mod base;
pub mod fixtures;
pub mod hooks;
#[cfg(test)]
mod tests;
