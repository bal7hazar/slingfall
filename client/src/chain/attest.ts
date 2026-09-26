// Client of the attestation service (`services/attest/attest.py`, `POST /attest`): sends the
// outputs (and the proof, when the local prover made one), checks the answer signs
// `poseidon_hash_span(outputs)` (the contract's `verifier::attestation_hash`) and returns the
// `[r, s]` evidence of `submit`.
import { hash } from 'starknet';
import { N_OUTPUTS, feltHex } from './slingfall.ts';

/** A proof on the service's machine (`proof_path`) or sent inline (base64). */
export type ProofRef = { path: string } | { base64: string };

export interface Attestation {
  attestationHash: string;
  /** `[r, s]`: the `evidence` of `submit`. */
  signature: [string, string];
  publicKey: string;
  /** `false` when the service runs `--no-verify` (devnet without a prover). */
  verified: boolean;
}

/** `verifier::attestation_hash`: Poseidon over the outputs felts. */
export function attestationHash(outputs: readonly string[]): string {
  return feltHex(hash.computePoseidonHashOnElements(outputs.map(feltHex)));
}

export function attestBody(outputs: readonly string[], proof?: ProofRef): string {
  if (outputs.length !== N_OUTPUTS) throw new Error(`outputs: ${outputs.length} felts, expected ${N_OUTPUTS}`);
  const body: Record<string, unknown> = { outputs: outputs.map(feltHex) };
  if (proof && 'path' in proof) body.proof_path = proof.path;
  if (proof && 'base64' in proof) body.proof = proof.base64;
  return JSON.stringify(body);
}

/** Asks the service at `url` to attest `outputs`; throws with the service's message on refusal. */
export async function requestAttestation(
  url: string,
  outputs: readonly string[],
  proof?: ProofRef,
  fetchFn: typeof fetch = fetch,
): Promise<Attestation> {
  const response = await fetchFn(`${url.replace(/\/$/, '')}/attest`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: attestBody(outputs, proof),
  });
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) throw new Error(`attest: ${response.status} ${String(body.error ?? response.statusText)}`);
  const signature = body.signature;
  if (!Array.isArray(signature) || signature.length !== 2) throw new Error('attest: no [r, s] in the answer');
  const expected = attestationHash(outputs);
  if (BigInt(String(body.attestation_hash)) !== BigInt(expected)) {
    throw new Error(`attest: the service signed ${String(body.attestation_hash)}, not poseidon(outputs) ${expected}`);
  }
  return {
    attestationHash: expected,
    signature: [feltHex(String(signature[0])), feltHex(String(signature[1]))],
    publicKey: feltHex(String(body.public_key)),
    verified: body.verified === true,
  };
}
