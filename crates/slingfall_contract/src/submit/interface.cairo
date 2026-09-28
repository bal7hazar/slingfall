//! The interfaces of `Slingfall` (re-exported by `submit`): players (`ISlingfall`), the v1 admin
//! (`ISlingfallAdmin`), the settled tier's configuration (`ISlingfallSatellite`), v2 governance
//! (`ISlingfallGovernance`) and the v3 SNIP-36 tier (`ISlingfallProven`, `docs/contract-v3.md`),
//! with the constants of their API.

use slingfall_level::outputs::Outputs;
use starknet::{ClassHash, ContractAddress};
use crate::registry::{Best, LevelMeta};
use crate::verifier::{SatelliteConfig, VerifierKind};
use super::chunks::Edge;

/// Default `expire_delay`: a provisional record not settled within 24 h may be demoted.
pub const DEFAULT_EXPIRE_DELAY: u64 = 86_400;
/// `program_valid_until` of the current program.
pub const FOREVER: u64 = 0xffffffffffffffff;

/// States of a nullifier (the tier of an attempt).
pub mod nullifier {
    pub const NONE: u8 = 0;
    pub const ATTESTED: u8 = 1;
    /// The Satellite fact (`submit_settled`).
    pub const SETTLED: u8 = 2;
    /// A SNIP-36 chain (`finalize`).
    pub const PROVEN: u8 = 3;
}

/// `valid_until` of a set member replaced by a new pin: `now + grace_s`, saturating below
/// `FOREVER` (the grace of `pin_program`, `pin_chain`, `pin_virtual_os`).
pub fn grace_until(now: u64, grace_s: u64) -> u64 {
    if grace_s >= FOREVER - now {
        FOREVER - 1
    } else {
        now + grace_s
    }
}

/// Players' entry points and reads.
#[starknet::interface]
pub trait ISlingfall<TState> {
    /// Registers a level given as its `Serde` felts (`docs/DESIGN.md` D2) after
    /// `LevelTrait::validate`; returns its `level_hash`. The caller is the author; the level is
    /// active.
    fn register_level(ref self: TState, level: Array<felt252>) -> felt252;
    /// Opens or closes a level to submissions; by its author or the admin.
    fn set_level_active(ref self: TState, level_hash: felt252, active: bool);
    /// The level's metadata (all zero when unknown).
    fn level(self: @TState, level_hash: felt252) -> LevelMeta;
    /// The level's `Serde` felts (empty when unknown).
    fn level_data(self: @TState, level_hash: felt252) -> Array<felt252>;
    /// Replays `inputs` (the `Serde` felts of an `Inputs`) on a registered level through a library
    /// call to the `SlingfallSim` class (`sim_class_hash`) and sends the outputs felts to
    /// `simulate::MARKER` as an L2 to L1 message from this contract. Meant for the virtual OS.
    fn simulate(ref self: TState, level_hash: felt252, inputs: Array<felt252>) -> Outputs;
    /// Records a replay's `outputs` (the 10 felts of D4) as provisional once `evidence` convinces
    /// the active verifier: `[program_hash, expiry, r, s]` for `Stub` (the attestation of
    /// `verifier::attestation_message`, its program valid now), nothing for `Snip36`; `Satellite`
    /// refuses everything. The caller must be `outputs.player`.
    fn submit(ref self: TState, outputs: Array<felt252>, evidence: Array<felt252>);
    /// Records `outputs` as settled for `outputs.player`, whoever the caller (a relay): the
    /// Atlantic fact of the run of `c1main` (program `child_program_hash`, valid now) on `args =
    /// [len(level), level..., len(inputs), inputs...]` (the `Serde` felts of the level and of the
    /// `Inputs`, as `tracec.py args` writes them) must be on the Satellite. Also settles a
    /// provisional record of the same attempt.
    fn submit_settled(
        ref self: TState,
        outputs: Array<felt252>,
        args: Array<felt252>,
        child_program_hash: felt252,
    );
    /// Demotes `player`'s provisional record on the level, older than `expire_delay` and never
    /// settled, to their settled best (and their provisional-board row with it). Anyone may call.
    fn expire(ref self: TState, level_hash: felt252, player: ContractAddress);
    /// The tier of an attempt: `nullifier::NONE`, `ATTESTED`, `SETTLED` (the Satellite fact) or
    /// `PROVEN` (SNIP-36).
    fn attempt(
        self: @TState, level_hash: felt252, player: ContractAddress, inputs_hash: felt252,
    ) -> u8;
    /// `player`'s best validated attempt on the level, either tier (all zero when none).
    fn best(self: @TState, player: ContractAddress, level_hash: felt252) -> Best;
    /// `player`'s best settled attempt on the level (all zero when none).
    fn best_settled(self: @TState, player: ContractAddress, level_hash: felt252) -> Best;
    /// Top `registry::LEADERBOARD_SIZE` settled won attempts, by decreasing score.
    fn leaderboard(self: @TState, level_hash: felt252) -> Array<(ContractAddress, u32)>;
    /// Top `registry::LEADERBOARD_SIZE` won `best` records of either tier, by decreasing score.
    fn leaderboard_provisional(self: @TState, level_hash: felt252) -> Array<(ContractAddress, u32)>;
}

/// Admin configuration: the verifier and its keys (the v1 interface, which `slingfall_sizes`'
/// fixtures implement; v2 semantics in the comments).
#[starknet::interface]
pub trait ISlingfallAdmin<TState> {
    fn admin(self: @TState) -> ContractAddress;
    fn virtual_os_hash(self: @TState) -> felt252;
    fn sim_class_hash(self: @TState) -> ClassHash;
    fn verifier(self: @TState) -> VerifierKind;
    fn attestation_key(self: @TState) -> felt252;
    /// Starts a two-step transfer: `admin` becomes the pending admin until it calls
    /// `ISlingfallGovernance::accept_admin` (proposing the current admin cancels it).
    fn set_admin(ref self: TState, admin: ContractAddress);
    /// The virtual-OS program hash the SNIP-36 proof facts must carry (versioned per Starknet
    /// release).
    fn set_virtual_os_hash(ref self: TState, virtual_os_hash: felt252);
    /// The class hash of `SlingfallSim`, the class `simulate` library-calls (zero: `simulate`
    /// panics `errors::SIMULATE_CLASS`).
    fn set_sim_class_hash(ref self: TState, sim_class_hash: ClassHash);
    fn set_verifier(ref self: TState, verifier: VerifierKind);
    /// Stark-curve public key of the attestations; bumps `attestation_epoch`, so that every
    /// earlier attestation (of any key) stops verifying.
    fn set_attestation_key(ref self: TState, attestation_key: felt252);
}

/// Admin configuration of the settled tier (apart from `ISlingfallAdmin`, which
/// `slingfall_sizes`' fixtures implement).
#[starknet::interface]
pub trait ISlingfallSatellite<TState> {
    fn satellite_config(self: @TState) -> SatelliteConfig;
    /// The constants of `SatelliteVerifier` (the two bootloaders, the Satellite's address); admin
    /// only.
    fn set_satellite_config(ref self: TState, config: SatelliteConfig);
}

/// Contract v2's governance: the program set, the attestation epoch, the expiry delay, the admin
/// transfer and the upgrade.
#[starknet::interface]
pub trait ISlingfallGovernance<TState> {
    fn pending_admin(self: @TState) -> ContractAddress;
    /// The pending admin takes over.
    fn accept_admin(ref self: TState);
    /// Replaces this contract's class (`replace_class_syscall`); admin only.
    fn upgrade(ref self: TState, class_hash: ClassHash);
    /// The last pinned program (zero when none, or revoked).
    fn current_program(self: @TState) -> felt252;
    /// Until when `program_hash` is accepted: valid while `block_timestamp < valid_until`
    /// (`FOREVER` for the current program, `0` never pinned or revoked).
    fn program_valid_until(self: @TState, program_hash: felt252) -> u64;
    /// `program_hash` becomes the current program; the previous one stays valid for `grace_s`
    /// seconds (`0`: invalid at once). Admin only.
    fn pin_program(ref self: TState, program_hash: felt252, grace_s: u64);
    /// `program_hash` is invalid at once (and no longer current). Admin only.
    fn revoke_program(ref self: TState, program_hash: felt252);
    /// The epoch the attestations must name (the number of `set_attestation_key` calls).
    fn attestation_epoch(self: @TState) -> u64;
    /// The age (seconds) after which an unsettled provisional record may be `expire`d.
    fn expire_delay(self: @TState) -> u64;
    fn set_expire_delay(ref self: TState, expire_delay: u64);
}

/// Contract v3: the SNIP-36 tier (`docs/contract-v3.md`). A shot proven as a chain of virtual
/// transactions of a chain contract (`init`, `step_chunk` × n, `outputs`; research 07 §4), each
/// proof's message submitted through `submit_chunk`, then linked and recorded by `finalize`.
#[starknet::interface]
pub trait ISlingfallProven<TState> {
    /// Stores one link of a chain from the transaction's `proof_facts`: the facts are well formed,
    /// their virtual-OS program is valid now, their base block is at least
    /// `verifier::BLOCK_HASH_BUFFER` blocks old, and `message_hash(chain, chunk_marker, payload)`
    /// is among their messages; `chain` is valid now. By `kind` (`chunks::kind`): `INIT`
    /// `[LEVEL_HASH, STATE_OUT_HASH]`, `STEP` `[STATE_IN_HASH, INPUTS_HASH, shot, k,
    /// STATE_OUT_HASH]`, `OUTPUTS` `[STATE_IN_HASH, INPUTS_HASH, outputs...]`. Idempotent, any
    /// order, any caller; several per transaction when the proof holds several messages.
    fn submit_chunk(ref self: TState, chain: ContractAddress, kind: u8, payload: Array<felt252>);
    /// Walks `chain`'s links from the `init` of `level_hash` through at most
    /// `chunks::MAX_EDGES` steps of `poseidon(inputs)` (shots in order, each below the number of
    /// shots) to an `outputs` link whose outputs are `outputs`, then records them as proven for
    /// `outputs.player` (the player of `inputs`), whoever the caller. `chain` must be valid now.
    /// Upgrades an attested attempt; refuses a settled or proven one.
    fn finalize(
        ref self: TState,
        chain: ContractAddress,
        level_hash: felt252,
        inputs: Array<felt252>,
        outputs: Array<felt252>,
    );
    /// `init`'s state hash for the level on `chain` (zero when none).
    fn chunk_start(self: @TState, chain: ContractAddress, level_hash: felt252) -> felt252;
    /// The step from `state_in_hash` of the attempt `inputs_hash` on `chain` (zero when none).
    fn chunk_edge(
        self: @TState, chain: ContractAddress, inputs_hash: felt252, state_in_hash: felt252,
    ) -> Edge;
    /// `poseidon(outputs felts)` of the `outputs` link from `state_in_hash` (zero when none).
    fn chunk_end(
        self: @TState, chain: ContractAddress, inputs_hash: felt252, state_in_hash: felt252,
    ) -> felt252;
    /// `to_address` of the chains' messages (zero: every chunk is refused).
    fn chunk_marker(self: @TState) -> felt252;
    fn set_chunk_marker(ref self: TState, marker: felt252);
    /// The last pinned chain (zero when none, or revoked).
    fn current_chain(self: @TState) -> ContractAddress;
    /// Until when `chain` is accepted (`FOREVER` for the current one, `0` never pinned or
    /// revoked); the same rule as `program_valid_until`.
    fn chain_valid_until(self: @TState, chain: ContractAddress) -> u64;
    /// The class-hash bundle `chain` library-calls, as the admin declared it (the
    /// `program_hash` of the records it proves).
    fn chain_bundle(self: @TState, chain: ContractAddress) -> felt252;
    /// `chain` (one deployment of a release's class bundle `bundle_hash`) becomes current; the
    /// previous one stays valid for `grace_s` seconds. Admin only.
    fn pin_chain(ref self: TState, chain: ContractAddress, bundle_hash: felt252, grace_s: u64);
    /// `chain` is invalid at once: its links no longer finalize. Admin only.
    fn revoke_chain(ref self: TState, chain: ContractAddress);
    /// The last pinned virtual-OS program hash (zero when none, or revoked).
    fn current_virtual_os(self: @TState) -> felt252;
    fn virtual_os_valid_until(self: @TState, program_hash: felt252) -> u64;
    /// `program_hash` becomes the current virtual-OS program, the previous one valid for
    /// `grace_s` seconds. Admin only.
    fn pin_virtual_os(ref self: TState, program_hash: felt252, grace_s: u64);
    fn revoke_virtual_os(ref self: TState, program_hash: felt252);
}
