// Client of the attestation service (`services/attest/attest.py`, `POST /attest`, contract v2):
// sends the level and the inputs (the service re-executes the replay, `--execute`) with the
// outputs the page computed, or the outputs and a proof (`--verify-cmd`); checks the answer signs
// `verifier::attestation_message(chain_id, contract, program_hash, epoch, expiry, outputs)` for
// this contract and these outputs, and returns the `[program_hash, expiry, r, s]` evidence of
// `submit`.
import { hash } from 'starknet';
import { N_OUTPUTS, feltHex } from './slingfall.ts';

/** `verifier::ATTEST_DOMAIN`: the short string 'SLINGFALL_ATTEST'. */
export const ATTEST_DOMAIN = feltHex(`0x${[...'SLINGFALL_ATTEST'].map((c) => c.charCodeAt(0).toString(16)).join('')}`);

/** A proof on the service's machine (`proof_path`) or sent inline (base64). */
export type ProofRef = { path: string } | { base64: string };

/** What the service is asked: the replay to re-execute (level + inputs), and / or a proof. */
export interface AttestRequest {
  outputs: readonly string[];
  level?: string;
  inputs?: readonly string[];
  proof?: ProofRef;
}

/** The fields of the signed message besides the outputs. */
export interface AttestContext {
  chainId: string;
  contract: string;
  programHash: string;
  epoch: number;
  expiry: number;
}

export interface Attestation extends AttestContext {
  message: string;
  /** `[program_hash, expiry, r, s]`: the `evidence` of `submit`. */
  evidence: [string, string, string, string];
  publicKey: string;
  /** `false` when the service runs `--no-verify` (devnet without a replay). */
  verified: boolean;
  /** `execute`, `verify` or `none`. */
  mode: string;
}

/** `verifier::attestation_message`. */
export function attestationMessage(ctx: AttestContext, outputs: readonly string[]): string {
  const felts = [ATTEST_DOMAIN, ctx.chainId, ctx.contract, ctx.programHash, ctx.epoch, ctx.expiry, ...outputs].map((v) => feltHex(v));
  return feltHex(hash.computePoseidonHashOnElements(felts));
}

export function attestBody(request: AttestRequest): string {
  if (request.outputs.length !== N_OUTPUTS) throw new Error(`outputs: ${request.outputs.length} felts, expected ${N_OUTPUTS}`);
  const body: Record<string, unknown> = { outputs: request.outputs.map(feltHex) };
  if (request.level !== undefined) body.level = feltHex(request.level);
  if (request.inputs !== undefined) body.inputs = request.inputs.map(feltHex);
  if (request.proof && 'path' in request.proof) body.proof_path = request.proof.path;
  if (request.proof && 'base64' in request.proof) body.proof = request.proof.base64;
  return JSON.stringify(body);
}

/** Asks the service at `url` to attest the attempt for `contract`; throws with the service's message
 * on refusal, or when the answer does not sign this contract and these outputs. */
export async function requestAttestation(url: string, contract: string, request: AttestRequest, fetchFn: typeof fetch = fetch): Promise<Attestation> {
  const response = await fetchFn(`${url.replace(/\/$/, '')}/attest`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: attestBody(request),
  });
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) throw new Error(`attest: ${response.status} ${String(body.error ?? response.statusText)}`);
  const evidence = body.evidence;
  if (!Array.isArray(evidence) || evidence.length !== 4) throw new Error('attest: no [program_hash, expiry, r, s] evidence in the answer');
  const ctx: AttestContext = {
    chainId: feltHex(String(body.chain_id)),
    contract: feltHex(String(body.contract)),
    programHash: feltHex(String(evidence[0])),
    epoch: Number(body.epoch),
    expiry: Number(BigInt(String(evidence[1]))),
  };
  if (BigInt(ctx.contract) !== BigInt(contract)) throw new Error(`attest: the service signs for contract ${ctx.contract}, not ${feltHex(contract)}`);
  if (Array.isArray(body.outputs) && body.outputs.some((v, i) => BigInt(String(v)) !== BigInt(request.outputs[i]))) {
    throw new Error("attest: the service's replay gives other outputs than this page's");
  }
  const expected = attestationMessage(ctx, request.outputs);
  if (BigInt(String(body.message)) !== BigInt(expected)) {
    throw new Error(`attest: the service signed ${String(body.message)}, not the attestation message ${expected}`);
  }
  return {
    ...ctx,
    message: expected,
    evidence: [ctx.programHash, feltHex(ctx.expiry), feltHex(String(evidence[2])), feltHex(String(evidence[3]))],
    publicKey: feltHex(String(body.public_key)),
    verified: body.verified === true,
    mode: String(body.mode ?? ''),
  };
}
