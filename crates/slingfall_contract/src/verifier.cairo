//! `Verifier` interface over the evidence of a claimed `Outputs` (`docs/DESIGN.md` D9), with three
//! implementations: `Snip36Verifier` (the SNIP-36 `proof_facts` of the transaction),
//! `StubVerifier` (an admin-signed attestation, the interim path of research 01 §4 rank 2) and
//! `SatelliteVerifier` (the Atlantic fact of the run, registered on Herodotus's Satellite:
//! `docs/proving.md` "Atlantic + Integrity").

use core::ecdsa::check_ecdsa_signature;
use core::integer::u128_byte_reverse;
use core::keccak::keccak_u256s_be_inputs;
use core::num::traits::Zero;
use core::poseidon::poseidon_hash_span;
use slingfall_level::outputs::{Outputs, OutputsTrait};
use starknet::ContractAddress;
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
    /// `SatelliteVerifier`: the Atlantic fact on the Satellite; `evidence` is the run's argument
    /// (`[len(level), level..., len(inputs), inputs...]`) and the record is settled.
    Satellite,
}

/// `pedersen(0, 0)`: the second felt of the Atlantic bootloader's output (its configuration, the
/// same in every query; `docs/proving.md` "Fact formula" step 3).
pub const PEDERSEN_0_0: felt252 = 0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804;
/// `is_mocked` of the Satellite's reads: mocked facts are never accepted.
pub const NOT_MOCKED: bool = false;

/// The constants of the fact chain, admin-settable (`set_satellite_config`); any zero field
/// rejects everything.
#[derive(Copy, Drop, Serde, PartialEq, Debug, starknet::Store)]
pub struct SatelliteConfig {
    /// The bootloader's (Pedersen) hash of `c1main`, pinned per release of the proven program.
    pub child_program_hash: felt252,
    /// Atlantic's bootloader program hash (`metadata.json` `program_hash`).
    pub atlantic_bootloader_hash: felt252,
    /// Integrity's `SHARP_BOOTLOADER_PROGRAM_HASH` (the outer program of the translated fact).
    pub sharp_bootloader_hash: felt252,
    /// Herodotus's Satellite (Starknet Sepolia `0x421cd9…676e`).
    pub satellite_address: ContractAddress,
}

/// The two reads of the Satellite (`HerodotusDev/satellite`,
/// `cairo/src/cairo_fact_registry.cairo`).
#[starknet::interface]
pub trait ISatellite<TState> {
    /// The Poseidon ("Integrity") fact, registered by translation with 96 security bits.
    fn isCairoFactValid(self: @TState, fact_hash: felt252, is_mocked: bool) -> bool;
    /// The SHARP (keccak) fact, bridged from Ethereum.
    fn isKeccakVerifiedFactHashValid(self: @TState, fact_hash: u256) -> bool;
}

/// Atlantic + Satellite: the claimed outputs and `evidence`, the run's argument `args =
/// [len(level), level..., len(inputs), inputs...]` (what `tracec.py args` writes), are the public
/// output of one proven run of `c1main`; its fact must be on the Satellite, either translated
/// (`isCairoFactValid`, one Poseidon) or, as long as Atlantic's translation stalls
/// (`docs/proving.md`), the bridged keccak fact (`isKeccakVerifiedFactHashValid`, a Keccak over the
/// output, computed only when the first read fails). The proven program decodes `args` (exactly one
/// level and one `Inputs`) and computes `level_hash`, `player` and `inputs_hash` from them: nothing
/// else needs binding, and the level felts come in calldata (cheaper than reading the registry:
/// `docs/proving.md` "Settled submit").
#[derive(Drop)]
pub struct SatelliteVerifier {
    pub config: SatelliteConfig,
}

impl SatelliteVerifierImpl of Verifier<SatelliteVerifier> {
    fn check(ref self: SatelliteVerifier, claim: Outputs, evidence: Span<felt252>) -> bool {
        let config = self.config;
        if config.child_program_hash == 0
            || config.atlantic_bootloader_hash == 0
            || config.sharp_bootloader_hash == 0
            || config.satellite_address.is_zero() {
            return false;
        }
        let out = atlantic_output(config.child_program_hash, claim, evidence);
        let satellite = ISatelliteDispatcher { contract_address: config.satellite_address };
        let fact = integrity_fact(
            config.sharp_bootloader_hash, config.atlantic_bootloader_hash, out.span(),
        );
        if satellite.isCairoFactValid(fact, NOT_MOCKED) {
            return true;
        }
        satellite
            .isKeccakVerifiedFactHashValid(sharp_fact(config.atlantic_bootloader_hash, out.span()))
    }
}

/// Atlantic's bootloader output for one run of `c1main`: `[0, PEDERSEN_0_0, 1, len(task) + 2,
/// child_program_hash, task...]` with `task = [0, 10, outputs..., len(args), args...]`
/// (`tools/atlantic/encoding.py`).
pub fn atlantic_output(
    child_program_hash: felt252, claim: Outputs, args: Span<felt252>,
) -> Array<felt252> {
    let outputs = claim.to_felts();
    let task_len = 3 + outputs.len() + args.len();
    let mut out: Array<felt252> = array![
        0, PEDERSEN_0_0, 1, (task_len + 2).into(), child_program_hash, 0, outputs.len().into(),
    ];
    out.append_span(outputs.span());
    out.append(args.len().into());
    out.append_span(args);
    out
}

/// `c1main`'s argument for a level and inputs: `[len(level), level..., len(inputs), inputs...]`.
pub fn run_args(level: Span<felt252>, inputs: Span<felt252>) -> Array<felt252> {
    let mut args: Array<felt252> = array![level.len().into()];
    args.append_span(level);
    args.append(inputs.len().into());
    args.append_span(inputs);
    args
}

/// The translated fact the Satellite registers: Integrity's `calculate_bootloaded_fact_hash(
/// sharp_bootloader, atlantic_bootloader, out)` = `poseidon(sharp_bootloader, poseidon(1,
/// len(out) + 2, atlantic_bootloader, out...))`.
pub fn integrity_fact(
    sharp_bootloader_hash: felt252, atlantic_bootloader_hash: felt252, out: Span<felt252>,
) -> felt252 {
    let mut felts: Array<felt252> = array![1, (out.len() + 2).into(), atlantic_bootloader_hash];
    felts.append_span(out);
    poseidon_hash_span([sharp_bootloader_hash, poseidon_hash_span(felts.span())].span())
}

/// The SHARP fact, `keccak(atlantic_bootloader || keccak(out))` over 32-byte big-endian words, as
/// the big-endian integer the Satellite stores.
pub fn sharp_fact(atlantic_bootloader_hash: felt252, out: Span<felt252>) -> u256 {
    let mut words: Array<u256> = array![];
    for felt in out {
        words.append((*felt).into());
    }
    let output_hash = big_endian(keccak_u256s_be_inputs(words.span()));
    big_endian(keccak_u256s_be_inputs([atlantic_bootloader_hash.into(), output_hash].span()))
}

/// `keccak_u256s_be_inputs` returns the digest's bytes in little-endian order.
fn big_endian(digest: u256) -> u256 {
    u256 { low: u128_byte_reverse(digest.high), high: u128_byte_reverse(digest.low) }
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
    use slingfall_level::level::fixtures::{one_block_felts, pile10_felts};
    use slingfall_level::outputs::{Outputs, OutputsTrait};
    use slingfall_testing::opaque;
    use crate::simulate::MARKER;
    use crate::submit::fixtures::{
        ATLANTIC_BOOTLOADER_HASH, ATTESTATION_KEY, E3A_CHILD_PROGRAM_HASH, GOLDEN_ATTESTATION_HASH,
        GOLDEN_MESSAGE_HASH, GOLDEN_R, GOLDEN_S, MESSAGE_FROM as FROM, ONE_BLOCK_INTEGRITY_FACT,
        ONE_BLOCK_SHARP_FACT, PILE10_INTEGRITY_FACT, PILE10_OUTPUT_LEN, PILE10_SHARP_FACT,
        SHARP_BOOTLOADER_HASH, golden_claim, one_block_miss_inputs, one_block_miss_outputs,
        reference_inputs, reference_outputs,
    };
    use super::{
        Snip36Verifier, StubVerifier, Verifier, atlantic_output, attestation_hash, integrity_fact,
        message_hash, run_args, sharp_fact,
    };

    /// `atlantic_output` of a level and inputs.
    fn output(
        child: felt252, claim: Outputs, level: Span<felt252>, inputs: Span<felt252>,
    ) -> Array<felt252> {
        atlantic_output(child, claim, run_args(level, inputs).span())
    }

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

    /// E3a vectors: the output and both facts of the two proven runs.
    #[test]
    fn test_atlantic_facts_are_the_e3a_facts() {
        // (level, inputs, outputs, integrity fact, sharp fact).
        let cases: Array<(Array<felt252>, Array<felt252>, Array<felt252>, felt252, u256)> = array![
            (
                pile10_felts(),
                reference_inputs(),
                reference_outputs(),
                PILE10_INTEGRITY_FACT,
                PILE10_SHARP_FACT,
            ),
            (
                one_block_felts(),
                one_block_miss_inputs(),
                one_block_miss_outputs(),
                ONE_BLOCK_INTEGRITY_FACT,
                ONE_BLOCK_SHARP_FACT,
            ),
        ];
        for (level, inputs, outputs, integrity, sharp) in cases {
            let claim = OutputsTrait::from_felts(outputs.span());
            let out = output(E3A_CHILD_PROGRAM_HASH, claim, level.span(), inputs.span());
            assert_eq!(out.len(), 20 + level.len() + inputs.len());
            let fact = integrity_fact(SHARP_BOOTLOADER_HASH, ATLANTIC_BOOTLOADER_HASH, out.span());
            assert_eq!(fact, integrity);
            assert_eq!(sharp_fact(ATLANTIC_BOOTLOADER_HASH, out.span()), sharp);
        }
        let claim = OutputsTrait::from_felts(reference_outputs().span());
        let out = output(
            E3A_CHILD_PROGRAM_HASH, claim, pile10_felts().span(), reference_inputs().span(),
        );
        assert_eq!(out.len(), PILE10_OUTPUT_LEN);
    }

    /// Every constant and every felt of the run moves the facts.
    #[test]
    fn test_atlantic_facts_commit_to_everything() {
        let claim = OutputsTrait::from_felts(reference_outputs().span());
        let level = pile10_felts();
        let inputs = reference_inputs();
        let out = output(E3A_CHILD_PROGRAM_HASH, claim, level.span(), inputs.span());
        let other_child = output(E3A_CHILD_PROGRAM_HASH + 1, claim, level.span(), inputs.span());
        let other_inputs = output(
            E3A_CHILD_PROGRAM_HASH, claim, level.span(), one_block_miss_inputs().span(),
        );
        let other_claim = output(
            E3A_CHILD_PROGRAM_HASH, Outputs { score: 1, ..claim }, level.span(), inputs.span(),
        );
        for other in array![other_child, other_inputs, other_claim] {
            let fact = integrity_fact(
                SHARP_BOOTLOADER_HASH, ATLANTIC_BOOTLOADER_HASH, other.span(),
            );
            assert_ne!(fact, PILE10_INTEGRITY_FACT);
            assert_ne!(sharp_fact(ATLANTIC_BOOTLOADER_HASH, other.span()), PILE10_SHARP_FACT);
        }
        let fact = integrity_fact(SHARP_BOOTLOADER_HASH + 1, ATLANTIC_BOOTLOADER_HASH, out.span());
        assert_ne!(fact, PILE10_INTEGRITY_FACT);
        let fact = integrity_fact(SHARP_BOOTLOADER_HASH, ATLANTIC_BOOTLOADER_HASH + 1, out.span());
        assert_ne!(fact, PILE10_INTEGRITY_FACT);
        assert_ne!(sharp_fact(ATLANTIC_BOOTLOADER_HASH + 1, out.span()), PILE10_SHARP_FACT);
    }

    #[test]
    fn steps_verifier_satellite_integrity_fact__pile10() {
        let claim = opaque(OutputsTrait::from_felts(reference_outputs().span()));
        let level = opaque(pile10_felts());
        let inputs = opaque(reference_inputs());
        let out = output(E3A_CHILD_PROGRAM_HASH, claim, level.span(), inputs.span());
        opaque(integrity_fact(SHARP_BOOTLOADER_HASH, ATLANTIC_BOOTLOADER_HASH, out.span()));
    }

    #[test]
    fn steps_verifier_satellite_sharp_fact__pile10() {
        let claim = opaque(OutputsTrait::from_felts(reference_outputs().span()));
        let level = opaque(pile10_felts());
        let inputs = opaque(reference_inputs());
        let out = output(E3A_CHILD_PROGRAM_HASH, claim, level.span(), inputs.span());
        opaque(sharp_fact(ATLANTIC_BOOTLOADER_HASH, out.span()));
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
