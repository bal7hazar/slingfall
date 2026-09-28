//! The SNIP-36 chain (`slingfall_split::chain::SplitChain`): a whole shot as its proven
//! transactions, `init` -> `step_chunk` × n -> `outputs`, each one L2 to L1 message; the messages
//! link (every `STATE_IN_HASH` is the previous `STATE_OUT_HASH`), the states are main's and the
//! outputs are main's (`fixtures/<case>/outputs.txt`).

use slingfall_game::chunk::{ChunkState, hash_felts};
use slingfall_game::play::decode;
use slingfall_split::chain::MARKER;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, MessageToL1SpyTrait, declare, spy_messages_to_l1,
};
use starknet::syscalls::call_contract_syscall;
use starknet::{ContractAddress, SyscallResultTrait};
use crate::harness::{declared, install, load, raw, state};

/// Deploys the chain contract over the world class `layout`.
pub fn deploy_chain(layout: ByteArray) -> ContractAddress {
    install();
    let raw = raw(@layout);
    let calldata: Array<felt252> = array![
        declared("BuildClass").into(), declared("SettleClass").into(), declared("EditClass").into(),
        declared(layout).into(), declared("OutputsClass").into(), raw.into(),
    ];
    let (address, _) = declare("SplitChain")
        .unwrap_syscall()
        .contract_class()
        .deploy(@calldata)
        .unwrap_syscall();
    address
}

/// A call of the chain contract: its returned span, without the length prefix.
fn invoke(address: ContractAddress, selector: felt252, calldata: Array<felt252>) -> Span<felt252> {
    let mut ret = call_contract_syscall(address, selector, calldata.span()).unwrap_syscall();
    let _ = ret.pop_front();
    ret
}

/// The level felts of `case` (from main's first state).
pub fn level(case: @ByteArray) -> Array<felt252> {
    let chunk: ChunkState = decode(load(case, "state_0").span(), 'fixture: state');
    let mut felts = array![];
    chunk.level.serialize(ref felts);
    felts
}

/// The chain's state (`world ++ rules`) of main's fixture at `tick`.
pub fn chain_state(case: @ByteArray, tick: u32) -> Array<felt252> {
    let (world, rules) = state(case, tick);
    let mut out = world;
    rules.span().serialize(ref out);
    out
}

/// `init` then `step_chunk` with the tick budgets of `schedule` (the last one repeated) until the
/// shot is over, then `outputs`; checks every link, main's first state, main's outputs.
pub fn play_chain(layout: ByteArray, case: ByteArray, schedule: Span<u32>) {
    let address = deploy_chain(layout);
    let inputs = load(@case, "inputs");
    let mut spy = spy_messages_to_l1();
    // init
    let level = level(@case);
    let mut calldata = array![];
    level.span().serialize(ref calldata);
    let mut state: Span<felt252> = invoke(address, selector!("init"), calldata);
    let expected = chain_state(@case, 0);
    if let Some(i) = crate::init::first_difference(state, expected.span()) {
        println!("init: first difference at {i} of {} / {}", state.len(), expected.len());
        let from = if i > 8 {
            i - 8
        } else {
            0
        };
        println!("got  {:?}", state.slice(from, 16));
        println!("main {:?}", expected.span().slice(from, 16));
        panic!("init: not main's first state");
    }
    let mut hashes = array![(0, hash_felts(state))];
    // step_chunk × n
    let mut i = 0;
    loop {
        let k = if i < schedule.len() {
            *schedule[i]
        } else {
            *schedule[schedule.len() - 1]
        };
        let mut calldata = array![];
        state.serialize(ref calldata);
        inputs.span().serialize(ref calldata);
        calldata.append(0);
        calldata.append(k.into());
        let ret = invoke(address, selector!("step_chunk"), calldata);
        state = ret.slice(0, ret.len() - 2);
        hashes.append((k, hash_felts(state)));
        i += 1;
        if *ret[ret.len() - 1] == 1 {
            break;
        }
    }
    // outputs
    let mut calldata = array![];
    state.serialize(ref calldata);
    inputs.span().serialize(ref calldata);
    let outputs = invoke(address, selector!("outputs"), calldata);
    assert!(outputs == load(@case, "outputs").span(), "outputs: not main's");
    // The messages: one per transaction, from the chain, to the marker, linked.
    let messages = spy.get_messages().messages;
    assert!(messages.len() == hashes.len() + 1, "one message per transaction");
    let inputs_hash = hash_felts(inputs.span());
    let (_, first) = *hashes[0];
    let mut previous = first;
    let mut index = 0;
    for (from, message) in messages.span() {
        assert!(*from == address, "message from the chain contract");
        let to: felt252 = (*message.to_address).into();
        assert!(to == MARKER, "message to the marker");
        let payload = message.payload.span();
        if index == 0 {
            assert!(payload == array![hash_felts(level.span()), first].span(), "init message");
        } else if index < hashes.len() {
            let (k, out) = *hashes[index];
            assert!(
                payload == array![previous, inputs_hash, 0, k.into(), out].span(),
                "chunk message {index}",
            );
            previous = out;
        } else {
            let mut expected = array![previous, inputs_hash];
            expected.append_span(outputs);
            assert!(payload == expected.span(), "outputs message");
        }
        index += 1;
    }
    println!("chain {case}: {} transactions", messages.len());
}

/// Layout (b) (the layout that fits today) on the reference shot, in its transactions
/// (`docs/research/07-split-game-step.md`): 0-50, 50-80, 80-90, 90-107.
#[test]
#[ignore]
fn test_chain_b_reference() {
    play_chain("LayoutB", "reference", array![50, 30, 10, 17].span());
}

/// Layout (e) on the reference shot: 0-90, 90-107.
#[test]
fn test_chain_e_reference() {
    play_chain("LayoutE", "reference", array![90, 17].span());
}

/// `outputs` of an unfinished state reverts (P1b's verifier check 6, in the transaction).
#[test]
#[should_panic]
fn test_chain_outputs_unfinished() {
    let address = deploy_chain("LayoutE");
    let inputs = load(@"owner", "inputs");
    let mut calldata = array![];
    chain_state(@"owner", 80).span().serialize(ref calldata);
    inputs.span().serialize(ref calldata);
    invoke(address, selector!("outputs"), calldata);
}

/// `step_chunk` of a shot that is not the one in progress reverts (P1b's verifier check 5).
#[test]
#[should_panic]
fn test_chain_wrong_shot() {
    let address = deploy_chain("LayoutE");
    let inputs = load(@"owner", "inputs");
    let mut calldata = array![];
    chain_state(@"owner", 40).span().serialize(ref calldata);
    inputs.span().serialize(ref calldata);
    calldata.append(1);
    calldata.append(10);
    invoke(address, selector!("step_chunk"), calldata);
}

/// One `step_chunk` transaction of the chain over `layout`: ticks `start..end` of `case` from
/// main's state at `start`, checked against main's state at `end` (the steps of the transaction:
/// this test's minus [`tx_setup`]'s).
pub fn tx_chunk(layout: ByteArray, case: ByteArray, start: u32, end: u32, over: bool) {
    let address = deploy_chain(layout);
    let inputs = load(@case, "inputs");
    let mut calldata = array![];
    chain_state(@case, start).span().serialize(ref calldata);
    inputs.span().serialize(ref calldata);
    calldata.append(0);
    calldata.append((end - start).into());
    let mut expected = chain_state(@case, end);
    expected.append((end - start).into());
    expected.append(over.into());
    let ret = invoke(address, selector!("step_chunk"), calldata);
    assert!(ret == expected.span(), "{case} {start}-{end}: differs from main");
}

/// The `init` transaction of `case` over `layout`.
pub fn tx_init(layout: ByteArray, case: ByteArray) {
    let address = deploy_chain(layout);
    let mut calldata = array![];
    level(@case).span().serialize(ref calldata);
    let expected = chain_state(@case, 0);
    let ret = invoke(address, selector!("init"), calldata);
    assert!(ret == expected.span(), "{case}: init differs from main");
}

/// The `outputs` transaction of `case` (its last state, after `last` ticks) over `layout`.
pub fn tx_outputs(layout: ByteArray, case: ByteArray, last: u32) {
    let address = deploy_chain(layout);
    let mut calldata = array![];
    chain_state(@case, last).span().serialize(ref calldata);
    load(@case, "inputs").span().serialize(ref calldata);
    let expected = load(@case, "outputs");
    let ret = invoke(address, selector!("outputs"), calldata);
    assert!(ret == expected.span(), "{case}: outputs differ from main's");
}

/// The work of [`tx_chunk`] (`start < end`), [`tx_init`] (`start == end == 0`) or [`tx_outputs`]
/// (`start == end != 0`) without the transaction.
pub fn tx_setup(case: ByteArray, start: u32, end: u32) {
    let _address = deploy_chain("LayoutE");
    let mut calldata = array![];
    let mut expected = array![];
    if start == end && start == 0 {
        level(@case).span().serialize(ref calldata);
        expected = chain_state(@case, 0);
    } else if start == end {
        chain_state(@case, start).span().serialize(ref calldata);
        load(@case, "inputs").span().serialize(ref calldata);
        expected = load(@case, "outputs");
    } else {
        chain_state(@case, start).span().serialize(ref calldata);
        load(@case, "inputs").span().serialize(ref calldata);
        calldata.append(0);
        calldata.append((end - start).into());
        expected = chain_state(@case, end);
        expected.append((end - start).into());
        expected.append(0);
    }
    assert!(calldata.span() != expected.span(), "setup");
}
