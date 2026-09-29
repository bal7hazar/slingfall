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

pub const WORLD_EDIT_HASH: felt252 =
    0x6b80770cb8a1b6d5d31003c35a670cede94c049e22718077c8f728f1ccf3610;
pub const CONTACT_BALL_HASH: felt252 =
    0x4efa41be660cdf0afad6953de378645d439efea43d9409603db060d432c38df;
pub const SOLVE_ADVANCE_HASH: felt252 =
    0x6f22ca2b78b9955a5b288e4e80663a65fcb997739e11b68bf5c2226022b72d3;
pub const ISLANDS_HASH: felt252 = 0x640435f9c277ebb55e1c01979eeb2cf84948424dcacbd669e11055d12b78bde;
pub const BROAD_PHASE_HASH: felt252 =
    0x63c302fc078a15b81bc53c4d4bbc7c3c10920773cedcf9c4edf5a64c8e7a2b8;
pub const MASS_HASH: felt252 = 0x59bd3e4c27c773dc1cd65d09408315b6344aad370a0ef1c60f8b24af42c0fce;
pub const NARROW_PHASE_HASH: felt252 =
    0x447bcf48b1735aaba6fdfaa632aed8582d115764ae676fdda24c31b20a10dbd;
pub const ACTIVE_SET_HASH: felt252 =
    0x74d52fcda3b1da92328620cffef1ff1b9563f36b5cb02512dd1505a5fe12b14;
pub const RULES_HASH: felt252 = 0x712ae1a857fbf88caef8749cda329cc9746a7fd01d2095357d5f1c4abefb9d0;
pub const STEP_HASH: felt252 = 0x70f5ddc00c002eccc615047984e25e3f6ac5fa522a110d22985add7696a2c70;

pub const WORLD_HASH: felt252 = 0x3334afa92dfe4025d77d6e9358cd62850b3b8442e36aa6bca10367900968523;
pub const FALLBACK_GAME_HASH: felt252 =
    0x58891d8ad938fde422281f13941e3521a26af6e7cdc1397f85602130d366ae7;
pub const BUILD_HASH: felt252 = 0x6e49b45453d93f54a0b8b88f402c548456d5da1bf63d7d4fcf4aafb5fa860d8;
pub const SETTLE_HASH: felt252 = 0x70334b5eb173685c788f43c0e2ddc129b9aa6fdbb7e8222f172a8f488c9fb15;
pub const OUTPUTS_HASH: felt252 = 0x3a619e67f7d06f3a10d54f9a2b79b9cc681155273b33b24892a05b59fd236fc;
pub const SPLIT_CHAIN_HASH: felt252 =
    0x6120153d1ba21f4599a43a49da1e31a8a432ef7cb12c6fff4196e1e23b72cdd;

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
