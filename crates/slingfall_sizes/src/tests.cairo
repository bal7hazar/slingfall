//! The one-class fixture deploys and runs: the real `simulate` in the registry class
//! (`SizeE_Simulate`) returns the reference outputs of pile10 (the contract golden,
//! `slingfall_contract::simulate::replay_hook`). Its Cairo steps are the single-class golden the
//! two-class contract is compared with (`slingfall_contract`'s `steps_simulate__pile10_reference`,
//! `REPORT.md` of lot G7c). Named `test_*`, not `steps_*`: this crate is not in the CI test matrix
//! and has no step snapshot.

use slingfall_level::hash::to_felts;
use slingfall_level::inputs::{Inputs, Shot};
use slingfall_level::level::fixtures::{PILE10_HASH, pile10_felts};
use slingfall_level::outputs::OutputsTrait;
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};
use starknet::ContractAddress;
use crate::base::{ISlingfallBaseDispatcher, ISlingfallBaseDispatcherTrait};
use crate::fixtures::{ISimulateDispatcher, ISimulateDispatcherTrait};

const ADMIN: felt252 = 'admin';
const PLAYER: felt252 = 'player';

/// The reference shot and its outputs (`slingfall_game::fixtures::reference_outputs`).
fn reference_inputs() -> Array<felt252> {
    to_felts(
        @Inputs {
            player: PLAYER,
            shots: array![Shot { pull_x: -600, pull_y: -392, delay: 0, ability_tick: 0 }],
        },
    )
}

fn reference_outputs() -> Array<felt252> {
    array![
        1, PILE10_HASH, 0, PLAYER,
        0x31b10e77b97a88153b1e9d781ecddece54061fe1cf88e6a3660eee99fda4f3b, 5350, 1, 1, 191,
        0x2ff3945fee21a4cc7f9447a645a65108dd2a7e697f0c06e75ef0475bbef13e9,
    ]
}

/// Registers pile10 on `address` and simulates the reference shot.
fn register_and_simulate(address: ContractAddress) -> Array<felt252> {
    ISlingfallBaseDispatcher { contract_address: address }.register_level(pile10_felts());
    let outputs = ISimulateDispatcher { contract_address: address }
        .simulate(PILE10_HASH, reference_inputs());
    outputs.to_felts()
}

#[test]
fn test_simulate_reference__one_class() {
    let class = declare("SizeE_Simulate").unwrap().contract_class();
    let (address, _) = class.deploy(@array![ADMIN]).unwrap();
    assert_eq!(register_and_simulate(address), reference_outputs());
}
