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
    0x7821f7fd3f73ec3e2000804015f615c63a5dde2495e2a8b3097f6e701f4153f;
pub const CONTACT_POLYGON_HASH: felt252 =
    0x641aec5d123fca908fcb15ac8ea473bbd08dc2a2d06ca6fba995f4e0ac98676;
pub const SOLVE_ADVANCE_HASH: felt252 =
    0x484f69de20d79c8ec04effc9557b3ce9a63cc0940d9643f9a954c4a436c4239;
pub const ISLANDS_HASH: felt252 = 0x6124b2b6093c09826da9b57e8008363ad730eae18a95ad5d6f5208342830f54;
pub const BROAD_PHASE_HASH: felt252 =
    0x7d3eed01dc6daa7f8ccdc93ffbed0f86c938302bbc3f8b1fcc24694b448c4d7;
pub const MASS_HASH: felt252 = 0x5415bd22e6c965a3c006b598c748686672ef13cecde4d60cadb674184e451a2;
pub const NARROW_PHASE_HASH: felt252 =
    0x69d00ab7e3ebdb09cfeaee8bb6acc4b2f49468e06d516c72f16936b44dcf336;
pub const ACTIVE_SET_HASH: felt252 =
    0x4a6e55fafd8273f75152b3509aa40223f5f50e882ab1978a91beeb895201d02;
pub const RULES_HASH: felt252 = 0x1252255e389d7be57c38073f06d273ece226ba8c5158f0631603aeb1591b4ae;
pub const EDIT_HASH: felt252 = 0x38c35b4f684d8228998d652f48a13d0631be9b9db51bc5e46eb4c86c5cb1dd5;
pub const STEP_HASH: felt252 = 0x3730c4a319a31a3a9f2c399cce7c1ac8f1535feda549cc6059022ba4763f5;

pub const WORLD_HASH: felt252 = 0x30b53e086f4d809518e166b070d4092cd4a7684aba7e2c81460673ac74f8b38;
pub const FALLBACK_GAME_HASH: felt252 =
    0x720225f8d2387c33d7412b20f6e0e311a0afa72aa42d2374b05f2c2e52760e3;
pub const BUILD_HASH: felt252 = 0x5072b33404b0460aecc752ac5f061f93536bc40de808b2c31b8feebb770b94b;
pub const SETTLE_HASH: felt252 = 0x7e9a195cd593b728e4ee7b5338d81f564673afbad5b7d11382f1a76e58d457f;
pub const OUTPUTS_HASH: felt252 = 0x30e684c2fd7005e22c7fe4200681c27d76ab2bbe8abcf3633da59ebc0b0558d;
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
