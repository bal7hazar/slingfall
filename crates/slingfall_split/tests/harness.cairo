//! Fixtures, declarations and chunk calls shared by the tests.

use slingfall_game::chunk::{ChunkState, step_state};
use slingfall_game::play::{NoopObserver, decode};
use slingfall_level::inputs::Inputs;
use slingfall_split::rules::from_game;
use snforge_std::fs::{FileTrait, read_txt};
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};
use starknet::syscalls::call_contract_syscall;
use starknet::{ClassHash, ContractAddress, SyscallResultTrait};

/// The classes the world classes library-call: rapier2d_classes' (`classes.json`), then this
/// crate's.
#[cfg(not(feature: 'probes'))]
pub fn classes() -> Array<ByteArray> {
    array![
        "WorldEditClass", "ContactBallClass", "SolveAdvanceClass", "IslandsClass",
        "BroadPhaseClass", "MassClass", "NarrowPhaseClass", "ActiveSetClass", "RulesClass",
        "StepClass",
    ]
}

/// As without the feature, plus the alternatives' rules class (layouts (c) and (d)) and the game's
/// own edit class (layout (d)).
#[cfg(feature: 'probes')]
pub fn classes() -> Array<ByteArray> {
    array![
        "WorldEditClass", "ContactBallClass", "SolveAdvanceClass", "IslandsClass",
        "BroadPhaseClass", "MassClass", "NarrowPhaseClass", "ActiveSetClass", "RulesClass",
        "StepClass", "TypedRulesClass", "EditClass",
    ]
}

pub fn declared(name: ByteArray) -> ClassHash {
    *declare(name).unwrap_syscall().contract_class().class_hash
}

/// Declares every class the world classes library-call.
pub fn install() {
    install_except(@"");
}

/// [`install`] without the class `skip` (`""`: none): a library call of it then fails
/// (`tests/called.cairo` measures which classes a shot calls).
pub fn install_except(skip: @ByteArray) {
    for name in classes() {
        if @name != skip {
            let _ = declared(name);
        }
    }
}

/// Declares and deploys the world class `name` (no constructor).
pub fn deploy(name: ByteArray) -> ContractAddress {
    let (address, _) = declare(name)
        .unwrap_syscall()
        .contract_class()
        .deploy(@array![])
        .unwrap_syscall();
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

/// The world classes whose `step_chunk` takes the world as a length-prefixed span and returns one
/// array (`crate::lean::WorldClass`: one codec site).
pub fn raw(layout: @ByteArray) -> bool {
    layout == @"WorldClass" || layout == @"LayoutF"
}

/// `step_chunk(world, rules, inputs, shot, k)` on the world class at `address`: its return felts
/// (`world ++ rules ++ [stepped, over]`).
pub fn chunk(
    address: ContractAddress,
    raw: bool,
    world: Span<felt252>,
    rules: Span<felt252>,
    inputs: Span<felt252>,
    shot: u8,
    k: u32,
) -> Span<felt252> {
    let mut calldata = array![];
    if raw {
        calldata.append((world.len() + 1 + rules.len()).into());
    }
    calldata.append_span(world);
    rules.serialize(ref calldata);
    inputs.serialize(ref calldata);
    shot.serialize(ref calldata);
    k.serialize(ref calldata);
    let mut out = call_contract_syscall(address, selector!("step_chunk"), calldata.span())
        .unwrap_syscall();
    if raw {
        let _ = out.pop_front();
    }
    out
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
    let raw = raw(@layout);
    let address = deploy(layout);
    let (world, rules) = state(@case, start);
    let inputs = load(@case, "inputs");
    let expected = expected(@case, start, end, over);
    let out = chunk(address, raw, world.span(), rules.span(), inputs.span(), 0, end - start);
    assert!(out == expected.span(), "{case} {start}-{end}: differs from main");
}

/// [`window`] without the chunk call: the steps of the test's own work, subtracted from
/// [`window`]'s.
pub fn window_setup(case: ByteArray, start: u32, end: u32, over: bool) {
    install();
    let _address = deploy("WorldClass");
    let (world, rules) = state(@case, start);
    let inputs = load(@case, "inputs");
    let expected = expected(@case, start, end, over);
    let mut out = world;
    rules.span().serialize(ref out);
    out.append_span(inputs.span());
    assert!(out.span() != expected.span(), "setup");
}

/// Main's own chunk (`slingfall_game::chunk::step_state`: `GameTrait` in process, the whole
/// engine, the full `WorldState` codec) on the window, in this test: the in-process baseline.
pub fn window_main(case: ByteArray, start: u32, end: u32, over: bool) {
    install();
    let _address = deploy("WorldClass");
    let state: ChunkState = decode(load(@case, format!("state_{start}")).span(), 'fixture');
    let inputs: Inputs = decode(load(@case, "inputs").span(), 'fixture: inputs');
    let expected = expected(@case, start, end, over);
    let mut obs: NoopObserver = Default::default();
    let (next, stepped) = step_state(state, @inputs, 0, end - start, ref obs);
    let mut felts = array![];
    next.serialize(ref felts);
    let (world, rules) = split_state(felts.span());
    let mut out = world;
    rules.span().serialize(ref out);
    out.append(stepped.into());
    out.append(over.into());
    assert!(out == expected, "{case} {start}-{end}: main differs from its fixture");
}
