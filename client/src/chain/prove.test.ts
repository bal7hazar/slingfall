import { describe, expect, it, vi } from 'vitest';
import {
  ChainMismatchError,
  ProgramMismatchError,
  describeJob,
  fetchHealth,
  proofStatus,
  requestProof,
  settleLabel,
  waitCheap,
  waitRelayed,
  waitSettleable,
} from './prove';

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
    expect(job?.settleable).toBe(true);
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
    expect(describeJob({ ...k, translation: 'off' })).toBe('proof on Starknet (Satellite): ready to settle');
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
    const idle = { ...KECCAK, translation: { state: 'off' } };
    expect((await waitCheap('u', JOB.id, () => {}, { fetchFn: answers([200, idle]), sleep: async () => {} }))?.translation).toBe('off');
  });

  it('stops on a failed job', async () => {
    const fetchFn = answers([200, { ...JOB, state: 'failed', error: 'cairo1-run: exit 1' }]);
    await expect(waitSettleable('u', JOB.id, () => {}, { fetchFn, sleep: async () => {} })).rejects.toThrow('cairo1-run: exit 1');
  });

  it('decodes the program state (M6, v2 grace) and reports an invalid program in the status line', async () => {
    const body = { ...JOB, program_hash: '0x1', contract_program_hash: '0x2', program_valid_until: 1000, program_match: false };
    const job = await proofStatus('u', 'x', answers([200, body]));
    expect(job).toMatchObject({ programHash: '0x1', contractProgramHash: '0x2', programValidUntil: 1000n, programMatch: false });
    expect(describeJob(job)).toBe('proof made with engine release 0x1, which the contract no longer accepts (current 0x2): it cannot be settled');
    const unknown = await proofStatus('u', 'x', answers([200, JOB]));
    expect(unknown).toMatchObject({ programHash: null, contractProgramHash: null, programValidUntil: null, programMatch: null, relayState: 'off', relayed: false });
  });

  it('decodes the relay (S10) and stops polling once relayed', async () => {
    const waiting = { ...POSEIDON, relay: { state: 'waiting' }, relayed: false };
    const relayed = { ...POSEIDON, relay: { state: 'relayed', transaction_hash: '0x5e7' }, relayed: true, relay_transaction_hash: '0x5e7' };
    const job = await proofStatus('u', 'x', answers([200, relayed]));
    expect(job).toMatchObject({ relayed: true, relayTransactionHash: '0x5e7', relayState: 'relayed' });
    expect(describeJob(job)).toBe('settled on Starknet by the relay in 0x5e7');
    // Relayed before the page saw it settleable: waitSettleable returns it at once.
    expect((await waitSettleable('u', JOB.id, () => {}, { fetchFn: answers([200, { ...JOB, relayed: true }]), sleep: async () => {} }))?.relayed).toBe(true);
    const fetchFn = answers([200, waiting], [200, { ...waiting, relay: { state: 'waiting', error: 'simulate: busy' } }], [200, relayed]);
    const seen: string[] = [];
    const done = await waitRelayed('u', JOB.id, (j) => seen.push(j.relayState), { fetchFn, sleep: async () => {} });
    expect(done?.relayed).toBe(true);
    expect(seen).toEqual(['waiting', 'waiting', 'relayed']);
    const gaveUp = { ...waiting, relay: { state: 'gave-up', error: 'send: boom' } };
    expect(await waitRelayed('u', JOB.id, () => {}, { fetchFn: answers([200, gaveUp]), sleep: async () => {} })).toMatchObject({
      relayState: 'gave-up',
      relayError: 'send: boom',
    });
  });

  it('throws ProgramMismatchError on a 409 (M6)', async () => {
    const fetchFn = answers([409, { error: 'prove: program mismatch', program_hash: '0x1', contract_program_hash: '0x2' }]);
    const error = await requestProof('http://prove/', JOB.level_hash, ['0x706c61796572', '1', '0', '0', '0', '0'], fetchFn).catch((e) => e);
    expect(error).toBeInstanceOf(ProgramMismatchError);
    expect(error).toMatchObject({ programHash: '0x1', contractProgramHash: '0x2' });
  });

  it('reads /health, including the program hashes once known', async () => {
    const fetchFn = answers([
      200,
      { result: 'PROOF_VERIFICATION_ON_L2', submit: true, queued: 0, program_hash: '0x1', contract_program_hash: '0x1', program_match: true, relay: '0xre1a7' },
    ]);
    const health = await fetchHealth('http://prove/', fetchFn);
    expect(health).toEqual({
      result: 'PROOF_VERIFICATION_ON_L2',
      submit: true,
      queued: 0,
      programHash: '0x1',
      contractProgramHash: '0x1',
      programMatch: true,
      relay: '0xre1a7',
      proven: null,
    });
    expect(vi.mocked(fetchFn).mock.calls[0][0]).toBe('http://prove/health');
  });
});

describe('proven tier (SNIP-36)', () => {
  const PROVEN_JOB = {
    id: 'f55f0fdd2eeb24d7d4ab25e6aeaaf0f2',
    tier: 'proven',
    state: 'proving',
    level_hash: JOB.level_hash,
    inputs: JOB.inputs,
    proven: false,
    settleable: false,
    plan: { transactions: 4 },
    proofs: [{ state: 'proved', messages: 2 }, { state: 'proving' }, { state: 'pending' }, { state: 'pending' }],
    error: null,
  };
  const PROVEN = {
    ...PROVEN_JOB,
    state: 'proven',
    proven: true,
    proofs: PROVEN_JOB.proofs.map((p, i) => ({ ...p, state: 'submitted', transaction_hash: `0x70${i}` })),
    finalize: { state: 'finalized', transaction_hash: '0xf1' },
  };

  it('asks for the proven tier and follows the proofs until proven', async () => {
    const fetchFn = answers([202, { ...PROVEN_JOB, state: 'queued', proofs: undefined }], [200, PROVEN_JOB], [200, { ...PROVEN_JOB, state: 'submitting' }], [200, PROVEN]);
    const job = await requestProof('http://prove/', JOB.level_hash, JOB.inputs, fetchFn, 'proven');
    expect(JSON.parse(String(vi.mocked(fetchFn).mock.calls[0][1]?.body))).toEqual({ level: JOB.level_hash, inputs: JOB.inputs, tier: 'proven' });
    expect(job).toMatchObject({ tier: 'proven', state: 'queued', proven: false, proofs: [] });
    expect(describeJob(job)).toContain('planning the SNIP-36 chain');
    const seen: string[] = [];
    const done = await waitSettleable('u', job.id, (j) => seen.push(describeJob(j)), { fetchFn, sleep: async () => {} });
    expect(done).toMatchObject({ proven: true, finalizeTransactionHash: '0xf1' });
    expect(done?.proofs.map((p) => p.transactionHash)).toEqual(['0x700', '0x701', '0x702', '0x703']);
    expect(seen).toEqual([
      'proving by SNIP-36: 1/4 transactions proven',
      'sending the SNIP-36 proofs to the contract: 0/4',
      'proven by SNIP-36 on Starknet (finalized by the prover service in 0xf1)',
    ]);
  });

  it('reads the proven path of /health and refuses a chain mismatch (409)', async () => {
    const proven = { available: true, prover: 'fake', chain: '0xc4a1', own_bundle_hash: '0xbd', bundle_hash: '0xbd', chain_match: true };
    const health = await fetchHealth('http://prove/', answers([200, { result: 'PROOF_VERIFICATION_ON_L2', proven }]));
    expect(health.proven).toEqual({ available: true, prover: 'fake', chain: '0xc4a1', bundleHash: '0xbd', chainMatch: true });
    const refused = answers([409, { error: 'prove: chain mismatch', chain: '0xc4a1', own_bundle_hash: '0xbd', bundle_hash: '0xbe', chain_match: false }]);
    const error = await requestProof('u', JOB.level_hash, JOB.inputs, refused, 'proven').catch((e) => e);
    expect(error).toBeInstanceOf(ChainMismatchError);
    expect(error.message).toContain('chain mismatch');
  });

  it('stops on a failed proof', async () => {
    const failed = { ...PROVEN_JOB, state: 'failed', error: 'prover: proving failed' };
    await expect(waitSettleable('u', PROVEN_JOB.id, () => {}, { fetchFn: answers([200, failed]), sleep: async () => {} })).rejects.toThrow('prover: proving failed');
  });
});
