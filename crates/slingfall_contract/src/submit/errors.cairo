//! Panic messages of the contract (`felt252` short strings, stable API, `AGENTS.md` §7). The level
//! crate's own messages (`level: *`, `inputs: *`, `outputs: *`) pass through unchanged.

/// `register_level`: the felts are not exactly one `Level`.
pub const REGISTER_FELTS: felt252 = 'register: felts';
/// `register_level`: a level with the same `level_hash` is already registered.
pub const REGISTER_EXISTS: felt252 = 'register: exists';
/// `set_level_active`: no level has this hash.
pub const LEVEL_UNKNOWN: felt252 = 'level: unknown';
/// `set_level_active`: the caller is neither the level's author nor the admin.
pub const LEVEL_CALLER: felt252 = 'level: caller';

/// `simulate`: no level has this hash (or its stored felts do not decode).
pub const SIMULATE_LEVEL: felt252 = 'simulate: level';
/// `simulate`: the admin has not set the class hash of `SlingfallSim` (`sim_class_hash`).
pub const SIMULATE_CLASS: felt252 = 'simulate: class';
/// `simulate`: the inputs felts are not exactly one `Inputs`.
pub const SIMULATE_INPUTS: felt252 = 'simulate: inputs';

/// `submit`: the claimed `level_hash` is not registered.
pub const SUBMIT_LEVEL: felt252 = 'submit: level';
/// `submit`: the level is registered but inactive.
pub const SUBMIT_INACTIVE: felt252 = 'submit: inactive';
/// `submit`: the claimed `player` is not the caller.
pub const SUBMIT_PLAYER: felt252 = 'submit: player';
/// `submit`: this `(level_hash, player, inputs_hash)` was already submitted.
pub const SUBMIT_NULLIFIER: felt252 = 'submit: nullifier';
/// `submit`: the active verifier rejected the evidence.
pub const SUBMIT_PROOF: felt252 = 'submit: proof';

/// An admin entry point called by someone other than the admin.
pub const ADMIN_CALLER: felt252 = 'admin: caller';
/// `constructor` / `set_admin` with the zero address.
pub const ADMIN_ZERO: felt252 = 'admin: zero';
