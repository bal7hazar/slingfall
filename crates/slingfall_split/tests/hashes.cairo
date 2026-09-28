//! The class hashes the world classes compile (`slingfall_split::hashes`) are the declared ones.

use slingfall_split::hashes::{
    ACTIVE_SET_HASH, BROAD_PHASE_HASH, CONTACT_BALL_HASH, CONTACT_POLYGON_HASH, EDIT_HASH,
    FORCE_EVENTS_HASH, ISLANDS_HASH, LEAN_RULES_HASH, MASS_HASH, NARROW_PHASE_HASH, RULES_HASH,
    SOLVER_HASH, SOLVE_ADVANCE_HASH, STEP_HASH,
};
use crate::harness::{classes, declared};

#[test]
fn test_pinned_class_hashes() {
    let pinned = array![
        CONTACT_BALL_HASH, CONTACT_POLYGON_HASH, SOLVER_HASH, SOLVE_ADVANCE_HASH, ISLANDS_HASH,
        BROAD_PHASE_HASH, MASS_HASH, NARROW_PHASE_HASH, ACTIVE_SET_HASH, FORCE_EVENTS_HASH,
        RULES_HASH, LEAN_RULES_HASH, EDIT_HASH, STEP_HASH,
    ];
    let mut stale = false;
    let mut i = 0;
    for name in classes() {
        let hash: felt252 = declared(name.clone()).into();
        if hash != *pinned[i] {
            println!("pin {name} {hash:x}");
            stale = true;
        }
        i += 1;
    }
    assert!(!stale, "class hashes: stale pins");
}
