//! The class hashes the spike's classes compile as constants (`SlimSplitStages`' stage classes,
//! and this crate's rules, edit and step classes), as a game would after declaring them. They are
//! the hashes snforge declares (`tests::hashes::test_pinned_class_hashes` prints the stale ones).

use rapier2d_classes::ClassHashes;
use starknet::ClassHash;

/// Where the world classes find this crate's declared classes.
pub trait SplitHashes {
    /// `crate::classes::RulesClass`.
    fn rules() -> ClassHash;
    /// `crate::lean::LeanRulesClass` (layout (e)).
    fn lean_rules() -> ClassHash;
    /// `crate::classes::EditClass`.
    fn edit() -> ClassHash;
    /// `crate::classes::StepClass` (layout (b)).
    fn step() -> ClassHash;
}

pub const CONTACT_BALL_HASH: felt252 =
    0x7821f7fd3f73ec3e2000804015f615c63a5dde2495e2a8b3097f6e701f4153f;
pub const CONTACT_POLYGON_HASH: felt252 =
    0x641aec5d123fca908fcb15ac8ea473bbd08dc2a2d06ca6fba995f4e0ac98676;
pub const SOLVER_HASH: felt252 = 0x447d2dddc0d41fd2ac6d384e96f468d300f0509756eeb49435f004eac8a33ef;
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
pub const FORCE_EVENTS_HASH: felt252 =
    0x322bab3a8c6a846ade7d18d85db51f1ad5cd92c1680dfc79e7049510928fe5a;
pub const RULES_HASH: felt252 = 0x784b7c95076f548756192808fa7cba543e4de29f9587e46d36b848be51600bd;
pub const LEAN_RULES_HASH: felt252 = 0x4;
pub const EDIT_HASH: felt252 = 0x1c660a819b1a89e1b24a7c55198b006a9563a10f1c6e7db4592e7a1e60386b;
pub const STEP_HASH: felt252 = 0x3730c4a319a31a3a9f2c399cce7c1ac8f1535feda549cc6059022ba4763f5;

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
        const H: ClassHash = SOLVER_HASH.try_into().unwrap();
        H
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
        const H: ClassHash = FORCE_EVENTS_HASH.try_into().unwrap();
        H
    }
}

/// This crate's classes at their declared hashes.
pub impl PinnedSplit of SplitHashes {
    fn rules() -> ClassHash {
        const H: ClassHash = RULES_HASH.try_into().unwrap();
        H
    }

    fn lean_rules() -> ClassHash {
        const H: ClassHash = LEAN_RULES_HASH.try_into().unwrap();
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
