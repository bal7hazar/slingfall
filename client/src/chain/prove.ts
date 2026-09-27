// Client of the prover service (`services/prove/prove_service.py`): `POST /prove` the level and
// the inputs felts, then `GET /status/<id>` until the run's fact is on the Satellite
// (`settleable`), when `submit_settled(outputs, inputs)` can settle the attempt (docs/DESIGN.md D9,
// two tiers). The service holds the Atlantic key; the browser never does. Two paths settle: the
// translated Poseidon fact (`settleablePoseidon`, cheap) and the bridged keccak fact only
// (`settleableKeccak`); the contract prefers the first on its own, the client only labels it.
import { feltHex } from './slingfall.ts';

export interface ProofJob {
  id: string;
  /** `queued` → `running` → `submitted` (or `failed`; `built` without submission). */
  state: string;
  levelHash: string;
  inputs: string[];
  /** The run's outputs (once built): must equal the client's for the same player. */
  outputs: string[] | null;
  /** Atlantic's status (`RECEIVED`, `IN_PROGRESS`, `DONE`, `FAILED`) once submitted. */
  atlantic: string | null;
  /** The fact is on the Satellite (either path) *and* the contract's program config matches
   * (M6): `submit_settled` will pass. */
  settleable: boolean;
  /** The translated (Poseidon) fact is on the Satellite: the cheap `submit_settled`. */
  settleablePoseidon: boolean;
  /** The bridged keccak fact is on the Satellite: the dearer `submit_settled`. */
  settleableKeccak: boolean;
  /** The service's state of the translation (`grace`, `translate`, `translated`, `off`, ...). */
  translation: string | null;
  /** This job's `child_program_hash`, once built (M6). */
  programHash: string | null;
  /** The contract's currently pinned `child_program_hash` (M6); `null`: not read (no contract
   * configured on the service, or the RPC read failed). */
  contractProgramHash: string | null;
  /** `programHash === contractProgramHash`; `null` when either side is unknown. */
  programMatch: boolean | null;
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

function decodeJob(body: Record<string, unknown>): ProofJob {
  const atl = body.atlantic_status as { status?: string } | undefined;
  return {
    id: String(body.id),
    state: String(body.state),
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
    programMatch: typeof body.program_match === 'boolean' ? body.program_match : null,
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
  };
}

/** Asks the service to prove `inputs` on the level (idempotent: the same attempt, the same job). */
export function requestProof(url: string, levelHash: string, inputs: readonly string[], fetchFn: Fetch = fetch): Promise<ProofJob> {
  return call(fetchFn, `${url.replace(/\/$/, '')}/prove`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ level: feltHex(levelHash), inputs: inputs.map(feltHex) }),
  });
}

export function proofStatus(url: string, id: string, fetchFn: Fetch = fetch): Promise<ProofJob> {
  return call(fetchFn, `${url.replace(/\/$/, '')}/status/${encodeURIComponent(id)}`);
}

/** Human status of a job (the panel's line). */
export function describeJob(job: ProofJob): string {
  if (job.error) return `proof failed: ${job.error}`;
  if (job.settleablePoseidon) return 'proof on Starknet (Satellite): ready to settle (cheap)';
  if (job.settleable) {
    const soon = job.translation === 'grace' || job.translation === 'translate' || job.translation === 'backoff';
    return `proof on Starknet (Satellite): ready to settle${soon ? ' (a cheaper path follows in minutes)' : ''}`;
  }
  // M6: the fact may already be on the Satellite, but the contract was re-pinned to another
  // program since this proof was made: settling it would revert with 'submit: proof'.
  if (job.programMatch === false) {
    return `proof made for program ${job.programHash}, but the contract now accepts ${job.contractProgramHash}: it cannot be settled`;
  }
  if (job.state === 'submitted') return `proving on Atlantic (${job.atlantic ?? 'submitted'}; about 1.5 h)`;
  return `preparing the proof (${job.state})`;
}

/** The settle button's label: "Settle (cheap)" on the Poseidon path, else "Settle". */
export function settleLabel(job: ProofJob): string {
  return job.settleablePoseidon ? 'Settle (cheap)' : 'Settle';
}

/**
 * Polls `/status/<id>` every `intervalMs` until the job is settleable (returned) or failed
 * (thrown); `onJob` sees every answer. `sleep` is injectable for the tests.
 */
export async function waitSettleable(
  url: string,
  id: string,
  onJob: (job: ProofJob) => void,
  { intervalMs = 60_000, fetchFn = fetch, sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms)) }: {
    intervalMs?: number;
    fetchFn?: Fetch;
    sleep?: (ms: number) => Promise<void>;
  } = {},
): Promise<ProofJob> {
  for (;;) {
    const job = await proofStatus(url, id, fetchFn);
    onJob(job);
    if (job.settleable) return job;
    if (job.state === 'failed' || job.atlantic === 'FAILED') throw new Error(describeJob(job));
    await sleep(intervalMs);
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
