//! The class hashes of every class this crate declares, pinned in one module: the constants are the
//! hashes snforge declares. The classes that library-call others compile them as constants
//! (`GameClasses`:
//! rapier's stage classes; `PinnedSplit`: `RulesClass`, `EditClass`, `StepClass`), as a game would
//! after declaring them; the others (`WorldClass`, `FallbackGame`, the chain's classes) are pinned
//! for the deployment that reads them. `tests::hashes::test_pinned_class_hashes` fails, printing
//! the stale ones, when a class changes without its constant being regenerated (`scripts/pin.py`).

use rapier2d_classes::ClassHashes;
use starknet::ClassHash;

/// Where the world classes find this crate's declared classes.
pub trait SplitHashes {
    /// `crate::lean::RulesClass` (layout (e)).
    fn rules() -> ClassHash;
    /// `crate::classes::EditClass`.
    fn edit() -> ClassHash;
    /// `crate::classes::StepClass` (layout (b)).
    fn step() -> ClassHash;
}

pub const CONTACT_BALL_HASH: felt252 =
    0x4efa41be660cdf0afad6953de378645d439efea43d9409603db060d432c38df;
pub const CONTACT_POLYGON_HASH: felt252 =
    0x7bfd56046f343075ac1c74a80bec6e00f3d3ba5c605b865e10e965ff403204c;
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
pub const RULES_HASH: felt252 = 0x5ef41e0bdec0ac9a3e03031c504fbfb008093bf055360b422bd290f53c2a0;
pub const EDIT_HASH: felt252 = 0x55aa105913cf02f7cdf49ffdbfed75c38449ef9ebd83d49bf5a9f29491e2440;
pub const STEP_HASH: felt252 = 0x70f5ddc00c002eccc615047984e25e3f6ac5fa522a110d22985add7696a2c70;

pub const WORLD_HASH: felt252 = 0x6f9db96d38a847f630d1c00bbaa49defd011c5cd3649b9968f68459dd1c4a79;
pub const FALLBACK_GAME_HASH: felt252 =
    0x58891d8ad938fde422281f13941e3521a26af6e7cdc1397f85602130d366ae7;
pub const BUILD_HASH: felt252 = 0x6f809c726f650052b9336265a36d4ac5ac8f884fce3791cf1ed4e6a5de52896;
pub const SETTLE_HASH: felt252 = 0x402c539ddcb9ccf1e859798cfa36891971ca12018f671662fc502f6dedccc3d;
pub const OUTPUTS_HASH: felt252 = 0x3a619e67f7d06f3a10d54f9a2b79b9cc681155273b33b24892a05b59fd236fc;
pub const SPLIT_CHAIN_HASH: felt252 =
    0x6faa02c304d1de84c0111cc0d72e12ab02fcb40934b19008384f34bbcf4712a;

/// The class hash of the stage classes the game never calls (`SolverClass`, `ForceEventsClass`:
/// `SlimSplitStages` runs the solve in `SolveAdvanceClass` and the force events in process,
/// `tests/called.cairo`): none is built or declared, and a call of it fails on an undeclared class.
const NOT_DECLARED: ClassHash = 0.try_into().unwrap();

/// The stage classes of `rapier2d_classes` at their declared hashes.
pub impl GameClasses of ClassHashes {
    fn contact_ball() -> ClassHash {
        const H: ClassHash = CONTACT_BALL_HASH.try_into().unwrap();
        H
    }

    fn contact_polygon() -> ClassHash {
        const H: ClassHash = CONTACT_POLYGON_HASH.try_into().unwrap();
        H
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

/// This crate's classes at their declared hashes.
pub impl PinnedSplit of SplitHashes {
    fn rules() -> ClassHash {
        const H: ClassHash = RULES_HASH.try_into().unwrap();
        H
    }

    fn edit() -> ClassHash {
        const H: ClassHash = EDIT_HASH.try_into().unwrap();
        H
    }

    fn step() -> ClassHash {
        const H: ClassHash = STEP_HASH.try_into().unwrap();
        H
    }
}

/// Every declared class of the default build by contract name, with its pinned hash.
pub fn pinned() -> Array<(ByteArray, felt252)> {
    array![
        ("ContactBallClass", CONTACT_BALL_HASH), ("ContactPolygonClass", CONTACT_POLYGON_HASH),
        ("SolveAdvanceClass", SOLVE_ADVANCE_HASH), ("IslandsClass", ISLANDS_HASH),
        ("BroadPhaseClass", BROAD_PHASE_HASH), ("MassClass", MASS_HASH),
        ("NarrowPhaseClass", NARROW_PHASE_HASH), ("ActiveSetClass", ACTIVE_SET_HASH),
        ("RulesClass", RULES_HASH), ("EditClass", EDIT_HASH), ("StepClass", STEP_HASH),
        ("WorldClass", WORLD_HASH), ("FallbackGame", FALLBACK_GAME_HASH),
        ("BuildClass", BUILD_HASH), ("SettleClass", SETTLE_HASH), ("OutputsClass", OUTPUTS_HASH),
        ("SplitChain", SPLIT_CHAIN_HASH),
    ]
}
