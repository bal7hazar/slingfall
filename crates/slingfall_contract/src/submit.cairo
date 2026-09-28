//! The `Slingfall` contract, v3 (`docs/DESIGN.md` D9, `docs/contract-v2.md`,
//! `docs/contract-v3.md`): level registry, `simulate` (run in the SNIP-36 virtual OS), `submit`
//! (the provisional tier: `player == caller`, nullifier `poseidon(level_hash, player,
//! inputs_hash)`, the active `Verifier`), `submit_settled` (the settled tier: the Atlantic fact on
//! the Satellite, recorded for `claim.player` whoever sends it), `submit_chunk` / `finalize` (the
//! proven tier: a SNIP-36 chain of proofs, idem), sets of accepted programs with a grace period,
//! per-tier records and leaderboards, `expire`, a two-step admin transfer and `upgrade`.
//!
//! Three tiers: an attempt validated by an attestation is *provisional*; one validated by
//! `SatelliteVerifier` is *settled*, one validated by a SNIP-36 chain *proven*; both proofs rank
//! together (`Best.settled`, the settled board). A nullifier moves `NONE -> ATTESTED -> SETTLED |
//! PROVEN` or `NONE -> SETTLED | PROVEN`: the only second submission of an attempt is its proof.
//! `best` and the provisional board rank each player's best of any tier; `best_settled` and
//! `leaderboard` only proven attempts, so a provisional record never hides one.

pub use interface::*;

pub mod chunks;
pub mod errors;
pub mod events;
#[cfg(test)]
pub mod fixtures;
pub mod interface;
#[cfg(test)]
mod tests;

#[starknet::contract]
pub mod Slingfall {
    use core::num::traits::Zero;
    use core::poseidon::poseidon_hash_span;
    use slingfall_level::inputs::Inputs;
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
        AttestationVerifier, BLOCK_HASH_BUFFER, SatelliteConfig, SatelliteVerifier, Snip36Verifier,
        Verifier, VerifierKind, has_message, message_hash, parse_facts,
    };
    use super::chunks::{Chunk, Edge, MAX_EDGES};
    pub use super::events::*;
    use super::{DEFAULT_EXPIRE_DELAY, FOREVER, chunks, errors, grace_until, nullifier};

    /// v2's storage unchanged (an `upgrade` from v2 keeps every record), then v3's.
    #[storage]
    struct Storage {
        admin: ContractAddress,
        pending_admin: ContractAddress,
        /// The virtual-OS program of `submit`'s `Snip36` verifier.
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
        /// `nullifier::{NONE, ATTESTED, SETTLED, PROVEN}`.
        nullifiers: Map<felt252, u8>,
        /// Any tier.
        best: Map<(ContractAddress, felt252), Best>,
        /// Proofs only (settled or proven).
        best_settled: Map<(ContractAddress, felt252), Best>,
        boards_settled: Map<felt252, Vec<Entry>>,
        boards_provisional: Map<felt252, Vec<Entry>>,
        // v3: the SNIP-36 tier.
        /// `to_address` of the chains' messages.
        chunk_marker: felt252,
        /// Chain contract (one deployment of a release's class bundle) -> `valid_until`.
        chains: Map<ContractAddress, u64>,
        /// Chain -> the bundle hash the admin declared for it.
        chain_bundles: Map<ContractAddress, felt252>,
        current_chain: ContractAddress,
        /// Virtual-OS program hash -> `valid_until`.
        virtual_os_programs: Map<felt252, u64>,
        current_virtual_os: felt252,
        /// `(chain, level_hash)` -> `init`'s state hash.
        chunk_starts: Map<(ContractAddress, felt252), felt252>,
        /// `(chain, inputs_hash, state_in_hash)` -> the step from that state.
        chunk_edges: Map<(ContractAddress, felt252, felt252), Edge>,
        /// `(chain, inputs_hash, state_in_hash)` -> `poseidon(outputs felts)`.
        chunk_ends: Map<(ContractAddress, felt252, felt252), felt252>,
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
        ChainPinned: ChainPinned,
        ChainRevoked: ChainRevoked,
        VirtualOsPinned: VirtualOsPinned,
        VirtualOsRevoked: VirtualOsRevoked,
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
            let (player, _) = admit(ref self, claim, nullifier::ATTESTED);
            let (valid, program_hash) = match self.verifier.read() {
                VerifierKind::Snip36 => {
                    let mut verifier = Snip36Verifier {
                        virtual_os_hash: self.virtual_os_hash.read(),
                        from: get_contract_address().into(),
                        facts: proof_facts(),
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
            record(ref self, claim, player, nullifier::ATTESTED, false, program_hash);
        }

        fn submit_settled(
            ref self: ContractState,
            outputs: Array<felt252>,
            args: Array<felt252>,
            child_program_hash: felt252,
        ) {
            let claim = OutputsTrait::from_felts(outputs.span());
            let (player, upgrade) = admit(ref self, claim, nullifier::SETTLED);
            assert_program(@self, child_program_hash);
            let mut verifier = SatelliteVerifier {
                config: self.satellite.read(), child_program_hash,
            };
            assert(verifier.check(claim, args.span()), errors::SUBMIT_PROOF);
            record(ref self, claim, player, nullifier::SETTLED, upgrade, child_program_hash);
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
                previous_valid_until = grace_until(get_block_timestamp(), grace_s);
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

    #[abi(embed_v0)]
    impl SlingfallProvenImpl of super::ISlingfallProven<ContractState> {
        fn submit_chunk(
            ref self: ContractState, chain: ContractAddress, kind: u8, payload: Array<felt252>,
        ) {
            let now = get_block_timestamp();
            let marker = self.chunk_marker.read();
            assert(marker != 0 && self.chains.read(chain) > now, errors::CHUNK_CHAIN);
            let Some(facts) = parse_facts(proof_facts()) else {
                core::panic_with_felt252(errors::CHUNK_FACTS)
            };
            let program_valid_until = self.virtual_os_programs.read(facts.program_hash);
            assert(program_valid_until > now, errors::CHUNK_PROGRAM);
            let block = get_block_number();
            assert(
                block >= BLOCK_HASH_BUFFER && facts.base_block_number <= block
                    - BLOCK_HASH_BUFFER && facts.base_block_hash != 0,
                errors::CHUNK_BASE_BLOCK,
            );
            let hash = message_hash(chain.into(), marker, payload.span());
            assert(has_message(facts.messages, hash), errors::CHUNK_MESSAGE);
            match chunks::parse(kind, payload.span()) {
                Chunk::Init((
                    level_hash, state,
                )) => {
                    let entry = self.chunk_starts.entry((chain, level_hash));
                    let stored = entry.read();
                    if stored == 0 {
                        entry.write(state);
                    } else {
                        assert(stored == state, errors::CHUNK_CONFLICT);
                    }
                },
                Chunk::Step((
                    inputs_hash, state_in, edge,
                )) => {
                    let entry = self.chunk_edges.entry((chain, inputs_hash, state_in));
                    let stored = entry.read();
                    if stored.next == 0 {
                        entry.write(edge);
                    } else {
                        assert(stored == edge, errors::CHUNK_CONFLICT);
                    }
                },
                Chunk::Outputs((
                    inputs_hash, state_in, outputs_hash,
                )) => {
                    let entry = self.chunk_ends.entry((chain, inputs_hash, state_in));
                    let stored = entry.read();
                    if stored == 0 {
                        entry.write(outputs_hash);
                    } else {
                        assert(stored == outputs_hash, errors::CHUNK_CONFLICT);
                    }
                },
            }
        }

        fn finalize(
            ref self: ContractState,
            chain: ContractAddress,
            level_hash: felt252,
            inputs: Array<felt252>,
            outputs: Array<felt252>,
        ) {
            assert(self.chains.read(chain) > get_block_timestamp(), errors::FINALIZE_CHAIN);
            let claim = OutputsTrait::from_felts(outputs.span());
            let mut felts = inputs.span();
            let decoded: Option<Inputs> = Serde::deserialize(ref felts);
            let Some(decoded) = decoded else {
                core::panic_with_felt252(errors::FINALIZE_INPUTS)
            };
            assert(felts.is_empty(), errors::FINALIZE_INPUTS);
            let inputs_hash = poseidon_hash_span(inputs.span());
            assert(
                claim.level_hash == level_hash
                    && claim.inputs_hash == inputs_hash
                    && claim.player == decoded.player,
                errors::FINALIZE_OUTPUTS,
            );
            let shots = decoded.shots.len();
            let mut state = self.chunk_starts.read((chain, level_hash));
            assert(state != 0, errors::FINALIZE_LINK);
            let mut shot: u8 = 0;
            let mut edges: u32 = 0;
            loop {
                let end = self.chunk_ends.read((chain, inputs_hash, state));
                if end != 0 {
                    assert(end == poseidon_hash_span(outputs.span()), errors::FINALIZE_OUTPUTS);
                    break;
                }
                let edge = self.chunk_edges.read((chain, inputs_hash, state));
                assert(edge.next != 0, errors::FINALIZE_LINK);
                assert(edges < MAX_EDGES, errors::FINALIZE_LENGTH);
                assert(edge.shot >= shot && edge.shot.into() < shots, errors::FINALIZE_SHOT);
                shot = edge.shot;
                edges += 1;
                state = edge.next;
            }
            let (player, upgrade) = admit(ref self, claim, nullifier::PROVEN);
            let bundle = self.chain_bundles.read(chain);
            record(ref self, claim, player, nullifier::PROVEN, upgrade, bundle);
        }

        fn chunk_start(
            self: @ContractState, chain: ContractAddress, level_hash: felt252,
        ) -> felt252 {
            self.chunk_starts.read((chain, level_hash))
        }

        fn chunk_edge(
            self: @ContractState,
            chain: ContractAddress,
            inputs_hash: felt252,
            state_in_hash: felt252,
        ) -> Edge {
            self.chunk_edges.read((chain, inputs_hash, state_in_hash))
        }

        fn chunk_end(
            self: @ContractState,
            chain: ContractAddress,
            inputs_hash: felt252,
            state_in_hash: felt252,
        ) -> felt252 {
            self.chunk_ends.read((chain, inputs_hash, state_in_hash))
        }

        fn chunk_marker(self: @ContractState) -> felt252 {
            self.chunk_marker.read()
        }

        fn set_chunk_marker(ref self: ContractState, marker: felt252) {
            assert_admin(@self);
            self.chunk_marker.write(marker);
        }

        fn current_chain(self: @ContractState) -> ContractAddress {
            self.current_chain.read()
        }

        fn chain_valid_until(self: @ContractState, chain: ContractAddress) -> u64 {
            self.chains.read(chain)
        }

        fn chain_bundle(self: @ContractState, chain: ContractAddress) -> felt252 {
            self.chain_bundles.read(chain)
        }

        fn pin_chain(
            ref self: ContractState, chain: ContractAddress, bundle_hash: felt252, grace_s: u64,
        ) {
            assert_admin(@self);
            assert(chain.is_non_zero() && bundle_hash != 0, errors::CHAIN_ZERO);
            let mut previous = self.current_chain.read();
            let mut previous_valid_until = 0;
            if previous == chain {
                previous = Zero::zero();
            } else if previous.is_non_zero() {
                previous_valid_until = grace_until(get_block_timestamp(), grace_s);
                self.chains.write(previous, previous_valid_until);
            }
            self.chains.write(chain, FOREVER);
            self.chain_bundles.write(chain, bundle_hash);
            self.current_chain.write(chain);
            self.emit(ChainPinned { chain, bundle_hash, previous, previous_valid_until });
        }

        fn revoke_chain(ref self: ContractState, chain: ContractAddress) {
            assert_admin(@self);
            self.chains.write(chain, 0);
            if self.current_chain.read() == chain {
                self.current_chain.write(Zero::zero());
            }
            self.emit(ChainRevoked { chain });
        }

        fn current_virtual_os(self: @ContractState) -> felt252 {
            self.current_virtual_os.read()
        }

        fn virtual_os_valid_until(self: @ContractState, program_hash: felt252) -> u64 {
            self.virtual_os_programs.read(program_hash)
        }

        fn pin_virtual_os(ref self: ContractState, program_hash: felt252, grace_s: u64) {
            assert_admin(@self);
            assert(program_hash != 0, errors::PROGRAM_ZERO);
            let mut previous = self.current_virtual_os.read();
            let mut previous_valid_until = 0;
            if previous == program_hash {
                previous = 0;
            } else if previous != 0 {
                previous_valid_until = grace_until(get_block_timestamp(), grace_s);
                self.virtual_os_programs.write(previous, previous_valid_until);
            }
            self.virtual_os_programs.write(program_hash, FOREVER);
            self.current_virtual_os.write(program_hash);
            self.emit(VirtualOsPinned { program_hash, previous, previous_valid_until });
        }

        fn revoke_virtual_os(ref self: ContractState, program_hash: felt252) {
            assert_admin(@self);
            self.virtual_os_programs.write(program_hash, 0);
            if self.current_virtual_os.read() == program_hash {
                self.current_virtual_os.write(0);
            }
            self.emit(VirtualOsRevoked { program_hash });
        }
    }

    /// The transaction's SNIP-36 `proof_facts`: the one read of them (`submit` and
    /// `submit_chunk`).
    fn proof_facts() -> Span<felt252> {
        get_execution_info().unbox().tx_info.unbox().proof_facts
    }

    fn assert_admin(self: @ContractState) {
        assert(get_caller_address() == self.admin.read(), errors::ADMIN_CALLER);
    }

    /// `program_hash` is in the program set now.
    fn assert_program(self: @ContractState, program_hash: felt252) {
        assert(self.programs.read(program_hash) > get_block_timestamp(), errors::SUBMIT_PROGRAM);
    }

    /// The checks before any verifier: the level is registered and active, the claim is the
    /// caller's (`ATTESTED` only: a proven claim is recorded for its player whoever sends it, the
    /// proof binds the player), and the nullifier admits `tier` (a new attempt, or the proof of an
    /// attested one: `true` then). Writes `tier` as the new nullifier state; returns the player
    /// and that flag.
    fn admit(ref self: ContractState, claim: Outputs, tier: u8) -> (ContractAddress, bool) {
        let level_hash = claim.level_hash;
        let meta = self.levels.read(level_hash);
        assert(meta.version != 0, errors::SUBMIT_LEVEL);
        assert(meta.active, errors::SUBMIT_INACTIVE);
        let player: Option<ContractAddress> = claim.player.try_into();
        let Some(player) = player else {
            core::panic_with_felt252(errors::SUBMIT_PLAYER)
        };
        let proof = tier != nullifier::ATTESTED;
        assert(proof || player == get_caller_address(), errors::SUBMIT_PLAYER);
        let key = poseidon_hash_span([level_hash, claim.player, claim.inputs_hash].span());
        let state = self.nullifiers.read(key);
        let upgrade = proof && state == nullifier::ATTESTED;
        assert(state == nullifier::NONE || upgrade, errors::SUBMIT_NULLIFIER);
        self.nullifiers.write(key, tier);
        (player, upgrade)
    }

    /// Updates the player's records and the leaderboards with a claim validated at `tier`, and
    /// emits `LevelValidated`: `best` and the provisional board for any tier, `best_settled` and
    /// the settled board for a proof (`SETTLED` or `PROVEN`). The proof of an attested attempt
    /// that is the `best` record marks it settled (its score is already counted).
    fn record(
        ref self: ContractState,
        claim: Outputs,
        player: ContractAddress,
        tier: u8,
        upgrade: bool,
        program_hash: felt252,
    ) {
        let settled = tier != nullifier::ATTESTED;
        let proven = tier == nullifier::PROVEN;
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
                    player, level_hash, inputs_hash, score, won, settled, program_hash, proven,
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
