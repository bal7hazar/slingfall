//! The class hashes of every class this crate declares, pinned in one module: the constants are the
//! hashes snforge declares. The classes that library-call others compile them as constants
//! (`GameClasses`: rapier's stage classes; `PinnedSplit`: `RulesClass`, rapier's `WorldEditClass`,
//! `StepClass`), as a game would after declaring them; the others (`WorldClass`, `FallbackGame`,
//! the chain's classes) are pinned for the deployment that reads them.
//! `tests::hashes::test_pinned_class_hashes` fails, printing the stale ones, when a class changes
//! without its constant being regenerated (`scripts/pin.py`), and when [`BUNDLE_HASH`] is not the
//! Poseidon of [`bundle`].

use core::poseidon::poseidon_hash_span;
use rapier2d_classes::ClassHashes;
use starknet::ClassHash;

/// Where the world classes find the declared classes they call besides rapier's stages.
pub trait SplitHashes {
    /// `crate::lean::RulesClass` (layout (e)).
    fn rules() -> ClassHash;
    /// `rapier2d_classes::edits::WorldEditClass` (layout (e)'s edit crossing).
    fn edit() -> ClassHash;
    /// `crate::classes::StepClass` (layout (b)).
    fn step() -> ClassHash;
}

// Build root of these class hashes: /home/runner/work/slingfall/slingfall
pub const WORLD_EDIT_HASH: felt252 =
    0x10c4d0f04c869f302be8209a7d230809628831ec2bb4fd93603784dfcc98693;
pub const CONTACT_BALL_HASH: felt252 =
    0x5f9b275f6554d67248a2d06302bc48eb7fc08854ab213a36cd558dc9ef7d08b;
pub const SOLVE_ADVANCE_HASH: felt252 =
    0xb0f496a340509f79c875459843cbf6870aa01f35231b72ecaf0d9403ed36d2;
pub const ISLANDS_HASH: felt252 = 0x3e2a3e1ff275efee0257ef842298712e98b6b555203048a5b9b2648e24c9a46;
pub const BROAD_PHASE_HASH: felt252 =
    0x53423c89826872bf0609676dde383e1e7fd4716d8c76c4964785c1e73a51014;
pub const MASS_HASH: felt252 = 0x60051ffb6f7fe7e5a29c6ac58db800bafcfa716e79b3d97a058a71027e10c3b;
pub const NARROW_PHASE_HASH: felt252 =
    0x7c3425c0a8f5c38a3941fdb3f41d495729347b049ca3eb8934adf80b6366502;
pub const ACTIVE_SET_HASH: felt252 =
    0x5ea0e678c30220f403888fa50bf0b304040ee2628f14edfa4158cf082e90e9b;
pub const RULES_HASH: felt252 = 0x37c9b47d091e7531d86e6ac40b3f310345aaf60d3e9cc781433331f83ea2be;
pub const STEP_HASH: felt252 = 0x19fc37d407bfe629a5cbcde2f0a2ac031fc6013a01c2dd6a3bc17f270fa855c;

pub const WORLD_HASH: felt252 = 0x683a09686e877faa7278d976908581cdf94a11dde45d9c2c886a0d4fcf13df1;
pub const FALLBACK_GAME_HASH: felt252 =
    0x52830d62b9435656c169d1b2007057c7475665ec5529d51ada081594637ef0d;
pub const BUILD_HASH: felt252 = 0x592421400795bf672876d4270c8cd5e53b853f60e841ec24af7c9459ecb5bc0;
pub const SETTLE_HASH: felt252 = 0x5954c1c3abb4a001621e3c8234680cdcf67c1308851c8da36ba5ae1ffe486e2;
pub const OUTPUTS_HASH: felt252 = 0x4debb40a1fa636c3a68c9c540236ef5caf0c034d413dd86db84a95b76c0a0d6;
pub const SPLIT_CHAIN_HASH: felt252 =
    0xd86128e076fb3c81f25cfb801c2c824299204c2da26257af4ad879487ddf0a;

/// The bundle hash of layout (e)'s chain (contract v3's `pin_chain`): Poseidon of [`bundle`].
/// `services/prove/snip36.py` (`own_bundle`) and `deploy/split.ts` (`bundleOf`) compute the same
/// value from `classes.json`'s order and the constants above (their tests check this one).
pub const BUNDLE_HASH: felt252 = 0x8a629c64c8e6c34dcc4cd0f29fd51c2c34d19cefe83647335a98825ddd7368;

/// The class hash of the stage classes the game never calls (`ContactPolygonClass`: in
/// `NarrowPhaseClass` since alpha.8; `SolverClass`, `ForceEventsClass`: `SlimSplitStages` runs the
/// solve in `SolveAdvanceClass` and the force events in process; `tests/called.cairo`): none is
/// built or declared, and a call of it fails on an undeclared class.
const NOT_DECLARED: ClassHash = 0.try_into().unwrap();

/// The stage classes of `rapier2d_classes` at their declared hashes.
pub impl GameClasses of ClassHashes {
    fn contact_ball() -> ClassHash {
        const H: ClassHash = CONTACT_BALL_HASH.try_into().unwrap();
        H
    }

    fn contact_polygon() -> ClassHash {
        NOT_DECLARED
    }

    fn solver() -> ClassHash {
        NOT_DECLARED
    }

    fn solve_advance() -> ClassHash {
        const H: ClassHash = SOLVE_ADVANCE_HASH.try_into().unwrap();
        H
    }

    fn islands() -> ClassHash {
        const H: ClassHash = ISLANDS_HASH.try_into().unwrap();
        H
    }

    fn broad_phase() -> ClassHash {
        const H: ClassHash = BROAD_PHASE_HASH.try_into().unwrap();
        H
    }

    fn mass() -> ClassHash {
        const H: ClassHash = MASS_HASH.try_into().unwrap();
        H
    }

    fn narrow_phase() -> ClassHash {
        const H: ClassHash = NARROW_PHASE_HASH.try_into().unwrap();
        H
    }

    fn active_set() -> ClassHash {
        const H: ClassHash = ACTIVE_SET_HASH.try_into().unwrap();
        H
    }

    fn force_events() -> ClassHash {
        NOT_DECLARED
    }
}

/// The declared classes the world classes call besides the stages, at their hashes.
pub impl PinnedSplit of SplitHashes {
    fn rules() -> ClassHash {
        const H: ClassHash = RULES_HASH.try_into().unwrap();
        H
    }

    fn edit() -> ClassHash {
        const H: ClassHash = WORLD_EDIT_HASH.try_into().unwrap();
        H
    }

    fn step() -> ClassHash {
        const H: ClassHash = STEP_HASH.try_into().unwrap();
        H
    }
}

/// The class hashes of layout (e)'s bundle in bundle order (`classes.json`: `chain`, then
/// `rapier`; `scripts/classes.py` derives this list).
pub fn bundle() -> Array<felt252> {
    array![
        SPLIT_CHAIN_HASH, BUILD_HASH, SETTLE_HASH, WORLD_HASH, OUTPUTS_HASH, RULES_HASH,
        WORLD_EDIT_HASH, CONTACT_BALL_HASH, SOLVE_ADVANCE_HASH, ISLANDS_HASH, BROAD_PHASE_HASH,
        MASS_HASH, NARROW_PHASE_HASH, ACTIVE_SET_HASH,
    ]
}

/// Poseidon of [`bundle`] (what [`BUNDLE_HASH`] must be).
pub fn bundle_hash() -> felt252 {
    poseidon_hash_span(bundle().span())
}

/// Every declared class of the default build by contract name, with its pinned hash.
pub fn pinned() -> Array<(ByteArray, felt252)> {
    array![
        ("WorldEditClass", WORLD_EDIT_HASH), ("ContactBallClass", CONTACT_BALL_HASH),
        ("SolveAdvanceClass", SOLVE_ADVANCE_HASH), ("IslandsClass", ISLANDS_HASH),
        ("BroadPhaseClass", BROAD_PHASE_HASH), ("MassClass", MASS_HASH),
        ("NarrowPhaseClass", NARROW_PHASE_HASH), ("ActiveSetClass", ACTIVE_SET_HASH),
        ("RulesClass", RULES_HASH), ("StepClass", STEP_HASH), ("WorldClass", WORLD_HASH),
        ("FallbackGame", FALLBACK_GAME_HASH), ("BuildClass", BUILD_HASH),
        ("SettleClass", SETTLE_HASH), ("OutputsClass", OUTPUTS_HASH),
        ("SplitChain", SPLIT_CHAIN_HASH),
    ]
}
