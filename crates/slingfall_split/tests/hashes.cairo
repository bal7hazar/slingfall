//! Every declared class is at its pinned hash (`slingfall_split::hashes`), and the bundle hash is
//! the Poseidon of the pinned bundle.

use slingfall_split::hashes::{BUNDLE_HASH, bundle_hash, pinned};
use crate::harness::{declared, install};

/// Prints `pin <name> <hash>` for each stale pin (`scripts/pin.py` reads it; `Bundle` is
/// `BUNDLE_HASH`) and fails.
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
    let bundle = bundle_hash();
    if bundle != BUNDLE_HASH {
        println!("pin Bundle {bundle:x}");
        stale = true;
    }
    assert!(!stale, "class hashes: stale pins (python3 crates/slingfall_split/scripts/pin.py)");
}

/// The alternatives' rules and edit classes (feature `probes`).
#[test]
#[cfg(feature: 'probes')]
fn test_pinned_probe_hashes() {
    install();
    let pins: Array<(ByteArray, felt252)> = array![
        ("TypedRulesClass", slingfall_split::probes::hashes::TYPED_RULES_HASH),
        ("EditClass", slingfall_split::probes::hashes::EDIT_HASH),
    ];
    let mut stale = false;
    for (name, pin) in pins {
        let hash: felt252 = declared(name.clone()).into();
        if hash != pin {
            println!("pin {name} {hash:x}");
            stale = true;
        }
    }
    assert!(
        !stale,
        "class hashes: stale probe pins (python3 crates/slingfall_split/scripts/pin.py --probes)",
    );
}
