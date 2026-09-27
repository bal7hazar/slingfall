//! The `Slingfall` contract, v2 (`docs/DESIGN.md` D9, `docs/contract-v2.md`): level registry,
//! `simulate` (run in the SNIP-36 virtual OS), `submit` (the provisional tier: `player == caller`,
//! nullifier `poseidon(level_hash, player, inputs_hash)`, the active `Verifier`),
//! `submit_settled` (the settled tier: the Atlantic fact on the Satellite, recorded for
//! `claim.player` whoever sends it), a set of accepted programs with a grace period, per-tier
//! records and leaderboards, `expire`, a two-step admin transfer and `upgrade`.
//!
//! Two tiers: an attempt validated by an attestation or SNIP-36 is *provisional*; one validated by
//! `SatelliteVerifier` is *settled*. A nullifier moves `NONE -> ATTESTED -> SETTLED` or `NONE ->
//! SETTLED`: the only second submission of an attempt is its settlement. `best` and the
//! provisional board rank each player's best of either tier; `best_settled` and `leaderboard`
//! only settled attempts, so a provisional record never hides a settled one.

use slingfall_level::outputs::Outputs;
use starknet::{ClassHash, ContractAddress};
use crate::registry::{Best, LevelMeta};
use crate::verifier::{SatelliteConfig, VerifierKind};

pub mod errors;
#[cfg(test)]
pub mod fixtures;
#[cfg(test)]
mod tests;

/// Default `expire_delay`: a provisional record not settled within 24 h may be demoted.
pub const DEFAULT_EXPIRE_DELAY: u64 = 86_400;
/// `program_valid_until` of the current program.
pub const FOREVER: u64 = 0xffffffffffffffff;

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
    /// The tier of an attempt: `nullifier::NONE`, `ATTESTED` or `SETTLED`.
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

/// States of a nullifier (the tier of an attempt).
pub mod nullifier {
    pub const NONE: u8 = 0;
    pub const ATTESTED: u8 = 1;
    pub const SETTLED: u8 = 2;
}

#[starknet::contract]
pub mod Slingfall {
    use core::num::traits::{Bounded, Zero};
    use core::poseidon::poseidon_hash_span;
    use slingfall_level::level::{Level, LevelTrait};
    use slingfall_level::outputs::{Outputs, OutputsTrait};
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait,
    };
    use starknet::syscalls::{replace_class_syscall, send_message_to_l1_syscall};
    use starknet::{
        ClassHash, ContractAddress, SyscallResultTrait, get_block_number, get_block_timestamp,
        get_caller_address, get_contract_address, get_execution_info,
    };
    use crate::registry::{Best, Entry, LevelMeta, improves_best, insert, remove};
    use crate::simulate::MARKER;
    use crate::simulate::class::{ISlingfallSimDispatcherTrait, ISlingfallSimLibraryDispatcher};
    use crate::verifier::{
        AttestationVerifier, SatelliteConfig, SatelliteVerifier, Snip36Verifier, Verifier,
        VerifierKind,
    };
    use super::{DEFAULT_EXPIRE_DELAY, FOREVER, errors, nullifier};

    #[storage]
    struct Storage {
        admin: ContractAddress,
        pending_admin: ContractAddress,
        virtual_os_hash: felt252,
        /// The class hash of `SlingfallSim` (`simulate` library-calls it).
        sim_class_hash: ClassHash,
        verifier: VerifierKind,
        attestation_key: felt252,
        attestation_epoch: u64,
        satellite: SatelliteConfig,
        /// `c1main` program hash -> `valid_until` (block timestamp, exclusive).
        programs: Map<felt252, u64>,
        current_program: felt252,
        expire_delay: u64,
        levels: Map<felt252, LevelMeta>,
        /// `(level_hash, i)` -> the level's `i`-th felt: one storage write per felt (a
        /// `Vec::push` costs a length read and two writes).
        level_felts: Map<(felt252, u32), felt252>,
        level_len: Map<felt252, u32>,
        /// `nullifier::{NONE, ATTESTED, SETTLED}`.
        nullifiers: Map<felt252, u8>,
        /// Either tier.
        best: Map<(ContractAddress, felt252), Best>,
        best_settled: Map<(ContractAddress, felt252), Best>,
        boards_settled: Map<felt252, Vec<Entry>>,
        boards_provisional: Map<felt252, Vec<Entry>>,
    }

    #[event]
    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub enum Event {
        LevelRegistered: LevelRegistered,
        LevelActiveSet: LevelActiveSet,
        LevelValidated: LevelValidated,
        RecordExpired: RecordExpired,
        ProgramPinned: ProgramPinned,
        ProgramRevoked: ProgramRevoked,
        AttestationKeySet: AttestationKeySet,
        AdminTransferStarted: AdminTransferStarted,
        AdminTransferred: AdminTransferred,
        Upgraded: Upgraded,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct LevelRegistered {
        #[key]
        pub level_hash: felt252,
        pub author: ContractAddress,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct LevelActiveSet {
        #[key]
        pub level_hash: felt252,
        pub active: bool,
    }

    /// A validated attempt (emitted by every accepted submission, record or not).
    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct LevelValidated {
        #[key]
        pub player: ContractAddress,
        #[key]
        pub level_hash: felt252,
        pub inputs_hash: felt252,
        pub score: u32,
        pub won: bool,
        /// Validated by the Satellite fact (else by an attestation or SNIP-36).
        pub settled: bool,
        /// `Best::program_hash`.
        pub program_hash: felt252,
    }

    /// `expire` demoted a provisional record (`inputs_hash`) to the settled best.
    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct RecordExpired {
        #[key]
        pub player: ContractAddress,
        #[key]
        pub level_hash: felt252,
        pub inputs_hash: felt252,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct ProgramPinned {
        #[key]
        pub program_hash: felt252,
        /// The former current program (zero when none or the same), valid until
        /// `previous_valid_until`.
        pub previous: felt252,
        pub previous_valid_until: u64,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct ProgramRevoked {
        #[key]
        pub program_hash: felt252,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct AttestationKeySet {
        pub attestation_key: felt252,
        pub epoch: u64,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct AdminTransferStarted {
        pub admin: ContractAddress,
        pub pending: ContractAddress,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct AdminTransferred {
        pub previous: ContractAddress,
        pub admin: ContractAddress,
    }

    #[derive(Drop, PartialEq, Debug, starknet::Event)]
    pub struct Upgraded {
        pub class_hash: ClassHash,
    }

    /// The provisional verifier starts as the attestation (`Stub`) with no key, no program is
    /// pinned: nothing is accepted until the admin configures them.
    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        assert(admin.is_non_zero(), errors::ADMIN_ZERO);
        self.admin.write(admin);
        self.verifier.write(VerifierKind::Stub);
        self.expire_delay.write(DEFAULT_EXPIRE_DELAY);
    }

    #[abi(embed_v0)]
    impl SlingfallImpl of super::ISlingfall<ContractState> {
        fn register_level(ref self: ContractState, level: Array<felt252>) -> felt252 {
            let mut felts = level.span();
            let decoded: Option<Level> = Serde::deserialize(ref felts);
            let Some(decoded) = decoded else {
                core::panic_with_felt252(errors::REGISTER_FELTS)
            };
            assert(felts.is_empty(), errors::REGISTER_FELTS);
            decoded.validate();
            let level_hash = decoded.hash();
            let meta = self.levels.read(level_hash);
            assert(meta.version == 0, errors::REGISTER_EXISTS);
            let author = get_caller_address();
            self
                .levels
                .write(
                    level_hash,
                    LevelMeta {
                        author,
                        version: decoded.version,
                        active: true,
                        registered_at: get_block_timestamp(),
                    },
                );
            let mut i: u32 = 0;
            for felt in level {
                self.level_felts.write((level_hash, i), felt);
                i += 1;
            }
            self.level_len.write(level_hash, i);
            self.emit(LevelRegistered { level_hash, author });
            level_hash
        }

        fn set_level_active(ref self: ContractState, level_hash: felt252, active: bool) {
            let mut meta = self.levels.read(level_hash);
            assert(meta.version != 0, errors::LEVEL_UNKNOWN);
            let caller = get_caller_address();
            assert(caller == meta.author || caller == self.admin.read(), errors::LEVEL_CALLER);
            meta.active = active;
            self.levels.write(level_hash, meta);
            self.emit(LevelActiveSet { level_hash, active });
        }

        fn level(self: @ContractState, level_hash: felt252) -> LevelMeta {
            self.levels.read(level_hash)
        }

        fn level_data(self: @ContractState, level_hash: felt252) -> Array<felt252> {
            read_level(self, level_hash)
        }

        fn simulate(
            ref self: ContractState, level_hash: felt252, inputs: Array<felt252>,
        ) -> Outputs {
            let level = read_level(@self, level_hash);
            assert(!level.is_empty(), errors::SIMULATE_LEVEL);
            let class_hash = self.sim_class_hash.read();
            assert(class_hash.is_non_zero(), errors::SIMULATE_CLASS);
            let outputs = ISlingfallSimLibraryDispatcher { class_hash }.simulate(level, inputs);
            send_message_to_l1_syscall(MARKER, outputs.to_felts().span()).unwrap_syscall();
            outputs
        }

        fn submit(ref self: ContractState, outputs: Array<felt252>, evidence: Array<felt252>) {
            let claim = OutputsTrait::from_felts(outputs.span());
            let (player, _) = admit(ref self, claim, false);
            let (valid, program_hash) = match self.verifier.read() {
                VerifierKind::Snip36 => {
                    let facts = get_execution_info().unbox().tx_info.unbox().proof_facts;
                    let mut verifier = Snip36Verifier {
                        virtual_os_hash: self.virtual_os_hash.read(),
                        from: get_contract_address().into(),
                        facts,
                    };
                    (verifier.check(claim, evidence.span()), self.sim_class_hash.read().into())
                },
                VerifierKind::Stub => {
                    assert(evidence.len() == 4, errors::SUBMIT_PROOF);
                    let program_hash = *evidence[0];
                    assert_program(@self, program_hash);
                    let mut verifier = AttestationVerifier {
                        public_key: self.attestation_key.read(),
                        chain_id: get_execution_info().unbox().tx_info.unbox().chain_id,
                        contract: get_contract_address().into(),
                        epoch: self.attestation_epoch.read(),
                        now: get_block_timestamp(),
                    };
                    (verifier.check(claim, evidence.span()), program_hash)
                },
                VerifierKind::Satellite => (false, 0),
            };
            assert(valid, errors::SUBMIT_PROOF);
            record(ref self, claim, player, false, false, program_hash);
        }

        fn submit_settled(
            ref self: ContractState,
            outputs: Array<felt252>,
            args: Array<felt252>,
            child_program_hash: felt252,
        ) {
            let claim = OutputsTrait::from_felts(outputs.span());
            let (player, upgrade) = admit(ref self, claim, true);
            assert_program(@self, child_program_hash);
            let mut verifier = SatelliteVerifier {
                config: self.satellite.read(), child_program_hash,
            };
            assert(verifier.check(claim, args.span()), errors::SUBMIT_PROOF);
            record(ref self, claim, player, true, upgrade, child_program_hash);
        }

        fn expire(ref self: ContractState, level_hash: felt252, player: ContractAddress) {
            let key = (player, level_hash);
            let best = self.best.read(key);
            let settled = self.best_settled.read(key);
            assert(!best.settled && best != settled, errors::EXPIRE_NONE);
            let age = get_block_timestamp() - best.timestamp;
            assert(age >= self.expire_delay.read(), errors::EXPIRE_EARLY);
            self.best.write(key, settled);
            if best.won {
                let score = if settled.won {
                    Some(settled.score)
                } else {
                    None
                };
                update_board(ref self, false, level_hash, player, score);
            }
            self.emit(RecordExpired { player, level_hash, inputs_hash: best.inputs_hash });
        }

        fn attempt(
            self: @ContractState,
            level_hash: felt252,
            player: ContractAddress,
            inputs_hash: felt252,
        ) -> u8 {
            self
                .nullifiers
                .read(poseidon_hash_span([level_hash, player.into(), inputs_hash].span()))
        }

        fn best(self: @ContractState, player: ContractAddress, level_hash: felt252) -> Best {
            self.best.read((player, level_hash))
        }

        fn best_settled(
            self: @ContractState, player: ContractAddress, level_hash: felt252,
        ) -> Best {
            self.best_settled.read((player, level_hash))
        }

        fn leaderboard(self: @ContractState, level_hash: felt252) -> Array<(ContractAddress, u32)> {
            rows(read_board(self, true, level_hash))
        }

        fn leaderboard_provisional(
            self: @ContractState, level_hash: felt252,
        ) -> Array<(ContractAddress, u32)> {
            rows(read_board(self, false, level_hash))
        }
    }

    #[abi(embed_v0)]
    impl SlingfallAdminImpl of super::ISlingfallAdmin<ContractState> {
        fn admin(self: @ContractState) -> ContractAddress {
            self.admin.read()
        }

        fn virtual_os_hash(self: @ContractState) -> felt252 {
            self.virtual_os_hash.read()
        }

        fn sim_class_hash(self: @ContractState) -> ClassHash {
            self.sim_class_hash.read()
        }

        fn verifier(self: @ContractState) -> VerifierKind {
            self.verifier.read()
        }

        fn attestation_key(self: @ContractState) -> felt252 {
            self.attestation_key.read()
        }

        fn set_admin(ref self: ContractState, admin: ContractAddress) {
            assert_admin(@self);
            assert(admin.is_non_zero(), errors::ADMIN_ZERO);
            self.pending_admin.write(admin);
            self.emit(AdminTransferStarted { admin: self.admin.read(), pending: admin });
        }

        fn set_virtual_os_hash(ref self: ContractState, virtual_os_hash: felt252) {
            assert_admin(@self);
            self.virtual_os_hash.write(virtual_os_hash);
        }

        fn set_sim_class_hash(ref self: ContractState, sim_class_hash: ClassHash) {
            assert_admin(@self);
            self.sim_class_hash.write(sim_class_hash);
        }

        fn set_verifier(ref self: ContractState, verifier: VerifierKind) {
            assert_admin(@self);
            self.verifier.write(verifier);
        }

        fn set_attestation_key(ref self: ContractState, attestation_key: felt252) {
            assert_admin(@self);
            let epoch = self.attestation_epoch.read() + 1;
            self.attestation_key.write(attestation_key);
            self.attestation_epoch.write(epoch);
            self.emit(AttestationKeySet { attestation_key, epoch });
        }
    }

    #[abi(embed_v0)]
    impl SlingfallSatelliteImpl of super::ISlingfallSatellite<ContractState> {
        fn satellite_config(self: @ContractState) -> SatelliteConfig {
            self.satellite.read()
        }

        fn set_satellite_config(ref self: ContractState, config: SatelliteConfig) {
            assert_admin(@self);
            self.satellite.write(config);
        }
    }

    #[abi(embed_v0)]
    impl SlingfallGovernanceImpl of super::ISlingfallGovernance<ContractState> {
        fn pending_admin(self: @ContractState) -> ContractAddress {
            self.pending_admin.read()
        }

        fn accept_admin(ref self: ContractState) {
            let caller = get_caller_address();
            let pending = self.pending_admin.read();
            assert(pending.is_non_zero() && caller == pending, errors::ADMIN_PENDING);
            let previous = self.admin.read();
            self.admin.write(caller);
            self.pending_admin.write(Zero::zero());
            self.emit(AdminTransferred { previous, admin: caller });
        }

        fn upgrade(ref self: ContractState, class_hash: ClassHash) {
            assert_admin(@self);
            assert(class_hash.is_non_zero(), errors::UPGRADE_ZERO);
            replace_class_syscall(class_hash).unwrap_syscall();
            self.emit(Upgraded { class_hash });
        }

        fn current_program(self: @ContractState) -> felt252 {
            self.current_program.read()
        }

        fn program_valid_until(self: @ContractState, program_hash: felt252) -> u64 {
            self.programs.read(program_hash)
        }

        fn pin_program(ref self: ContractState, program_hash: felt252, grace_s: u64) {
            assert_admin(@self);
            assert(program_hash != 0, errors::PROGRAM_ZERO);
            let mut previous = self.current_program.read();
            let mut previous_valid_until = 0;
            if previous == program_hash {
                previous = 0;
            } else if previous != 0 {
                let now = get_block_timestamp();
                previous_valid_until =
                    if grace_s >= Bounded::<u64>::MAX - now {
                        FOREVER - 1
                    } else {
                        now + grace_s
                    };
                self.programs.write(previous, previous_valid_until);
            }
            self.programs.write(program_hash, FOREVER);
            self.current_program.write(program_hash);
            self.emit(ProgramPinned { program_hash, previous, previous_valid_until });
        }

        fn revoke_program(ref self: ContractState, program_hash: felt252) {
            assert_admin(@self);
            self.programs.write(program_hash, 0);
            if self.current_program.read() == program_hash {
                self.current_program.write(0);
            }
            self.emit(ProgramRevoked { program_hash });
        }

        fn attestation_epoch(self: @ContractState) -> u64 {
            self.attestation_epoch.read()
        }

        fn expire_delay(self: @ContractState) -> u64 {
            self.expire_delay.read()
        }

        fn set_expire_delay(ref self: ContractState, expire_delay: u64) {
            assert_admin(@self);
            self.expire_delay.write(expire_delay);
        }
    }

    fn assert_admin(self: @ContractState) {
        assert(get_caller_address() == self.admin.read(), errors::ADMIN_CALLER);
    }

    /// `program_hash` is in the program set now.
    fn assert_program(self: @ContractState, program_hash: felt252) {
        assert(self.programs.read(program_hash) > get_block_timestamp(), errors::SUBMIT_PROGRAM);
    }

    /// The checks before any verifier: the level is registered and active, the claim is the
    /// caller's (provisional only: a settled claim is recorded for its player whoever sends it,
    /// the fact binds the player), and the nullifier admits this tier (a new attempt, or the
    /// settlement of an attested one: `true` then). Writes the new nullifier state; returns the
    /// player and that flag.
    fn admit(ref self: ContractState, claim: Outputs, settled: bool) -> (ContractAddress, bool) {
        let level_hash = claim.level_hash;
        let meta = self.levels.read(level_hash);
        assert(meta.version != 0, errors::SUBMIT_LEVEL);
        assert(meta.active, errors::SUBMIT_INACTIVE);
        let player: Option<ContractAddress> = claim.player.try_into();
        let Some(player) = player else {
            core::panic_with_felt252(errors::SUBMIT_PLAYER)
        };
        assert(settled || player == get_caller_address(), errors::SUBMIT_PLAYER);
        let key = poseidon_hash_span([level_hash, claim.player, claim.inputs_hash].span());
        let state = self.nullifiers.read(key);
        let upgrade = settled && state == nullifier::ATTESTED;
        assert(state == nullifier::NONE || upgrade, errors::SUBMIT_NULLIFIER);
        self.nullifiers.write(key, if settled {
            nullifier::SETTLED
        } else {
            nullifier::ATTESTED
        });
        (player, upgrade)
    }

    /// Updates the player's records and the leaderboards with a validated claim, and emits
    /// `LevelValidated`: `best` and the provisional board for either tier, `best_settled` and the
    /// settled board for a settled claim. The settlement of an attested attempt that is the `best`
    /// record marks it settled (its score is already counted).
    fn record(
        ref self: ContractState,
        claim: Outputs,
        player: ContractAddress,
        settled: bool,
        upgrade: bool,
        program_hash: felt252,
    ) {
        let Outputs { level_hash, inputs_hash, score, won, .. } = claim;
        let key = (player, level_hash);
        let new = Best {
            score,
            won,
            inputs_hash,
            block: get_block_number(),
            timestamp: get_block_timestamp(),
            settled,
            program_hash,
        };
        let best = self.best.read(key);
        if improves_best(@best, won, score) {
            self.best.write(key, new);
            if won {
                update_board(ref self, false, level_hash, player, Some(score));
            }
        } else if upgrade && best.inputs_hash == inputs_hash {
            self.best.write(key, Best { settled: true, program_hash, ..best });
        }
        if settled && improves_best(@self.best_settled.read(key), won, score) {
            self.best_settled.write(key, new);
            if won {
                update_board(ref self, true, level_hash, player, Some(score));
            }
        }
        self
            .emit(
                LevelValidated {
                    player, level_hash, inputs_hash, score, won, settled, program_hash,
                },
            );
    }

    fn read_level(self: @ContractState, level_hash: felt252) -> Array<felt252> {
        let mut felts = array![];
        for i in 0..self.level_len.read(level_hash) {
            felts.append(self.level_felts.read((level_hash, i)));
        }
        felts
    }

    fn read_board(self: @ContractState, settled: bool, level_hash: felt252) -> Array<Entry> {
        let stored = if settled {
            self.boards_settled.entry(level_hash)
        } else {
            self.boards_provisional.entry(level_hash)
        };
        let mut board = array![];
        for i in 0..stored.len() {
            board.append(stored.at(i).read());
        }
        board
    }

    fn rows(board: Array<Entry>) -> Array<(ContractAddress, u32)> {
        let mut rows = array![];
        for entry in board {
            rows.append((entry.player, entry.score));
        }
        rows
    }

    /// Moves `player`'s row of a leaderboard to a won `score` (`None`: drops it), writing only
    /// the rows that change.
    fn update_board(
        ref self: ContractState,
        settled: bool,
        level_hash: felt252,
        player: ContractAddress,
        score: Option<u32>,
    ) {
        let old = read_board(@self, settled, level_hash);
        let new = match score {
            Some(score) => insert(old.span(), player, score),
            None => remove(old.span(), player),
        };
        let stored = if settled {
            self.boards_settled.entry(level_hash)
        } else {
            self.boards_provisional.entry(level_hash)
        };
        let old_len: u64 = old.len().into();
        let new_len: u64 = new.len().into();
        let mut i: u64 = 0;
        for entry in new {
            if i >= old_len {
                stored.push(entry);
            } else if *old[i.try_into().unwrap()] != entry {
                stored.at(i).write(entry);
            }
            i += 1;
        }
        if new_len < old_len {
            let _ = stored.pop();
        }
    }
}
