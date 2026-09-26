//! Panic messages of the replay executables and of the shared level logic (`felt252` short
//! strings, stable API, `AGENTS.md` §7).

/// The `level` argument is not exactly the felts of one `Level`.
pub const LEVEL: felt252 = 'replay: level';
/// The `inputs` argument is not exactly the felts of one `Inputs`.
pub const INPUTS: felt252 = 'replay: inputs';
/// The `state` argument of `step_chunk` is not exactly one `ChunkState` of this version.
pub const STATE: felt252 = 'replay: state';
/// `step_chunk`'s `shot` is not the shot in progress, is past the inputs, or the level is over.
pub const SHOT: felt252 = 'replay: shot';
