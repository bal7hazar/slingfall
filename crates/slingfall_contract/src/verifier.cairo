//! `Verifier` interface over the evidence of a claimed `Outputs` (`docs/DESIGN.md` D9), with two
//! implementations: `Snip36Verifier` (the SNIP-36 `proof_facts` of the transaction) and
//! `StubVerifier` (an admin-signed attestation, the interim path of research 01 §4 rank 2).

use core::ecdsa::check_ecdsa_signature;
use core::poseidon::poseidon_hash_span;
use slingfall_level::outputs::{Outputs, OutputsTrait};
use crate::simulate::MARKER;

/// Position of the virtual-OS program hash in `tx_info.proof_facts`. Provisional layout until the
/// SNIP-36 round trip (lot E2) pins it: `[program_hash, ...]`, the L2 to L1 message hashes among
/// the facts that follow it.
pub const PROGRAM_HASH_INDEX: usize = 0;

/// The verifier `submit` runs, switched by the admin.
#[derive(Copy, Drop, Serde, PartialEq, Debug, starknet::Store)]
pub enum VerifierKind {
    /// `Snip36Verifier`: in-protocol proof facts (the target, `docs/DESIGN.md` D9).
    #[default]
    Snip36,
    /// `StubVerifier`: an attestation signed by the admin's key.
    Stub,
}

/// Decides whether `evidence` backs `claim`. `false` rejects the submission.
pub trait Verifier<T> {
    fn check(ref self: T, claim: Outputs, evidence: Span<felt252>) -> bool;
}

/// SNIP-36: the transaction's `proof_facts` must name the expected virtual-OS program and hold the
/// hash of the message `simulate` sent (`from` = this contract, `to` = `MARKER`, payload = the
/// claimed outputs). `evidence` is not read: the facts come from the protocol.
#[derive(Drop)]
pub struct Snip36Verifier {
    /// Expected virtual-OS program hash; `0` (unset) rejects everything.
    pub virtual_os_hash: felt252,
    /// Address of the contract that sent the message in the virtual OS (this contract).
    pub from: felt252,
    /// `get_execution_info().tx_info.proof_facts`.
    pub facts: Span<felt252>,
}

impl Snip36VerifierImpl of Verifier<Snip36Verifier> {
    fn check(ref self: Snip36Verifier, claim: Outputs, evidence: Span<felt252>) -> bool {
        let facts = self.facts;
        if self.virtual_os_hash == 0 || facts.len() <= PROGRAM_HASH_INDEX {
            return false;
        }
        if *facts[PROGRAM_HASH_INDEX] != self.virtual_os_hash {
            return false;
        }
        let expected = message_hash(self.from, MARKER, claim.to_felts().span());
        let mut messages = facts
            .slice(PROGRAM_HASH_INDEX + 1, facts.len() - PROGRAM_HASH_INDEX - 1);
        for fact in messages {
            if *fact == expected {
                return true;
            }
        }
        false
    }
}

/// Interim verifier: `evidence = [r, s]`, a Stark-curve ECDSA signature by `public_key` of
/// `attestation_hash(outputs felts)`.
#[derive(Drop)]
pub struct StubVerifier {
    /// The admin's attestation public key; `0` (unset) rejects everything.
    pub public_key: felt252,
}

impl StubVerifierImpl of Verifier<StubVerifier> {
    fn check(ref self: StubVerifier, claim: Outputs, evidence: Span<felt252>) -> bool {
        if self.public_key == 0 || evidence.len() != 2 {
            return false;
        }
        let hash = attestation_hash(claim.to_felts().span());
        check_ecdsa_signature(hash, self.public_key, *evidence[0], *evidence[1])
    }
}

/// Hash of an L2 to L1 message as `submit` looks for it among the proof facts:
/// `poseidon_hash_span([from, to, payload.len(), ...payload])`. The one place of this rule
/// (provisional until lot E2 checks it against the virtual OS).
pub fn message_hash(from: felt252, to: felt252, payload: Span<felt252>) -> felt252 {
    let mut felts: Array<felt252> = array![from, to, payload.len().into()];
    felts.append_span(payload);
    poseidon_hash_span(felts.span())
}

/// What the attestation key signs: `poseidon_hash_span(outputs felts)`.
pub fn attestation_hash(outputs: Span<felt252>) -> felt252 {
    poseidon_hash_span(outputs)
}

#[cfg(test)]
mod tests {
    use slingfall_level::outputs::{Outputs, OutputsTrait};
    use slingfall_testing::opaque;
    use crate::simulate::MARKER;
    use crate::submit::fixtures::{
        ATTESTATION_KEY, GOLDEN_ATTESTATION_HASH, GOLDEN_MESSAGE_HASH, GOLDEN_R, GOLDEN_S,
        MESSAGE_FROM as FROM, golden_claim,
    };
    use super::{Snip36Verifier, StubVerifier, Verifier, attestation_hash, message_hash};

    const VIRTUAL_OS_HASH: felt252 = 0x53f6c9fc;

    fn snip36(facts: Span<felt252>) -> Snip36Verifier {
        Snip36Verifier { virtual_os_hash: VIRTUAL_OS_HASH, from: FROM, facts }
    }

    #[test]
    fn test_message_hash_is_golden() {
        let payload = golden_claim().to_felts();
        assert_eq!(message_hash(FROM, MARKER, payload.span()), GOLDEN_MESSAGE_HASH);
        // Every field of the message is committed to.
        assert_ne!(message_hash(FROM + 1, MARKER, payload.span()), GOLDEN_MESSAGE_HASH);
        assert_ne!(message_hash(FROM, MARKER + 1, payload.span()), GOLDEN_MESSAGE_HASH);
        assert_ne!(message_hash(FROM, MARKER, payload.span().slice(0, 9)), GOLDEN_MESSAGE_HASH);
    }

    #[test]
    fn test_snip36_accepts_the_message_among_the_facts() {
        let cases: Array<Array<felt252>> = array![
            array![VIRTUAL_OS_HASH, GOLDEN_MESSAGE_HASH],
            array![VIRTUAL_OS_HASH, 0x1, 0x2, GOLDEN_MESSAGE_HASH, 0x3],
        ];
        for facts in cases {
            let mut verifier = snip36(facts.span());
            assert!(verifier.check(golden_claim(), array![].span()));
        }
    }

    #[test]
    fn test_snip36_rejects() {
        let mut other = golden_claim();
        other.score += 1;
        // (facts, claim): no facts, wrong program, message missing, program hash only counted at
        // its index, another claim.
        let cases: Array<(Array<felt252>, Outputs)> = array![
            (array![], golden_claim()),
            (array![VIRTUAL_OS_HASH + 1, GOLDEN_MESSAGE_HASH], golden_claim()),
            (array![VIRTUAL_OS_HASH, 0x1], golden_claim()),
            (array![GOLDEN_MESSAGE_HASH, VIRTUAL_OS_HASH], golden_claim()),
            (array![VIRTUAL_OS_HASH, GOLDEN_MESSAGE_HASH], other),
        ];
        for (facts, claim) in cases {
            let mut verifier = snip36(facts.span());
            assert!(!verifier.check(claim, array![].span()));
        }
        // An unset program hash rejects even matching facts.
        let facts = array![0, GOLDEN_MESSAGE_HASH];
        let mut unset = Snip36Verifier { virtual_os_hash: 0, from: FROM, facts: facts.span() };
        assert!(!unset.check(golden_claim(), array![].span()));
    }

    #[test]
    fn test_attestation_hash_is_golden() {
        assert_eq!(attestation_hash(golden_claim().to_felts().span()), GOLDEN_ATTESTATION_HASH);
    }

    #[test]
    fn test_stub_accepts_the_golden_signature() {
        let mut verifier = StubVerifier { public_key: ATTESTATION_KEY };
        assert!(verifier.check(golden_claim(), array![GOLDEN_R, GOLDEN_S].span()));
    }

    #[test]
    fn test_stub_rejects() {
        let mut other = golden_claim();
        other.won = false;
        // (public key, claim, evidence).
        let cases: Array<(felt252, Outputs, Array<felt252>)> = array![
            (ATTESTATION_KEY, other, array![GOLDEN_R, GOLDEN_S]),
            (ATTESTATION_KEY, golden_claim(), array![GOLDEN_R, GOLDEN_S + 1]),
            (ATTESTATION_KEY, golden_claim(), array![GOLDEN_S, GOLDEN_R]),
            (ATTESTATION_KEY, golden_claim(), array![GOLDEN_R]),
            (ATTESTATION_KEY, golden_claim(), array![GOLDEN_R, GOLDEN_S, 0]),
            (ATTESTATION_KEY, golden_claim(), array![0, 0]),
            (0, golden_claim(), array![GOLDEN_R, GOLDEN_S]),
            (GOLDEN_R, golden_claim(), array![GOLDEN_R, GOLDEN_S]),
        ];
        for (public_key, claim, evidence) in cases {
            let mut verifier = StubVerifier { public_key };
            assert!(!verifier.check(claim, evidence.span()));
        }
    }

    #[test]
    fn steps_verifier_stub_check() {
        let mut verifier = StubVerifier { public_key: opaque(ATTESTATION_KEY) };
        let evidence = opaque(array![GOLDEN_R, GOLDEN_S]);
        assert!(verifier.check(opaque(golden_claim()), evidence.span()));
    }

    #[test]
    fn steps_verifier_snip36_check__4_facts() {
        let facts = opaque(array![VIRTUAL_OS_HASH, 0x1, 0x2, GOLDEN_MESSAGE_HASH]);
        let mut verifier = snip36(facts.span());
        assert!(verifier.check(opaque(golden_claim()), array![].span()));
    }
}
