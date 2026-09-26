import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, vi } from 'vitest';
import type { Call } from 'starknet';
import { attestBody, attestationHash, requestAttestation } from './attest';
import {
  LEVEL_VALIDATED,
  SlingfallContract,
  decodeLeaderboard,
  decodeRecord,
  feltHex,
  levelValidatedEvents,
  mentionsPanic,
  receiptGas,
  registerLevelCall,
  submitCalldata,
} from './slingfall';
import { submitLevel, type Receipt } from './submission';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));

/** `pub const NAME: felt252 = ...;` of the contract's test fixtures (the golden vectors). */
function cairoConstants(): Record<string, bigint> {
  const text = readFileSync(root('crates/slingfall_contract/src/submit/fixtures.cairo'), 'utf8');
  const found: Record<string, bigint> = {};
  for (const [, name, raw] of text.matchAll(/pub const (\w+): felt252 =\s*([^;]+);/g)) {
    const value = raw.trim();
    found[name] = value.startsWith("'")
      ? BigInt(`0x${Buffer.from(value.slice(1, -1)).toString('hex')}`)
      : BigInt(value);
  }
  return found;
}

const C = cairoConstants();
const PILE10_HASH: string = JSON.parse(readFileSync(root('fixtures/levels/pile10.felts.json'), 'utf8')).level_hash;
/** `fixtures::golden_claim()`. */
const GOLDEN = ['1', PILE10_HASH, '0', feltHex(C.PLAYER), '0xabc', '1650', '1', '2', '431', '0x33'];
const SIGNATURE = [feltHex(C.GOLDEN_R), feltHex(C.GOLDEN_S)];
const CONTRACT = '0x5afe';

describe('attestation', () => {
  it('hashes the outputs as verifier::attestation_hash', () => {
    expect(BigInt(attestationHash(GOLDEN))).toBe(C.GOLDEN_ATTESTATION_HASH);
  });

  it('posts the outputs as 0x felts, with the proof', () => {
    expect(JSON.parse(attestBody(GOLDEN, { path: '/tmp/proof.json' }))).toEqual({
      outputs: GOLDEN.map(feltHex),
      proof_path: '/tmp/proof.json',
    });
    expect(JSON.parse(attestBody(GOLDEN, { base64: 'UFJPT0Y=' })).proof).toBe('UFJPT0Y=');
    expect(JSON.parse(attestBody(GOLDEN))).toEqual({ outputs: GOLDEN.map(feltHex) });
    expect(() => attestBody(GOLDEN.slice(1))).toThrow('9 felts');
  });

  const answer = (status: number, body: unknown) =>
    vi.fn(async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;

  it('returns the service signature once it signs poseidon(outputs)', async () => {
    const fetchFn = answer(200, {
      attestation_hash: feltHex(C.GOLDEN_ATTESTATION_HASH),
      signature: SIGNATURE,
      public_key: feltHex(C.ATTESTATION_KEY),
      verified: true,
    });
    const got = await requestAttestation('http://attest/', GOLDEN, undefined, fetchFn);
    expect(got).toEqual({
      attestationHash: feltHex(C.GOLDEN_ATTESTATION_HASH),
      signature: SIGNATURE,
      publicKey: feltHex(C.ATTESTATION_KEY),
      verified: true,
    });
    expect(vi.mocked(fetchFn).mock.calls[0][0]).toBe('http://attest/attest');
  });

  it('refuses an answer over other outputs, and reports refusals', async () => {
    const other = answer(200, { attestation_hash: '0x1', signature: SIGNATURE, public_key: '0x1' });
    await expect(requestAttestation('u', GOLDEN, undefined, other)).rejects.toThrow('not poseidon(outputs)');
    const refused = answer(422, { error: 'verify: rejected (exit 1)' });
    await expect(requestAttestation('u', GOLDEN, undefined, refused)).rejects.toThrow('422 verify: rejected');
  });
});

describe('submit encoding', () => {
  it('lays out submit(outputs, evidence) as two length-prefixed arrays', () => {
    const calldata = submitCalldata(GOLDEN, SIGNATURE);
    expect(calldata).toHaveLength(1 + 10 + 1 + 2);
    expect(calldata[0]).toBe('0xa');
    expect(calldata.slice(1, 11)).toEqual(GOLDEN.map(feltHex));
    expect(calldata.slice(11)).toEqual(['0x2', ...SIGNATURE]);
    expect(() => submitCalldata(GOLDEN.slice(0, 9), SIGNATURE)).toThrow('9 felts');
    expect(() => submitCalldata(GOLDEN, [(2n ** 252n).toString()])).toThrow('not a felt');
  });

  it('registers a level from its felts', () => {
    const doc = JSON.parse(readFileSync(root('fixtures/levels/one_block.felts.json'), 'utf8')) as { felts: string[] };
    const call = registerLevelCall(CONTRACT, doc.felts);
    expect(call.entrypoint).toBe('register_level');
    expect(call.calldata).toHaveLength(1 + doc.felts.length);
    expect(BigInt((call.calldata as string[])[0])).toBe(BigInt(doc.felts.length));
  });

  it('decodes best and leaderboard', () => {
    expect(decodeRecord(['0x1450', '0x1', '0xabc', '0x7'])).toEqual({ score: 5200, won: true, inputsHash: '0xabc', block: 7 });
    expect(decodeLeaderboard(['0x2', '0x10', '0x64', '0x20', '0x32'])).toEqual([
      { player: '0x10', score: 100 },
      { player: '0x20', score: 50 },
    ]);
    expect(decodeLeaderboard(['0x0'])).toEqual([]);
    expect(() => decodeLeaderboard(['0x2', '0x10'])).toThrow('leaderboard');
  });

  it('finds LevelValidated among the receipt events', () => {
    const receipt = {
      events: [
        { from_address: '0x123', keys: [LEVEL_VALIDATED, '0x1', '0x2'], data: ['0x3', '0x4', '0x1'] },
        { from_address: CONTRACT, keys: ['0x99'], data: [] },
        { from_address: CONTRACT, keys: [LEVEL_VALIDATED, feltHex(C.PLAYER), PILE10_HASH], data: ['0xabc', '0x672', '0x1'] },
      ],
    };
    expect(levelValidatedEvents(receipt, CONTRACT)).toEqual([
      { player: feltHex(C.PLAYER), levelHash: feltHex(PILE10_HASH), inputsHash: '0xabc', score: 1650, won: true },
    ]);
    expect(receiptGas({ execution_resources: { l1_gas: 0, l1_data_gas: 128, l2_gas: 1_000_000 }, actual_fee: { amount: '0x10', unit: 'FRI' } }))
      .toEqual({ l1Gas: 0, l1DataGas: 128, l2Gas: 1_000_000, fee: '16', unit: 'FRI' });
  });

  it('recognises a panic message in a node error, as text or hex', () => {
    expect(mentionsPanic(new Error("execution reverted: 'submit: nullifier'"), 'submit: nullifier')).toBe(true);
    expect(mentionsPanic(new Error('Failure reason: 0x7375626d69743a206e756c6c6966696572'), 'submit: nullifier')).toBe(true);
    expect(mentionsPanic(new Error('0x7375626d69743a2070726f6f66'), 'submit: nullifier')).toBe(false);
  });
});

describe('submitLevel', () => {
  const player = feltHex(C.PLAYER);
  const deps = (receipt: Receipt) => {
    const execute = vi.fn(async () => ({ transaction_hash: '0xfeed' }));
    const reader = {
      callContract: async (call: Call) => (call.entrypoint === 'best' ? ['0x672', '0x1', '0xabc', '0x3'] : ['0x1', player, '0x672']),
    };
    return {
      execute,
      deps: {
        contract: new SlingfallContract(CONTRACT, reader),
        account: { address: player, execute },
        outputsFor: async (p: string) => GOLDEN.map((f, i) => (i === 3 ? p : f)),
        attest: async () => ({ attestationHash: '0x1', signature: SIGNATURE as [string, string], publicKey: '0x2', verified: true }),
        waitForReceipt: async () => receipt,
      },
    };
  };

  it('attests, submits, reads the receipt, best and the leaderboard', async () => {
    const event = { from_address: CONTRACT, keys: [LEVEL_VALIDATED, player, PILE10_HASH], data: ['0xabc', '0x672', '0x1'] };
    const { deps: d, execute } = deps({ execution_status: 'SUCCEEDED', events: [event], execution_resources: { l2_gas: 42 } });
    const steps: string[] = [];
    const result = await submitLevel(d, (s) => steps.push(s.kind));
    expect(steps).toEqual(['outputs', 'attested', 'sent', 'accepted']);
    expect(execute).toHaveBeenCalledOnce();
    expect(result).toMatchObject({
      transactionHash: '0xfeed',
      gas: { l2Gas: 42 },
      validated: { score: 1650, won: true },
      best: { score: 1650, won: true },
      leaderboard: [{ player, score: 1650 }],
    });
  });

  it('fails on a revert or a missing event', async () => {
    await expect(submitLevel(deps({ execution_status: 'REVERTED', revert_reason: "'submit: nullifier'" }).deps)).rejects.toThrow('submit: nullifier');
    await expect(submitLevel(deps({ execution_status: 'SUCCEEDED', events: [] }).deps)).rejects.toThrow('no LevelValidated');
  });
});

describe('SlingfallContract', () => {
  it('calls best / leaderboard and submits from the outputs player only', async () => {
    const calls: Call[] = [];
    const reader = {
      callContract: async (call: Call) => {
        calls.push(call);
        return call.entrypoint === 'best' ? ['0x5', '0x0', '0x1', '0x2'] : ['0x0'];
      },
    };
    const contract = new SlingfallContract(CONTRACT, reader);
    expect((await contract.best('0x10', PILE10_HASH)).score).toBe(5);
    expect(await contract.leaderboard(PILE10_HASH)).toEqual([]);
    expect(calls.map((c) => [c.entrypoint, c.calldata])).toEqual([
      ['best', ['0x10', feltHex(PILE10_HASH)]],
      ['leaderboard', [feltHex(PILE10_HASH)]],
    ]);

    const execute = vi.fn(async () => ({ transaction_hash: '0xfeed' }));
    const player = { address: feltHex(C.PLAYER), execute };
    expect(await contract.submit(player, GOLDEN, SIGNATURE)).toBe('0xfeed');
    expect(execute).toHaveBeenCalledWith({ contractAddress: CONTRACT, entrypoint: 'submit', calldata: submitCalldata(GOLDEN, SIGNATURE) });
    await expect(contract.submit({ address: '0x1', execute }, GOLDEN, SIGNATURE)).rejects.toThrow('is not the account');
  });
});
