//! `Verifier` interface over the evidence of a claimed `Outputs` (`docs/DESIGN.md` D9), with four
//! implementations: `Snip36Verifier` (the SNIP-36 `proof_facts` of the transaction),
//! `AttestationVerifier` (contract v2: an attestation bound to the chain, the contract, the
//! program, the key epoch and an expiry; `docs/contract-v2.md`), `StubVerifier` (the v1 attestation
//! over the outputs alone, kept for `slingfall_sizes`' fixtures) and `SatelliteVerifier` (the
//! Atlantic fact of the run, registered on Herodotus's Satellite: `docs/proving.md` "Atlantic +
//! Integrity").

use core::ecdsa::check_ecdsa_signature;
use core::integer::u128_byte_reverse;
use core::keccak::keccak_u256s_be_inputs;
use core::num::traits::Zero;
use core::poseidon::poseidon_hash_span;
use slingfall_level::outputs::{Outputs, OutputsTrait};
use starknet::ContractAddress;
use crate::simulate::MARKER;

/// The layout of `tx_info.proof_facts` (sequencer `main-v0.14.4`: `virtual_os_output.cairo`,
/// `execution_constraints.cairo`; programme research SN1 §4): the `ProofHeader` `[proof_version,
/// proof_variant, program_hash]`, the `VirtualOsOutputHeader` `[output_version, base_block_number,
/// base_block_hash, starknet_os_config_hash, n_l2_to_l1_messages]`, then one hash per message.
pub mod facts {
    pub const PROOF_VERSION: usize = 0;
    pub const PROOF_VARIANT: usize = 1;
    pub const PROGRAM_HASH: usize = 2;
    pub const OUTPUT_VERSION: usize = 3;
    pub const BASE_BLOCK_NUMBER: usize = 4;
    pub const BASE_BLOCK_HASH: usize = 5;
    pub const N_MESSAGES: usize = 7;
    /// The first message hash (the length of the two headers).
    pub const MESSAGES: usize = 8;
    /// The proof versions the OS accepts (0.14.4 accepts both while V2 rolls out).
    pub const PROOF1: felt252 = 'PROOF1';
    pub const PROOF2: felt252 = 'PROOF2';
    pub const VIRTUAL_SNOS: felt252 = 'VIRTUAL_SNOS';
    pub const VIRTUAL_SNOS0: felt252 = 'VIRTUAL_SNOS0';
}

/// Position of the virtual-OS program hash in `tx_info.proof_facts`.
pub const PROGRAM_HASH_INDEX: usize = facts::PROGRAM_HASH;
/// The OS of the real transaction requires `base_block_number <= block_number - 10`
/// (`STORED_BLOCK_HASH_BUFFER`); the contract checks it again.
pub const BLOCK_HASH_BUFFER: u64 = 10;

/// What the contract reads of well-formed proof facts.
#[derive(Copy, Drop, PartialEq, Debug)]
pub struct ProofFacts {
    pub program_hash: felt252,
    pub base_block_number: u64,
    pub base_block_hash: felt252,
    /// `facts[8 .. 8 + n)`: the message hashes, and nothing after them.
    pub messages: Span<felt252>,
}

/// The facts of a SNIP-36 proof, or `None` unless they are one: a known proof version, the
/// `VIRTUAL_SNOS` variant and output version, `n_l2_to_l1_messages` messages present (the OS only
/// checks a minimum length, so felts past them are ignored), a `u64` base block number.
pub fn parse_facts(facts: Span<felt252>) -> Option<ProofFacts> {
    if facts.len() < facts::MESSAGES {
        return None;
    }
    let version = *facts[facts::PROOF_VERSION];
    if (version != facts::PROOF1 && version != facts::PROOF2)
        || *facts[facts::PROOF_VARIANT] != facts::VIRTUAL_SNOS
        || *facts[facts::OUTPUT_VERSION] != facts::VIRTUAL_SNOS0 {
        return None;
    }
    let n: u32 = (*facts[facts::N_MESSAGES]).try_into()?;
    if n > facts.len() - facts::MESSAGES {
        return None;
    }
    Some(
        ProofFacts {
            program_hash: *facts[facts::PROGRAM_HASH],
            base_block_number: (*facts[facts::BASE_BLOCK_NUMBER]).try_into()?,
            base_block_hash: *facts[facts::BASE_BLOCK_HASH],
            messages: facts.slice(facts::MESSAGES, n),
        },
    )
}

/// `hash` is one of `messages`.
pub fn has_message(messages: Span<felt252>, hash: felt252) -> bool {
    for message in messages {
        if *message == hash {
            return true;
        }
    }
    false
}

/// The verifier `submit` (the provisional tier) runs, switched by the admin; `submit_settled` is
/// always available beside it.
#[derive(Copy, Drop, Serde, PartialEq, Debug, starknet::Store)]
pub enum VerifierKind {
    /// `Snip36Verifier`: in-protocol proof facts (the target, `docs/DESIGN.md` D9).
    #[default]
    Snip36,
    /// `AttestationVerifier` in `Slingfall` (`StubVerifier` in `slingfall_sizes`): an attestation
    /// signed by the admin's key. The v2 constructor's choice.
    Stub,
    /// `Slingfall` v2: `submit` refuses everything (the provisional tier is closed, e.g. after a
    /// key compromise); the settled tier is `submit_settled`.
    Satellite,
}

/// `pedersen(0, 0)`: the second felt of the Atlantic bootloader's output (its configuration, the
/// same in every query; `docs/proving.md` "Fact formula" step 3).
pub const PEDERSEN_0_0: felt252 = 0x49ee3eba8c1600700ee1b87eb599f16716b0b1022947733551fde4050ca6804;
/// `is_mocked` of the Satellite's reads: mocked facts are never accepted.
pub const NOT_MOCKED: bool = false;

/// The constants of the fact chain, admin-settable (`set_satellite_config`); any zero field
/// rejects everything. `c1main`'s program hash is not one of them (contract v2): it comes with each
/// `submit_settled` and must be in the contract's program set (`pin_program`).
#[derive(Copy, Drop, Serde, PartialEq, Debug, starknet::Store)]
pub struct SatelliteConfig {
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
    /// The bootloader's (Pedersen) hash of `c1main` the run was proven with; `0` rejects
    /// everything. Whether it is accepted (the program set) is the contract's check.
    pub child_program_hash: felt252,
}

impl SatelliteVerifierImpl of Verifier<SatelliteVerifier> {
    fn check(ref self: SatelliteVerifier, claim: Outputs, evidence: Span<felt252>) -> bool {
        let config = self.config;
        if self.child_program_hash == 0
            || config.atlantic_bootloader_hash == 0
            || config.sharp_bootloader_hash == 0
            || config.satellite_address.is_zero() {
            return false;
        }
        let out = atlantic_output(self.child_program_hash, claim, evidence);
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

/// SNIP-36: the transaction's `proof_facts` must be well formed (`parse_facts`), name the expected
/// virtual-OS program and hold, among their messages, the hash of the message `simulate` sent
/// (`from` = this contract, `to` = `MARKER`, payload = the claimed outputs). `evidence` is not
/// read: the facts come from the protocol.
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
        let Some(facts) = parse_facts(self.facts) else {
            return false;
        };
        if self.virtual_os_hash == 0 || facts.program_hash != self.virtual_os_hash {
            return false;
        }
        has_message(facts.messages, message_hash(self.from, MARKER, claim.to_felts().span()))
    }
}

/// The v1 attestation: `evidence = [r, s]`, a Stark-curve ECDSA signature by `public_key` of
/// `attestation_hash(outputs felts)`, with no domain. Replaced in `Slingfall` by
/// `AttestationVerifier`; kept for `slingfall_sizes`' fixtures.
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

/// Domain of the v2 attestations (the first felt of `attestation_message`).
pub const ATTEST_DOMAIN: felt252 = 'SLINGFALL_ATTEST';

/// Contract v2's attestation: `evidence = [program_hash, expiry, r, s]`, a Stark-curve ECDSA
/// signature by `public_key` of `attestation_message(chain_id, contract, program_hash, epoch,
/// expiry, outputs felts)`, valid while `now < expiry`. A signature cannot be replayed on another
/// chain or deployment, after a key rotation (the epoch) or once expired; the program hash is
/// signed as given, and whether it is accepted (the program set) is the contract's check.
#[derive(Copy, Drop)]
pub struct AttestationVerifier {
    /// The admin's attestation public key; `0` (unset) rejects everything.
    pub public_key: felt252,
    /// `tx_info.chain_id`.
    pub chain_id: felt252,
    /// This contract's address.
    pub contract: felt252,
    /// The key's epoch (bumped by every `set_attestation_key`).
    pub epoch: u64,
    /// The block timestamp.
    pub now: u64,
}

impl AttestationVerifierImpl of Verifier<AttestationVerifier> {
    fn check(ref self: AttestationVerifier, claim: Outputs, evidence: Span<felt252>) -> bool {
        if self.public_key == 0 || evidence.len() != 4 {
            return false;
        }
        let expiry: Option<u64> = (*evidence[1]).try_into();
        let Some(expiry) = expiry else {
            return false;
        };
        if self.now >= expiry {
            return false;
        }
        let hash = attestation_message(
            self.chain_id, self.contract, *evidence[0], self.epoch, expiry, claim.to_felts().span(),
        );
        check_ecdsa_signature(hash, self.public_key, *evidence[2], *evidence[3])
    }
}

/// What a v2 attestation signs: `poseidon_hash_span([ATTEST_DOMAIN, chain_id, contract,
/// program_hash, epoch, expiry, outputs...])`.
pub fn attestation_message(
    chain_id: felt252,
    contract: felt252,
    program_hash: felt252,
    epoch: u64,
    expiry: u64,
    outputs: Span<felt252>,
) -> felt252 {
    let mut felts: Array<felt252> = array![
        ATTEST_DOMAIN, chain_id, contract, program_hash, epoch.into(), expiry.into(),
    ];
    felts.append_span(outputs);
    poseidon_hash_span(felts.span())
}

/// Hash of an L2 to L1 message as the virtual OS writes it among the proof facts:
/// `poseidon_hash_span([from, to, payload.len(), ...payload])` (`MessageToL1Header` then the
/// payload, `os_utils__virtual.cairo`; SN1 §4). The one place of this rule.
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
        ATLANTIC_BOOTLOADER_HASH, ATTESTATION_KEY, ATTEST_CHAIN_ID, ATTEST_EPOCH, ATTEST_EXPIRY,
        BASE_BLOCK, E3A_CHILD_PROGRAM_HASH, GOLDEN_ATTESTATION_HASH, GOLDEN_ATTEST_MESSAGE,
        GOLDEN_ATTEST_R, GOLDEN_ATTEST_S, GOLDEN_MESSAGE_HASH, GOLDEN_R, GOLDEN_S,
        MESSAGE_FROM as FROM, ONE_BLOCK_INTEGRITY_FACT, ONE_BLOCK_SHARP_FACT, PILE10_INTEGRITY_FACT,
        PILE10_OUTPUT_LEN, PILE10_SHARP_FACT, SHARP_BOOTLOADER_HASH, VIRTUAL_OS_HASH, golden_claim,
        one_block_miss_inputs, one_block_miss_outputs, proof_facts, reference_inputs,
        reference_outputs,
    };
    use super::{
        AttestationVerifier, Snip36Verifier, StubVerifier, Verifier, atlantic_output,
        attestation_hash, attestation_message, facts, integrity_fact, message_hash, parse_facts,
        run_args, sharp_fact,
    };

    /// The verifier of the v2 golden vector at time `now`.
    fn attestation(now: u64) -> AttestationVerifier {
        AttestationVerifier {
            public_key: ATTESTATION_KEY,
            chain_id: ATTEST_CHAIN_ID,
            contract: FROM,
            epoch: ATTEST_EPOCH,
            now,
        }
    }

    fn golden_evidence() -> Array<felt252> {
        array![E3A_CHILD_PROGRAM_HASH, ATTEST_EXPIRY.into(), GOLDEN_ATTEST_R, GOLDEN_ATTEST_S]
    }

    /// `atlantic_output` of a level and inputs.
    fn output(
        child: felt252, claim: Outputs, level: Span<felt252>, inputs: Span<felt252>,
    ) -> Array<felt252> {
        atlantic_output(child, claim, run_args(level, inputs).span())
    }

    fn snip36(facts: Span<felt252>) -> Snip36Verifier {
        Snip36Verifier { virtual_os_hash: VIRTUAL_OS_HASH, from: FROM, facts }
    }

    /// Well-formed facts of `VIRTUAL_OS_HASH` with these messages.
    fn facts_of(messages: Array<felt252>) -> Array<felt252> {
        proof_facts(VIRTUAL_OS_HASH, BASE_BLOCK, messages.span())
    }

    /// `facts` with felt `index` replaced by `value`.
    fn with(facts: Array<felt252>, index: usize, value: felt252) -> Array<felt252> {
        let mut result = array![];
        let mut i = 0;
        for fact in facts {
            result.append(if i == index {
                value
            } else {
                fact
            });
            i += 1;
        }
        result
    }

    /// `facts_of([GOLDEN_MESSAGE_HASH])` with felt `index` replaced by `value`.
    fn golden_facts_with(index: usize, value: felt252) -> Array<felt252> {
        with(facts_of(array![GOLDEN_MESSAGE_HASH]), index, value)
    }

    #[test]
    fn test_parse_facts_reads_the_protocol_layout() {
        let facts = facts_of(array![0x1, GOLDEN_MESSAGE_HASH]);
        let parsed = parse_facts(facts.span()).unwrap();
        assert_eq!(parsed.program_hash, VIRTUAL_OS_HASH);
        assert_eq!(parsed.base_block_number, BASE_BLOCK);
        assert_eq!(parsed.base_block_hash, 0xb10c);
        assert_eq!(parsed.messages, array![0x1, GOLDEN_MESSAGE_HASH].span());
        // PROOF1 is accepted too; felts past the `n` messages are not messages.
        let proof1 = golden_facts_with(facts::PROOF_VERSION, 'PROOF1');
        assert!(parse_facts(proof1.span()).is_some());
        let mut trailing = facts_of(array![0x1]);
        trailing.append(GOLDEN_MESSAGE_HASH);
        assert_eq!(parse_facts(trailing.span()).unwrap().messages, array![0x1].span());
        assert!(parse_facts(facts_of(array![]).span()).unwrap().messages.is_empty());
    }

    #[test]
    fn test_parse_facts_rejects() {
        // (index, value): version, variant, output version, more messages than felts, a count
        // that is not a `u32`, a base block that is not a `u64`.
        let cases: Array<(usize, felt252)> = array![
            (facts::PROOF_VERSION, 'PROOF3'), (facts::PROOF_VARIANT, 'SNOS'),
            (facts::OUTPUT_VERSION, 'VIRTUAL_SNOS1'), (facts::N_MESSAGES, 2),
            (facts::N_MESSAGES, 0x100000000), (facts::BASE_BLOCK_NUMBER, 0x10000000000000000),
        ];
        for (index, value) in cases {
            assert!(parse_facts(golden_facts_with(index, value).span()).is_none());
        }
        // Shorter than the headers.
        let facts = facts_of(array![]);
        assert!(parse_facts(facts.span().slice(0, facts::MESSAGES - 1)).is_none());
        assert!(parse_facts(array![].span()).is_none());
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
            facts_of(array![GOLDEN_MESSAGE_HASH]),
            facts_of(array![0x1, 0x2, GOLDEN_MESSAGE_HASH, 0x3]),
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
        let mut after_n = facts_of(array![0x1]);
        after_n.append(GOLDEN_MESSAGE_HASH);
        // (facts, claim): no facts, the v2 layout (program at 0), wrong program, message missing,
        // the message past the `n` messages, the message only in a header field, another claim.
        let cases: Array<(Array<felt252>, Outputs)> = array![
            (array![], golden_claim()),
            (array![VIRTUAL_OS_HASH, GOLDEN_MESSAGE_HASH], golden_claim()),
            (
                proof_facts(VIRTUAL_OS_HASH + 1, BASE_BLOCK, array![GOLDEN_MESSAGE_HASH].span()),
                golden_claim(),
            ),
            (facts_of(array![0x1]), golden_claim()), (after_n, golden_claim()),
            (
                with(facts_of(array![0x1]), facts::BASE_BLOCK_HASH, GOLDEN_MESSAGE_HASH),
                golden_claim(),
            ),
            (facts_of(array![GOLDEN_MESSAGE_HASH]), other),
        ];
        for (facts, claim) in cases {
            let mut verifier = snip36(facts.span());
            assert!(!verifier.check(claim, array![].span()));
        }
        // An unset program hash rejects even matching facts.
        let facts = proof_facts(0, BASE_BLOCK, array![GOLDEN_MESSAGE_HASH].span());
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
    fn test_attestation_message_is_golden() {
        let outputs = golden_claim().to_felts();
        let message = attestation_message(
            ATTEST_CHAIN_ID,
            FROM,
            E3A_CHILD_PROGRAM_HASH,
            ATTEST_EPOCH,
            ATTEST_EXPIRY,
            outputs.span(),
        );
        assert_eq!(message, GOLDEN_ATTEST_MESSAGE);
        // Every field is committed to (the domain separates it from the v1 hash).
        assert_ne!(message, attestation_hash(outputs.span()));
        let others = array![
            attestation_message(
                'SN_MAIN',
                FROM,
                E3A_CHILD_PROGRAM_HASH,
                ATTEST_EPOCH,
                ATTEST_EXPIRY,
                outputs.span(),
            ),
            attestation_message(
                ATTEST_CHAIN_ID,
                FROM + 1,
                E3A_CHILD_PROGRAM_HASH,
                ATTEST_EPOCH,
                ATTEST_EXPIRY,
                outputs.span(),
            ),
            attestation_message(
                ATTEST_CHAIN_ID,
                FROM,
                E3A_CHILD_PROGRAM_HASH + 1,
                ATTEST_EPOCH,
                ATTEST_EXPIRY,
                outputs.span(),
            ),
            attestation_message(
                ATTEST_CHAIN_ID, FROM, E3A_CHILD_PROGRAM_HASH, 2, ATTEST_EXPIRY, outputs.span(),
            ),
            attestation_message(
                ATTEST_CHAIN_ID, FROM, E3A_CHILD_PROGRAM_HASH, ATTEST_EPOCH, 1, outputs.span(),
            ),
            attestation_message(
                ATTEST_CHAIN_ID,
                FROM,
                E3A_CHILD_PROGRAM_HASH,
                ATTEST_EPOCH,
                ATTEST_EXPIRY,
                outputs.span().slice(0, 9),
            ),
        ];
        for other in others {
            assert_ne!(other, GOLDEN_ATTEST_MESSAGE);
        }
    }

    #[test]
    fn test_attestation_accepts_the_golden_signature_until_expiry() {
        let mut verifier = attestation(0);
        assert!(verifier.check(golden_claim(), golden_evidence().span()));
        let mut verifier = attestation(ATTEST_EXPIRY - 1);
        assert!(verifier.check(golden_claim(), golden_evidence().span()));
    }

    /// Replays across chain, contract, epoch, program and time, and malformed evidence.
    #[test]
    fn test_attestation_rejects() {
        let good = attestation(0);
        let mut other = golden_claim();
        other.score += 1;
        // (verifier, claim, evidence).
        let cases: Array<(AttestationVerifier, Outputs, Array<felt252>)> = array![
            (
                AttestationVerifier { chain_id: 'SN_MAIN', ..good },
                golden_claim(),
                golden_evidence(),
            ),
            (AttestationVerifier { contract: FROM + 1, ..good }, golden_claim(), golden_evidence()),
            (AttestationVerifier { epoch: 2, ..good }, golden_claim(), golden_evidence()),
            (AttestationVerifier { now: ATTEST_EXPIRY, ..good }, golden_claim(), golden_evidence()),
            (AttestationVerifier { public_key: 0, ..good }, golden_claim(), golden_evidence()),
            (
                AttestationVerifier { public_key: GOLDEN_R, ..good },
                golden_claim(),
                golden_evidence(),
            ),
            (attestation(0), other, golden_evidence()),
            (
                attestation(0),
                golden_claim(),
                array![
                    E3A_CHILD_PROGRAM_HASH + 1, ATTEST_EXPIRY.into(), GOLDEN_ATTEST_R,
                    GOLDEN_ATTEST_S,
                ],
            ),
            (
                attestation(0),
                golden_claim(),
                array![
                    E3A_CHILD_PROGRAM_HASH, ATTEST_EXPIRY.into() + 1, GOLDEN_ATTEST_R,
                    GOLDEN_ATTEST_S,
                ],
            ),
            // An expiry that is not a `u64`.
            (
                attestation(0),
                golden_claim(),
                array![
                    E3A_CHILD_PROGRAM_HASH, 0x10000000000000000, GOLDEN_ATTEST_R, GOLDEN_ATTEST_S,
                ],
            ),
            // The v1 evidence, and one felt too many.
            (attestation(0), golden_claim(), array![GOLDEN_R, GOLDEN_S]),
            (
                attestation(0),
                golden_claim(),
                array![
                    E3A_CHILD_PROGRAM_HASH, ATTEST_EXPIRY.into(), GOLDEN_ATTEST_R, GOLDEN_ATTEST_S,
                    0,
                ],
            ),
        ];
        for (verifier, claim, evidence) in cases {
            let mut verifier = verifier;
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
    fn steps_verifier_attestation_check() {
        let mut verifier = AttestationVerifier {
            public_key: opaque(ATTESTATION_KEY),
            chain_id: opaque(ATTEST_CHAIN_ID),
            contract: opaque(FROM),
            epoch: opaque(ATTEST_EPOCH),
            now: opaque(0),
        };
        let evidence = opaque(golden_evidence());
        assert!(verifier.check(opaque(golden_claim()), evidence.span()));
    }

    #[test]
    fn steps_verifier_snip36_check__3_messages() {
        let facts = opaque(facts_of(array![0x1, 0x2, GOLDEN_MESSAGE_HASH]));
        let mut verifier = snip36(facts.span());
        assert!(verifier.check(opaque(golden_claim()), array![].span()));
    }
}
