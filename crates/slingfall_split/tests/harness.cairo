//! Fixtures, declarations and chunk calls shared by the tests.

use slingfall_game::chunk::ChunkState;
use slingfall_game::play::decode;
use slingfall_split::rules::from_game;
use snforge_std::fs::{FileTrait, read_txt};
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};
use starknet::syscalls::call_contract_syscall;
use starknet::{ClassHash, ContractAddress, SyscallResultTrait};

/// The declared classes: rapier2d_classes' stages, then this crate's.
pub fn classes() -> Array<ByteArray> {
    array![
        "ContactBallClass", "ContactPolygonClass", "SolverClass", "SolveAdvanceClass",
        "IslandsClass", "BroadPhaseClass", "MassClass", "NarrowPhaseClass", "ActiveSetClass",
        "ForceEventsClass", "RulesClass", "LeanRulesClass", "EditClass", "StepClass",
    ]
}

pub fn declared(name: ByteArray) -> ClassHash {
    *declare(name).unwrap().contract_class().class_hash
}

/// Declares every class the world classes library-call.
pub fn install() {
    for name in classes() {
        let _ = declared(name);
    }
}

/// Declares and deploys the world class `name` (no constructor).
pub fn deploy(name: ByteArray) -> ContractAddress {
    let (address, _) = declare(name).unwrap().contract_class().deploy(@array![]).unwrap_syscall();
    address
}

/// `fixtures/<case>/<name>.txt`.
pub fn load(case: @ByteArray, name: ByteArray) -> Array<felt252> {
    read_txt(@FileTrait::new(format!("fixtures/{case}/{name}.txt")))
}

/// Main's `ChunkState` felts as the spike's state: the world's felts (`WorldState`'s, which the
/// basic codec reads unchanged) and the rules state's (`Rules`).
pub fn split_state(felts: Span<felt252>) -> (Array<felt252>, Array<felt252>) {
    let chunk: ChunkState = decode(felts, 'fixture: state');
    let ChunkState { progress, level, game, .. } = chunk;
    let mut world = array![];
    game.world.serialize(ref world);
    let mut rules = array![];
    from_game(@level, game, progress).serialize(ref rules);
    (world, rules)
}

/// The state of main's fixture after `tick` ticks of `case`.
pub fn state(case: @ByteArray, tick: u32) -> (Array<felt252>, Array<felt252>) {
    split_state(load(case, format!("state_{tick}")).span())
}

/// `step_chunk(world, rules, inputs, shot, k)` on the world class at `address`: its return felts
/// (`world ++ rules ++ [stepped, over]`).
pub fn chunk(
    address: ContractAddress,
    world: Span<felt252>,
    rules: Span<felt252>,
    inputs: Span<felt252>,
    shot: u8,
    k: u32,
) -> Span<felt252> {
    let mut calldata = array![];
    calldata.append_span(world);
    rules.serialize(ref calldata);
    inputs.serialize(ref calldata);
    shot.serialize(ref calldata);
    k.serialize(ref calldata);
    call_contract_syscall(address, selector!("step_chunk"), calldata.span()).unwrap_syscall()
}

/// What `chunk` must return after the window `start..end` of `case`: main's state at `end`.
pub fn expected(case: @ByteArray, start: u32, end: u32, over: bool) -> Array<felt252> {
    let (world, rules) = state(case, end);
    let mut out = world;
    rules.span().serialize(ref out);
    out.append((end - start).into());
    out.append(over.into());
    out
}

/// The window `start..end` of `case` in one chunk of the world class `layout`, checked against
/// main's state at `end` (world and rules, bit for bit).
pub fn window(layout: ByteArray, case: ByteArray, start: u32, end: u32, over: bool) {
    install();
    let address = deploy(layout);
    let (world, rules) = state(@case, start);
    let inputs = load(@case, "inputs");
    let expected = expected(@case, start, end, over);
    let out = chunk(address, world.span(), rules.span(), inputs.span(), 0, end - start);
    assert!(out == expected.span(), "{case} {start}-{end}: differs from main");
}

/// [`window`] without the chunk call: the steps of the test's own work, subtracted from
/// [`window`]'s.
pub fn window_setup(case: ByteArray, start: u32, end: u32, over: bool) {
    install();
    let _address = deploy("LayoutD");
    let (world, rules) = state(@case, start);
    let inputs = load(@case, "inputs");
    let expected = expected(@case, start, end, over);
    let mut out = world;
    rules.span().serialize(ref out);
    out.append_span(inputs.span());
    assert!(out.span() != expected.span(), "setup");
}
