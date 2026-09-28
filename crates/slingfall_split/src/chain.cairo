//! The SNIP-36 chain of a shot (`docs/research/07-split-game-step.md` "Transactions"): one
//! deployed contract, [`SplitChain`], whose three entry points are the three kinds of proven
//! transaction (`init`, `step_chunk` × n, `outputs`). Each library-calls the declared classes of
//! the layout and sends one L2 to L1 message, P1b's binding header with the new state replaced by
//! its hash (`docs/proving.md` "Chunk binding"):
//!
//! | transaction | message payload (`to = MARKER`) |
//! |---|---|
//! | `init(level)` | `[LEVEL_HASH, STATE_OUT_HASH]` |
//! | `step_chunk(state, inputs, shot, k)` | `[STATE_IN_HASH, INPUTS_HASH, shot, k, STATE_OUT_HASH]`
//! |
//! | `outputs(state, inputs)` | `[STATE_IN_HASH, INPUTS_HASH] ++ outputs` (the 10 D4 felts) |
//!
//! A hash is `slingfall_game::chunk::hash_felts` (Poseidon, no length prefix) of the argument's
//! felts. The state is `world ++ rules` (`BasicWorldState` felts, then the `Rules` felts,
//! length-prefixed). The virtual OS outputs nothing but the messages: the state leaves as its
//! hash, the prover keeps the felts for the next transaction. The checks P1b's verifier made on
//! public states (the shot in progress, the level not over, the last state finished) are made in
//! the transactions (`crate::rules::check_turn`, [`OutputsClass`]): a transaction that fails them
//! reverts, and the virtual OS proves no reverted transaction.
//!
//! **The payload layouts above are API** (V3 escalation 2): contract v3's `submit_chunk` decodes
//! them (`slingfall_contract::submit::chunks::parse`, kinds `INIT` / `STEP` / `OUTPUTS`), the
//! prover service forwards them (`services/prove/snip36.py`); changing one is a contract change.
//! [`MARKER`] is the value contract v3's `set_chunk_marker` is given. One deployment of
//! [`SplitChain`] is one release's class bundle: the classes it library-calls are fixed by its
//! constructor (no setter; `tests::chain::test_chain_bundle_*`), those its world class calls are
//! compiled in ([`crate::hashes`]); contract v3 pins the deployment's address with the bundle
//! hash (`pin_chain`).

use core::poseidon::poseidon_hash_span;
use rapier2d::prelude::{Handle, RigidBodyTrait, WorldTrait};
use rapier2d::world::World;
use slingfall_level::inputs::Inputs;
use slingfall_level::level::KIND_STATIC;
use crate::rules::{Rules, level_over};

/// `to_address` of every message (the contract's `simulate` marker).
pub const MARKER: felt252 = 'SLINGFALL';

/// Panic messages of the chain.
pub mod errors {
    /// `outputs` of a state whose level is not finished (P1b's verifier check 6).
    pub const NOT_FINISHED: felt252 = 'split: not finished';
}

/// The D4 outputs of a finished state (`slingfall_game::play::outputs` on the split state).
///
/// # Panics
/// [`errors::NOT_FINISHED`] unless the shot in progress is done and the level is over or every
/// shot of `inputs` was played.
pub fn outputs(ref world: World, rules: @Rules, inputs: @Inputs) -> Array<felt252> {
    let finished = *rules.progress.ticks == 0
        && (level_over(rules) || (*rules.shots_used).into() == inputs.shots.len());
    if !finished {
        core::panic_with_felt252(errors::NOT_FINISHED);
    }
    let mut inputs_felts = array![];
    inputs.serialize(ref inputs_felts);
    array![
        (*rules.params.version).into(), *rules.level_hash, *rules.params.seed, *inputs.player,
        poseidon_hash_span(inputs_felts.span()), (*rules.score).into(),
        (*rules.cores_left == 0).into(), (*rules.shots_used).into(), (*rules.tick).into(),
        final_state_hash(ref world, rules),
    ]
}

/// `GameTrait::final_state_hash` on the split state: Poseidon over the raw poses of the live
/// dynamic bodies in ascending slot order, the pebble included while it exists.
fn final_state_hash(ref world: World, rules: @Rules) -> felt252 {
    let mut felts: Array<felt252> = array![];
    let mut pebble: Option<Handle> = *rules.pebble;
    for entity in rules.entities.span() {
        if let Some(handle) = pebble {
            if handle.index < *entity.body.index {
                world.body(handle).unwrap().position().serialize(ref felts);
                pebble = None;
            }
        }
        if *entity.alive && *entity.kind != KIND_STATIC {
            world.body(*entity.body).unwrap().position().serialize(ref felts);
        }
    }
    if let Some(handle) = pebble {
        world.body(handle).unwrap().position().serialize(ref felts);
    }
    poseidon_hash_span(felts.span())
}

/// `init`'s first part: the world and the rules state of a level, before the settle step.
#[starknet::contract]
pub mod BuildClass {
    use rapier2d::world::basic_state::{BasicWorldState, into_basic_state};
    use slingfall_level::level::Level;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn build(self: @ContractState, level: Level) -> (BasicWorldState, Array<felt252>) {
        let (world, rules) = crate::init::build(@level);
        let mut felts = array![];
        rules.serialize(ref felts);
        (into_basic_state(world), felts)
    }
}

/// `init`'s settle step (`dt = 0`, no force events) with `SlimSplitStages`; the rules pass
/// through. The sleeps that follow it are `EditClass::sleep_all`'s.
#[starknet::contract]
pub mod SettleClass {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state, into_basic_state};
    use crate::hashes::GameClasses;

    #[storage]
    struct Storage {}

    #[external(v0)]
    fn settle(
        self: @ContractState, world: BasicWorldState, rules: Array<felt252>,
    ) -> (BasicWorldState, Array<felt252>) {
        let world = crate::init::settle::<GameClasses>(from_basic_state(world));
        (into_basic_state(world), rules)
    }
}

/// The `outputs` transaction's class: the world decoded for the final poses.
#[starknet::contract]
pub mod OutputsClass {
    use rapier2d::world::basic_state::{BasicWorldState, from_basic_state};
    use slingfall_level::inputs::Inputs;
    use crate::rules::Rules;

    #[storage]
    struct Storage {}

    /// `world ++ rules` (the state) then the `Inputs` felts.
    #[external(v0)]
    fn outputs(
        self: @ContractState, world: BasicWorldState, rules: Array<felt252>, inputs: Inputs,
    ) -> Array<felt252> {
        let rules: Rules = slingfall_game::play::decode(
            rules.span(), slingfall_game::errors::STATE,
        );
        let mut world = from_basic_state(world);
        super::outputs(ref world, @rules, @inputs)
    }
}

/// The deployed contract of the chain: the three proven transactions. The classes it
/// library-calls are storage, written once by the constructor and never again (no setter, no
/// upgrade): a new layout or class version is a new deployment, as the class hashes the world
/// class compiles are a new world class.
#[starknet::contract]
pub mod SplitChain {
    use slingfall_game::chunk::hash_felts;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::syscalls::{library_call_syscall, send_message_to_l1_syscall};
    use starknet::{ClassHash, SyscallResultTrait};
    use super::MARKER;

    #[storage]
    struct Storage {
        build: ClassHash,
        settle: ClassHash,
        edit: ClassHash,
        world: ClassHash,
        outputs: ClassHash,
        /// The world class takes the state as one length-prefixed span (`crate::lean`).
        raw: bool,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        build: ClassHash,
        settle: ClassHash,
        edit: ClassHash,
        world: ClassHash,
        outputs: ClassHash,
        raw: bool,
    ) {
        self.build.write(build);
        self.settle.write(settle);
        self.edit.write(edit);
        self.world.write(world);
        self.outputs.write(outputs);
        self.raw.write(raw);
    }

    /// `init(level)`: the settled state of the level; message `[LEVEL_HASH, STATE_OUT_HASH]`.
    #[external(v0)]
    fn init(ref self: ContractState, level: Span<felt252>) -> Span<felt252> {
        let built = library_call_syscall(self.build.read(), selector!("build"), level)
            .unwrap_syscall();
        let settled = library_call_syscall(self.settle.read(), selector!("settle"), built)
            .unwrap_syscall();
        let state = library_call_syscall(self.edit.read(), selector!("sleep_all"), settled)
            .unwrap_syscall();
        let payload = array![hash_felts(level), hash_felts(state)];
        send_message_to_l1_syscall(MARKER, payload.span()).unwrap_syscall();
        state
    }

    /// `step_chunk(state, inputs, shot, k)`: at most `k` ticks of shot `shot`; message
    /// `[STATE_IN_HASH, INPUTS_HASH, shot, k, STATE_OUT_HASH]`. Returns the new state, then
    /// `[stepped, over]`.
    #[external(v0)]
    fn step_chunk(
        ref self: ContractState, state: Span<felt252>, inputs: Span<felt252>, shot: u8, k: u32,
    ) -> Span<felt252> {
        let raw = self.raw.read();
        let mut calldata = array![];
        if raw {
            calldata.append(state.len().into());
        }
        calldata.append_span(state);
        inputs.serialize(ref calldata);
        calldata.append(shot.into());
        calldata.append(k.into());
        let mut ret = library_call_syscall(
            self.world.read(), selector!("step_chunk"), calldata.span(),
        )
            .unwrap_syscall();
        if raw {
            let _ = ret.pop_front();
        }
        let next = ret.slice(0, ret.len() - 2);
        let payload = array![
            hash_felts(state), hash_felts(inputs), shot.into(), k.into(), hash_felts(next),
        ];
        send_message_to_l1_syscall(MARKER, payload.span()).unwrap_syscall();
        ret
    }

    /// `outputs(state, inputs)`: the 10 D4 felts of a finished state; message
    /// `[STATE_IN_HASH, INPUTS_HASH] ++ outputs`.
    #[external(v0)]
    fn outputs(
        ref self: ContractState, state: Span<felt252>, inputs: Span<felt252>,
    ) -> Span<felt252> {
        let mut calldata = array![];
        calldata.append_span(state);
        calldata.append_span(inputs);
        let mut ret = library_call_syscall(
            self.outputs.read(), selector!("outputs"), calldata.span(),
        )
            .unwrap_syscall();
        let _ = ret.pop_front();
        let mut payload = array![hash_felts(state), hash_felts(inputs)];
        payload.append_span(ret);
        send_message_to_l1_syscall(MARKER, payload.span()).unwrap_syscall();
        ret
    }
}
