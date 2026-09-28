//! Every declared class is at its pinned hash (`slingfall_split::hashes`).

use slingfall_split::hashes::pinned;
use crate::harness::{declared, install};

/// Prints `pin <name> <hash>` for each stale pin (`scripts/pin.py` reads it) and fails.
#[test]
fn test_pinned_class_hashes() {
    install();
    let mut stale = false;
    for (name, pin) in pinned() {
        let hash: felt252 = declared(name.clone()).into();
        if hash != pin {
            println!("pin {name} {hash:x}");
            stale = true;
        }
    }
    assert!(!stale, "class hashes: stale pins (python3 crates/slingfall_split/scripts/pin.py)");
}

/// The alternatives' rules class (feature `probes`).
#[test]
#[cfg(feature: 'probes')]
fn test_pinned_probe_hashes() {
    install();
    let hash: felt252 = declared("TypedRulesClass").into();
    if hash != slingfall_split::probes::hashes::TYPED_RULES_HASH {
        println!("pin TypedRulesClass {hash:x}");
        panic!(
            "class hashes: stale probe pin (python3 crates/slingfall_split/scripts/pin.py --probes)",
        );
    }
}
