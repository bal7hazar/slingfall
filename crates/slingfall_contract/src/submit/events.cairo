//! The events of `Slingfall` (re-exported by `submit::Slingfall`).

use starknet::{ClassHash, ContractAddress};

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
    /// Validated by a proof: the Satellite fact or SNIP-36 (else by an attestation).
    pub settled: bool,
    /// `Best::program_hash`.
    pub program_hash: felt252,
    /// Validated by SNIP-36 (`finalize`; `settled` too: a proof either way).
    pub proven: bool,
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

/// `pin_chain`: the SNIP-36 chain contract of a release's class bundle.
#[derive(Drop, PartialEq, Debug, starknet::Event)]
pub struct ChainPinned {
    #[key]
    pub chain: ContractAddress,
    pub bundle_hash: felt252,
    /// The former current chain (zero when none or the same), valid until
    /// `previous_valid_until`.
    pub previous: ContractAddress,
    pub previous_valid_until: u64,
}

#[derive(Drop, PartialEq, Debug, starknet::Event)]
pub struct ChainRevoked {
    #[key]
    pub chain: ContractAddress,
}

/// `pin_virtual_os`: the virtual-OS program hash the proof facts may name.
#[derive(Drop, PartialEq, Debug, starknet::Event)]
pub struct VirtualOsPinned {
    #[key]
    pub program_hash: felt252,
    pub previous: felt252,
    pub previous_valid_until: u64,
}

#[derive(Drop, PartialEq, Debug, starknet::Event)]
pub struct VirtualOsRevoked {
    #[key]
    pub program_hash: felt252,
}
