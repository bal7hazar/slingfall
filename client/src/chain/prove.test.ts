import { describe, expect, it, vi } from 'vitest';
import { describeJob, proofStatus, requestProof, settleLabel, waitCheap, waitSettleable } from './prove';

const JOB = {
  id: 'bcbdf222b4585dc0821f5b88135a3026',
  state: 'submitted',
  level_hash: '0x17876831f245e0ec3d63220f2cb73c429ec93e7c888c2aa916d237cd9c114a3',
  inputs: ['0x706c61796572', '0x1', '0x0', '0x0', '0x0', '0x0'],
  outputs: ['0x1'],
  atlantic_status: { status: 'IN_PROGRESS' },
  settleable: false,
  settleable_poseidon: false,
  settleable_keccak: false,
  error: null,
};
const KECCAK = { ...JOB, atlantic_status: { status: 'DONE' }, settleable: true, settleable_keccak: true, translation: { state: 'grace' } };
const POSEIDON = { ...KECCAK, settleable_poseidon: true, translation: { state: 'translated' } };

const answers = (...bodies: [number, unknown][]) => {
  const fn = vi.fn();
  for (const [status, body] of bodies) fn.mockResolvedValueOnce(new Response(JSON.stringify(body), { status }));
  return fn as unknown as typeof fetch;
};

describe('prover service client', () => {
  it('posts the level and the inputs felts, decodes the job', async () => {
    const fetchFn = answers([202, { ...JOB, state: 'queued', atlantic_status: undefined, outputs: undefined }]);
    const job = await requestProof('http://prove/', JOB.level_hash, ['0x706c61796572', '1', '0', '0', '0', '0'], fetchFn);
    expect(job).toMatchObject({ id: JOB.id, state: 'queued', atlantic: null, outputs: null, settleable: false });
    const [url, init] = vi.mocked(fetchFn).mock.calls[0];
    expect(url).toBe('http://prove/prove');
    expect(JSON.parse(String(init?.body))).toEqual({ level: JOB.level_hash, inputs: JOB.inputs });
  });

  it('reports the service refusals', async () => {
    await expect(proofStatus('u', 'x', answers([404, { error: 'unknown job' }]))).rejects.toThrow('404 unknown job');
  });

  it('polls until the fact is on the Satellite', async () => {
    const fetchFn = answers([200, JOB], [200, JOB], [200, { ...JOB, atlantic_status: { status: 'DONE' }, settleable: true }]);
    const seen: string[] = [];
    const sleep = vi.fn(async () => {});
    const job = await waitSettleable('u', JOB.id, (j) => seen.push(describeJob(j)), { fetchFn, sleep });
    expect(job.settleable).toBe(true);
    expect(sleep).toHaveBeenCalledTimes(2);
    expect(seen[0]).toContain('proving on Atlantic (IN_PROGRESS');
    expect(seen[2]).toContain('ready to settle');
  });

  it('tells the keccak path from the Poseidon one', async () => {
    const [none, keccak, poseidon] = [JOB, KECCAK, POSEIDON].map((body) => body as Record<string, unknown>);
    const decode = async (body: Record<string, unknown>) => proofStatus('u', 'x', answers([200, body]));
    expect(await decode(none)).toMatchObject({ settleable: false, settleablePoseidon: false, settleableKeccak: false, translation: null });
    const k = await decode(keccak);
    expect(k).toMatchObject({ settleable: true, settleablePoseidon: false, settleableKeccak: true, translation: 'grace' });
    const p = await decode(poseidon);
    expect(p).toMatchObject({ settleable: true, settleablePoseidon: true, translation: 'translated' });
    expect([settleLabel(k), settleLabel(p)]).toEqual(['Settle', 'Settle (cheap)']);
    expect(describeJob(k)).toBe('proof on Starknet (Satellite): ready to settle (a cheaper path follows in minutes)');
    expect(describeJob(p)).toBe('proof on Starknet (Satellite): ready to settle (cheap)');
    expect(describeJob({ ...k, translation: 'no-account' })).toBe('proof on Starknet (Satellite): ready to settle');
  });

  it('a service without the new fields is read as before', async () => {
    const old = { ...JOB, atlantic_status: { status: 'DONE' }, settleable: true } as Record<string, unknown>;
    delete old.settleable_poseidon;
    delete old.settleable_keccak;
    expect(await proofStatus('u', 'x', answers([200, old]))).toMatchObject({ settleable: true, settleablePoseidon: false, translation: null });
  });

  it('keeps polling a keccak-only job until the fact is translated', async () => {
    const fetchFn = answers([200, KECCAK], [200, KECCAK], [200, POSEIDON]);
    const seen: string[] = [];
    const sleep = vi.fn(async () => {});
    const job = await waitCheap('u', JOB.id, (j) => seen.push(settleLabel(j)), { fetchFn, sleep });
    expect(job?.settleablePoseidon).toBe(true);
    expect(seen).toEqual(['Settle', 'Settle', 'Settle (cheap)']);
    expect(sleep).toHaveBeenCalledTimes(3);
  });

  it('stops polling when told to, or when the service will not translate', async () => {
    let calls = 0;
    const stop = () => calls++ >= 1; // one round, then the panel moved on
    expect(await waitCheap('u', JOB.id, () => {}, { fetchFn: answers([200, KECCAK]), sleep: async () => {}, stop })).toBeNull();
    const idle = { ...KECCAK, translation: { state: 'no-account' } };
    expect((await waitCheap('u', JOB.id, () => {}, { fetchFn: answers([200, idle]), sleep: async () => {} }))?.translation).toBe('no-account');
  });

  it('stops on a failed job', async () => {
    const fetchFn = answers([200, { ...JOB, state: 'failed', error: 'cairo1-run: exit 1' }]);
    await expect(waitSettleable('u', JOB.id, () => {}, { fetchFn, sleep: async () => {} })).rejects.toThrow('cairo1-run: exit 1');
  });
});
