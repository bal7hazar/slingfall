// Client of the prover service (`services/prove/prove_service.py`): `POST /prove` the level and
// the inputs felts, then `GET /status/<id>` until the run's fact is on the Satellite
// (`settleable`), when `submit_settled(outputs, args, child_program_hash)` can settle the attempt
// (contract v2, two tiers), or until the service's relay has settled it for the player
// (`relayed`). The service holds the Atlantic key; the browser never does. Two paths settle: the
// translated Poseidon fact (`settleablePoseidon`, cheap) and the bridged keccak fact only
// (`settleableKeccak`); the contract prefers the first on its own, the client only labels it.
// A service with the SNIP-36 path (contract v3's proven tier, `/health`'s `proven`) takes
// `tier: 'proven'`: it proves the attempt's chain, sends the proofs and `finalize` itself, and the
// job ends `proven` (nothing for the player to send).
import { feltHex } from './slingfall.ts';

/** `POST /prove`'s tier: Atlantic + the Satellite, or SNIP-36. */
export type Tier = 'settled' | 'proven';

/** One proof of a SNIP-36 job: `pending` → `proving` → `proved` → `ripening` → `submitted` (or `failed`). */
export interface ChainProof {
  state: string;
  messages: number | null;
  transactionHash: string | null;
}

export interface ProofJob {
  id: string;
  /** Which proof the job produces (`settled` for a service without the SNIP-36 path). */
  tier: Tier;
  /** Settled tier: `queued` → `running` → `submitted` (or `failed`; `built` without submission).
   * Proven tier: `queued` → `planning` → `proving` → `submitting` → `finalizing` → `proven` (or `failed`). */
  state: string;
  /** Proven tier: the attempt is recorded as proven (`finalize` landed). */
  proven: boolean;
  /** Proven tier: one entry per proof (per virtual transaction of the chain). */
  proofs: ChainProof[];
  /** Proven tier: the `finalize` transaction (sent by the service's account for the player). */
  finalizeTransactionHash: string | null;
  levelHash: string;
  inputs: string[];
  /** The run's outputs (once built): must equal the client's for the same player. */
  outputs: string[] | null;
  /** Atlantic's status (`RECEIVED`, `IN_PROGRESS`, `DONE`, `FAILED`) once submitted. */
  atlantic: string | null;
  /** The fact is on the Satellite (either path) *and* the job's program is valid on the contract
   * now (M6): `submit_settled` will pass (unless someone settled it first). */
  settleable: boolean;
  /** The translated (Poseidon) fact is on the Satellite: the cheap `submit_settled`. */
  settleablePoseidon: boolean;
  /** The bridged keccak fact is on the Satellite: the dearer `submit_settled`. */
  settleableKeccak: boolean;
  /** The service's state of the translation (`grace`, `translate`, `translated`, `off`, ...). */
  translation: string | null;
  /** This job's `child_program_hash`, once built (M6): the `child_program_hash` of `submit_settled`. */
  programHash: string | null;
  /** The contract's `current_program()` (M6); `null`: not read (no contract configured on the
   * service, or the RPC read failed). */
  contractProgramHash: string | null;
  /** `program_valid_until(programHash)` on the contract (a former program keeps a grace period). */
  programValidUntil: bigint | null;
  /** The job's program is valid on the contract now; `null` when unknown. */
  programMatch: boolean | null;
  /** The service's relay sent `submit_settled` for the player (S10). */
  relayed: boolean;
  relayTransactionHash: string | null;
  /** `off` (no relay), `waiting`, `relayed`, `settled` (someone settled first), `gave-up`. */
  relayState: string;
  relayError: string | null;
  error: string | null;
}

/** The service's `/health` (M6: the two program hashes, so the panel can warn before Prove is even clicked). */
export interface ServiceHealth {
  result: string;
  submit: boolean;
  queued: number;
  programHash: string | null;
  contractProgramHash: string | null;
  programMatch: boolean | null;
  /** The relay account, when the service relays `submit_settled` (the player may close the page). */
  relay: string | null;
  /** The SNIP-36 path (`null`: the service has none). */
  proven: ProvenPath | null;
}

/** `/health`'s `proven`: the service proves the contract's current chain when it is its own bundle. */
export interface ProvenPath {
  /** The proven path can be asked for (`false`: the contract's chain is another release or retired). */
  available: boolean;
  /** `fake` (devnet) or `snip36`. */
  prover: string;
  chain: string | null;
  /** The service's own bundle hash (the release it proves). */
  bundleHash: string | null;
  chainMatch: boolean | null;
}

type Fetch = typeof fetch;

/** `POST /prove` refused (409): the service's own program does not match the contract's (M6). */
export class ProgramMismatchError extends Error {
  readonly programHash: string;
  readonly contractProgramHash: string;

  constructor(message: string, programHash: string, contractProgramHash: string) {
    super(message);
    this.name = 'ProgramMismatchError';
    this.programHash = programHash;
    this.contractProgramHash = contractProgramHash;
  }
}

/** `POST /prove` of the proven tier refused (409): the contract's chain is not the service's bundle, or retired. */
export class ChainMismatchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ChainMismatchError';
  }
}

const hexOrNull = (value: unknown) => (typeof value === 'string' ? feltHex(value) : null);

function decodeJob(body: Record<string, unknown>): ProofJob {
  const atl = body.atlantic_status as { status?: string } | undefined;
  const relay = (body.relay ?? {}) as { state?: unknown; error?: unknown };
  const proofs = Array.isArray(body.proofs) ? (body.proofs as Record<string, unknown>[]) : [];
  return {
    id: String(body.id),
    tier: body.tier === 'proven' ? 'proven' : 'settled',
    state: String(body.state),
    proven: body.proven === true,
    proofs: proofs.map((p) => ({
      state: String(p.state),
      messages: typeof p.messages === 'number' ? p.messages : null,
      transactionHash: hexOrNull(p.transaction_hash),
    })),
    finalizeTransactionHash: hexOrNull((body.finalize as { transaction_hash?: unknown } | undefined)?.transaction_hash),
    levelHash: feltHex(String(body.level_hash)),
    inputs: (body.inputs as string[]).map(feltHex),
    outputs: Array.isArray(body.outputs) ? (body.outputs as string[]).map(feltHex) : null,
    atlantic: atl?.status ?? null,
    settleable: body.settleable === true,
    settleablePoseidon: body.settleable_poseidon === true,
    settleableKeccak: body.settleable_keccak === true,
    translation: typeof (body.translation as { state?: unknown } | undefined)?.state === 'string' ? (body.translation as { state: string }).state : null,
    programHash: typeof body.program_hash === 'string' ? feltHex(body.program_hash) : null,
    contractProgramHash: typeof body.contract_program_hash === 'string' ? feltHex(body.contract_program_hash) : null,
    programValidUntil:
      typeof body.program_valid_until === 'number' || typeof body.program_valid_until === 'string' ? BigInt(body.program_valid_until) : null,
    programMatch: typeof body.program_match === 'boolean' ? body.program_match : null,
    relayed: body.relayed === true,
    relayTransactionHash: typeof body.relay_transaction_hash === 'string' ? feltHex(body.relay_transaction_hash) : null,
    relayState: typeof relay.state === 'string' ? relay.state : 'off',
    relayError: typeof relay.error === 'string' ? relay.error : null,
    error: typeof body.error === 'string' ? body.error : null,
  };
}

async function call(fetchFn: Fetch, url: string, init?: RequestInit): Promise<ProofJob> {
  const response = await fetchFn(url, init);
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    if (response.status === 409 && typeof body.program_hash === 'string' && typeof body.contract_program_hash === 'string') {
      throw new ProgramMismatchError(String(body.error ?? 'program mismatch'), feltHex(body.program_hash), feltHex(body.contract_program_hash));
    }
    if (response.status === 409 && typeof body.own_bundle_hash === 'string') throw new ChainMismatchError(String(body.error ?? 'chain mismatch'));
    throw new Error(`prove: ${response.status} ${String(body.error ?? response.statusText)}`);
  }
  return decodeJob(body);
}

/** `GET /health`: the service's own program hash against the contract's (M6), before any job exists. */
export async function fetchHealth(url: string, fetchFn: Fetch = fetch): Promise<ServiceHealth> {
  const response = await fetchFn(`${url.replace(/\/$/, '')}/health`);
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) throw new Error(`prove: ${response.status} ${String(body.error ?? response.statusText)}`);
  return {
    result: String(body.result ?? ''),
    submit: body.submit === true,
    queued: Number(body.queued ?? 0),
    programHash: typeof body.program_hash === 'string' ? feltHex(body.program_hash) : null,
    contractProgramHash: typeof body.contract_program_hash === 'string' ? feltHex(body.contract_program_hash) : null,
    programMatch: typeof body.program_match === 'boolean' ? body.program_match : null,
    relay: typeof body.relay === 'string' ? body.relay : null,
    proven: decodeProvenPath(body.proven),
  };
}

function decodeProvenPath(value: unknown): ProvenPath | null {
  if (typeof value !== 'object' || value === null) return null;
  const p = value as Record<string, unknown>;
  return {
    available: p.available === true,
    prover: String(p.prover ?? ''),
    chain: hexOrNull(p.chain),
    bundleHash: hexOrNull(p.own_bundle_hash),
    chainMatch: typeof p.chain_match === 'boolean' ? p.chain_match : null,
  };
}

/** Asks the service to prove `inputs` on the level at `tier` (idempotent: the same attempt, the same
 * job). The body carries `tier` only for the proven one: an older service reads the rest as before. */
export function requestProof(url: string, levelHash: string, inputs: readonly string[], fetchFn: Fetch = fetch, tier: Tier = 'settled'): Promise<ProofJob> {
  return call(fetchFn, `${url.replace(/\/$/, '')}/prove`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ level: feltHex(levelHash), inputs: inputs.map(feltHex), ...(tier === 'proven' ? { tier } : {}) }),
  });
}

export function proofStatus(url: string, id: string, fetchFn: Fetch = fetch): Promise<ProofJob> {
  return call(fetchFn, `${url.replace(/\/$/, '')}/status/${encodeURIComponent(id)}`);
}

/** Human status of a SNIP-36 job. */
function describeProven(job: ProofJob): string {
  const n = job.proofs.length;
  const count = (state: string) => job.proofs.filter((p) => p.state === state).length;
  switch (job.state) {
    case 'proven':
      return job.finalizeTransactionHash ? `proven by SNIP-36 on Starknet (finalized by the prover service in ${job.finalizeTransactionHash})` : 'proven by SNIP-36 on Starknet';
    case 'queued':
    case 'planning':
      return 'planning the SNIP-36 chain of the shot (its transactions under the proof budget)';
    case 'proving':
      return `proving by SNIP-36: ${n - count('pending') - count('proving')}/${n} transactions proven`;
    case 'submitting':
      return `sending the SNIP-36 proofs to the contract: ${count('submitted')}/${n}`;
    case 'finalizing':
      return 'recording the proven attempt (finalize)';
    default:
      return `SNIP-36 proof (${job.state})`;
  }
}

/** Human status of a job (the panel's line). */
export function describeJob(job: ProofJob): string {
  if (job.error) return `proof failed: ${job.error}`;
  if (job.tier === 'proven') return describeProven(job);
  if (job.relayed) return `settled on Starknet by the relay in ${job.relayTransactionHash}`;
  if (job.relayState === 'settled') return 'settled on Starknet';
  if (job.settleablePoseidon) return 'proof on Starknet (Satellite): ready to settle (cheap)';
  if (job.settleable) {
    const soon = job.translation === 'grace' || job.translation === 'translate' || job.translation === 'backoff';
    return `proof on Starknet (Satellite): ready to settle${soon ? ' (a cheaper path follows in minutes)' : ''}`;
  }
  // M6: the fact may already be on the Satellite, but this proof's program is past its grace
  // period (or revoked): settling it would revert with 'submit: program'.
  if (job.programMatch === false) {
    return `proof made with engine release ${job.programHash}, which the contract no longer accepts (current ${job.contractProgramHash}): it cannot be settled`;
  }
  if (job.state === 'submitted') return `proving on Atlantic (${job.atlantic ?? 'submitted'}; about 1.5 h)`;
  return `preparing the proof (${job.state})`;
}

/** The settle button's label: "Settle (cheap)" on the Poseidon path, else "Settle". */
export function settleLabel(job: ProofJob): string {
  return job.settleablePoseidon ? 'Settle (cheap)' : 'Settle';
}

/**
 * Polls `/status/<id>` every `intervalMs` until the job is settleable or relayed (returned), proven
 * (a SNIP-36 job: returned), failed (thrown), or `stop()` (null); `onJob` sees every answer. `sleep`
 * is injectable for the tests.
 */
export async function waitSettleable(
  url: string,
  id: string,
  onJob: (job: ProofJob) => void,
  { intervalMs = 60_000, fetchFn = fetch, sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms)), stop = () => false }: {
    intervalMs?: number;
    fetchFn?: Fetch;
    sleep?: (ms: number) => Promise<void>;
    stop?: () => boolean;
  } = {},
): Promise<ProofJob | null> {
  for (;;) {
    if (stop()) return null;
    const job = await proofStatus(url, id, fetchFn);
    if (stop()) return null;
    onJob(job);
    if (job.settleable || job.relayed || job.relayState === 'settled' || job.proven) return job;
    if (job.state === 'failed' || job.atlantic === 'FAILED') throw new Error(describeJob(job));
    await sleep(intervalMs);
  }
}

/**
 * After `waitSettleable` returned a settleable job that the relay will send (`relayState`
 * `waiting`): keeps polling until it is relayed or settled (returned), the relay gives up (the job
 * as it is), or `stop()` (null).
 */
export async function waitRelayed(
  url: string,
  id: string,
  onJob: (job: ProofJob) => void,
  { intervalMs = 20_000, fetchFn = fetch, sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms)), stop = () => false }: {
    intervalMs?: number;
    fetchFn?: Fetch;
    sleep?: (ms: number) => Promise<void>;
    stop?: () => boolean;
  } = {},
): Promise<ProofJob | null> {
  for (;;) {
    await sleep(intervalMs);
    if (stop()) return null;
    const job = await proofStatus(url, id, fetchFn);
    if (stop()) return null;
    onJob(job);
    if (job.relayed || job.relayState === 'settled' || job.relayState === 'gave-up' || job.relayState === 'off') return job;
  }
}

/**
 * After `waitSettleable` returned a keccak-only job: keeps polling every `intervalMs` until the
 * Poseidon fact is there (returned), `stop()` says so (null) or the service will not translate
 * (`off`, `gave-up`: the job as it is). `onJob` sees every answer.
 */
export async function waitCheap(
  url: string,
  id: string,
  onJob: (job: ProofJob) => void,
  { intervalMs = 60_000, fetchFn = fetch, sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms)), stop = () => false }: {
    intervalMs?: number;
    fetchFn?: Fetch;
    sleep?: (ms: number) => Promise<void>;
    stop?: () => boolean;
  } = {},
): Promise<ProofJob | null> {
  for (;;) {
    await sleep(intervalMs);
    if (stop()) return null;
    const job = await proofStatus(url, id, fetchFn);
    if (stop()) return null;
    onJob(job);
    if (job.settleablePoseidon || job.translation === 'off' || job.translation === 'gave-up') return job;
  }
}
