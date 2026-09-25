//! Panic messages of the level crate (`felt252` short strings, stable API, `AGENTS.md` §7).

/// `Level.version` is not `level::LEVEL_VERSION`.
pub const VERSION: felt252 = 'level: version';
/// `Level.shots` is outside `1..=5`, or `Level.projectiles` does not hold one kind per shot.
pub const SHOTS: felt252 = 'level: shots';
/// `Level.tick_cap` is `0` or above `level::TICK_CAP_MAX`.
pub const TICK_CAP: felt252 = 'level: tick cap';
/// A body names a material index that does not exist.
pub const MATERIAL: felt252 = 'level: material';
/// Empty `Level.bounds`, sling anchor or a non-static body outside of them.
pub const BOUNDS: felt252 = 'level: bounds';
/// A body `kind` other than 0 (static), 1 (block) or 2 (core).
pub const BODY_KIND: felt252 = 'level: body kind';
/// A polygon with fewer than three vertices.
pub const SHAPE: felt252 = 'level: shape';
/// `Level.pull_radius` is `0` or above `inputs::PULL_MAX`.
pub const PULL_RADIUS: felt252 = 'level: pull radius';

/// A pull component outside `[-PULL_MAX, PULL_MAX]`.
pub const INPUTS_PULL: felt252 = 'inputs: pull';
/// A shot delay above `inputs::DELAY_MAX`.
pub const INPUTS_DELAY: felt252 = 'inputs: delay';
/// More shots than `Level.shots`.
pub const INPUTS_SHOTS: felt252 = 'inputs: shots';

/// `Outputs::from_felts` was not given exactly `outputs::OUTPUTS_LEN` felts.
pub const OUTPUTS_LENGTH: felt252 = 'outputs: length';
/// `Outputs::from_felts` met a felt outside the range of its field (e.g. `won` not 0 or 1).
pub const OUTPUTS_FIELD: felt252 = 'outputs: field';
