// Client of the prover service (`services/prove/prove_service.py`): `POST /prove` the level and
// the inputs felts, then `GET /status/<id>` until the run's fact is on the Satellite
// (`settleable`), when `submit_settled(outputs, inputs)` can settle the attempt (docs/DESIGN.md D9,
// two tiers). The service holds the Atlantic key; the browser never does.
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
  /** The fact is on the Satellite: `submit_settled` will pass. */
  settleable: boolean;
  error: string | null;
}

type Fetch = typeof fetch;

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
    error: typeof body.error === 'string' ? body.error : null,
  };
}

async function call(fetchFn: Fetch, url: string, init?: RequestInit): Promise<ProofJob> {
  const response = await fetchFn(url, init);
  const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) throw new Error(`prove: ${response.status} ${String(body.error ?? response.statusText)}`);
  return decodeJob(body);
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
  if (job.settleable) return 'proof on Starknet (Satellite): ready to settle';
  if (job.state === 'submitted') return `proving on Atlantic (${job.atlantic ?? 'submitted'}; about 1.5 h)`;
  return `preparing the proof (${job.state})`;
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
