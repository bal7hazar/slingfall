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
/// `submit` / `submit_settled`: the program hash is not valid now (never pinned, past its grace
/// period, or revoked).
pub const SUBMIT_PROGRAM: felt252 = 'submit: program';

/// `submit_chunk`: the chain is not valid now (never pinned, past its grace, revoked), or no
/// marker is set.
pub const CHUNK_CHAIN: felt252 = 'chunk: chain';
/// `submit_chunk`: the transaction's `proof_facts` are not SNIP-36 facts (`verifier::parse_facts`).
pub const CHUNK_FACTS: felt252 = 'chunk: facts';
/// `submit_chunk`: the facts' virtual-OS program is not valid now.
pub const CHUNK_PROGRAM: felt252 = 'chunk: program';
/// `submit_chunk`: the facts' base block is younger than `BLOCK_HASH_BUFFER` blocks, or has no
/// hash.
pub const CHUNK_BASE_BLOCK: felt252 = 'chunk: base block';
/// `submit_chunk`: the chain's message with this payload is not among the facts' messages.
pub const CHUNK_MESSAGE: felt252 = 'chunk: message';
/// `submit_chunk`: an unknown kind.
pub const CHUNK_KIND: felt252 = 'chunk: kind';
/// `submit_chunk`: a payload of the wrong length or with impossible values (`chunks::parse`).
pub const CHUNK_PAYLOAD: felt252 = 'chunk: payload';
/// `submit_chunk`: another link is stored under the same key (the same one is a no-op).
pub const CHUNK_CONFLICT: felt252 = 'chunk: conflict';

/// `finalize`: the chain is not valid now.
pub const FINALIZE_CHAIN: felt252 = 'finalize: chain';
/// `finalize`: the inputs felts are not exactly one `Inputs`.
pub const FINALIZE_INPUTS: felt252 = 'finalize: inputs';
/// `finalize`: the outputs are not the level's, the inputs' (hash, player) or the chain's end.
pub const FINALIZE_OUTPUTS: felt252 = 'finalize: outputs';
/// `finalize`: no `init` of the level, or a state with neither a step nor an end (a broken or
/// unfinished chain).
pub const FINALIZE_LINK: felt252 = 'finalize: link';
/// `finalize`: a step's shot is before the previous one's, or not a shot of the inputs.
pub const FINALIZE_SHOT: felt252 = 'finalize: shot';
/// `finalize`: more than `chunks::MAX_EDGES` steps.
pub const FINALIZE_LENGTH: felt252 = 'finalize: length';
/// `pin_chain` with the zero address or bundle hash.
pub const CHAIN_ZERO: felt252 = 'chain: zero';

/// `expire`: the player's record on the level is not a provisional one above their settled best.
pub const EXPIRE_NONE: felt252 = 'expire: none';
/// `expire`: the provisional record is younger than `expire_delay`.
pub const EXPIRE_EARLY: felt252 = 'expire: early';

/// `pin_program` with the zero hash.
pub const PROGRAM_ZERO: felt252 = 'program: zero';
/// `upgrade` with the zero class hash.
pub const UPGRADE_ZERO: felt252 = 'upgrade: zero';
/// `accept_admin` by someone other than the pending admin (or with none pending).
pub const ADMIN_PENDING: felt252 = 'admin: pending';

/// An admin entry point called by someone other than the admin.
pub const ADMIN_CALLER: felt252 = 'admin: caller';
/// `constructor` / `set_admin` with the zero address.
pub const ADMIN_ZERO: felt252 = 'admin: zero';
