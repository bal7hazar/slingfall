import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, vi } from 'vitest';
import type { Call } from 'starknet';
import { attestBody, attestationMessage, requestAttestation, type Attestation } from './attest';
import { hash } from 'starknet';
import {
  ATTEMPT,
  CHUNK_KIND,
  CHUNK_MARKER,
  LEVEL_VALIDATED,
  SPLIT_BUNDLE_CLASSES,
  SlingfallContract,
  adminCalls,
  bundleHash,
  decodeLeaderboard,
  decodeRecord,
  describeProof,
  explainWalletError,
  expireCall,
  feltHex,
  finalizeCall,
  levelValidatedEvents,
  mentionsPanic,
  proofKind,
  readBoards,
  receiptGas,
  registerLevelCall,
  runArgs,
  inputsFelts,
  submitCalldata,
  submitChunkCall,
  submitSettledCall,
} from './slingfall';
import { submitLevel, type Receipt } from './submission';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));

/** `pub const NAME: felt252 | u64 = ...;` of the contract's test fixtures (the golden vectors). */
function cairoConstants(): Record<string, bigint> {
  const text = readFileSync(root('crates/slingfall_contract/src/submit/fixtures.cairo'), 'utf8');
  const found: Record<string, bigint> = {};
  for (const [, name, raw] of text.matchAll(/pub const (\w+): (?:felt252|u64) =\s*([^;]+);/g)) {
    const value = raw.trim();
    found[name] = value.startsWith("'") ? BigInt(`0x${Buffer.from(value.slice(1, -1)).toString('hex')}`) : BigInt(value.replaceAll('_', ''));
  }
  return found;
}

const C = cairoConstants();
const PILE10_HASH: string = JSON.parse(readFileSync(root('fixtures/levels/pile10.felts.json'), 'utf8')).level_hash;
/** `fixtures::golden_claim()`. */
const GOLDEN = ['1', PILE10_HASH, '0', feltHex(C.PLAYER), '0xabc', '1650', '1', '2', '431', '0x33'];
/** The v2 vector: chain 'SN_SEPOLIA', contract `MESSAGE_FROM`, E3a's program, epoch 1, expiry 1 000 000. */
const CTX = {
  chainId: feltHex(C.ATTEST_CHAIN_ID),
  contract: feltHex(C.MESSAGE_FROM),
  programHash: feltHex(C.E3A_CHILD_PROGRAM_HASH),
  epoch: Number(C.ATTEST_EPOCH),
  expiry: Number(C.ATTEST_EXPIRY),
};
const EVIDENCE = [CTX.programHash, feltHex(CTX.expiry), feltHex(C.GOLDEN_ATTEST_R), feltHex(C.GOLDEN_ATTEST_S)];
const CONTRACT = CTX.contract;
const INPUTS = inputsFelts(feltHex(C.PLAYER), [{ pull_x: -604, pull_y: -392 }]);
/** A `Best` as the contract returns it: score, won, inputs_hash, block, timestamp, settled, program_hash. */
const bestFelts = (score: number, settled: boolean, program = CTX.programHash) => [feltHex(score), '0x1', '0xabc', '0x3', '0x64', settled ? '0x1' : '0x0', program];

describe('attestation (v2)', () => {
  it('hashes the message as verifier::attestation_message', () => {
    expect(BigInt(attestationMessage(CTX, GOLDEN))).toBe(C.GOLDEN_ATTEST_MESSAGE);
    expect(BigInt(attestationMessage({ ...CTX, epoch: 2 }, GOLDEN))).not.toBe(C.GOLDEN_ATTEST_MESSAGE);
  });

  it('posts the replay (level, inputs) with the outputs, or a proof', () => {
    expect(JSON.parse(attestBody({ outputs: GOLDEN, level: PILE10_HASH, inputs: INPUTS }))).toEqual({
      outputs: GOLDEN.map(feltHex),
      level: feltHex(PILE10_HASH),
      inputs: INPUTS,
    });
    expect(JSON.parse(attestBody({ outputs: GOLDEN, proof: { path: '/tmp/proof.json' } })).proof_path).toBe('/tmp/proof.json');
    expect(JSON.parse(attestBody({ outputs: GOLDEN, proof: { base64: 'UFJPT0Y=' } })).proof).toBe('UFJPT0Y=');
    expect(() => attestBody({ outputs: GOLDEN.slice(1) })).toThrow('9 felts');
  });

  const answer = (status: number, body: unknown) => vi.fn(async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;
  const golden = {
    message: feltHex(C.GOLDEN_ATTEST_MESSAGE),
    evidence: EVIDENCE,
    signature: EVIDENCE.slice(2),
    public_key: feltHex(C.ATTESTATION_KEY),
    chain_id: CTX.chainId,
    contract: CONTRACT,
    program_hash: CTX.programHash,
    epoch: CTX.epoch,
    expiry: CTX.expiry,
    outputs: GOLDEN.map(feltHex),
    verified: true,
    mode: 'execute',
  };

  it('returns the 4-felt evidence once the answer signs this contract and these outputs', async () => {
    const fetchFn = answer(200, golden);
    const got = await requestAttestation('http://attest/', CONTRACT, { outputs: GOLDEN, level: PILE10_HASH, inputs: INPUTS }, fetchFn);
    expect(got).toMatchObject({ evidence: EVIDENCE, message: feltHex(C.GOLDEN_ATTEST_MESSAGE), mode: 'execute', verified: true, ...CTX });
    expect(vi.mocked(fetchFn).mock.calls[0][0]).toBe('http://attest/attest');
  });

  it('refuses another contract, other outputs, a wrong message, a v1 answer; reports refusals', async () => {
    const ask = (body: unknown, contract = CONTRACT) => requestAttestation('u', contract, { outputs: GOLDEN }, answer(200, body));
    await expect(ask(golden, '0x1234')).rejects.toThrow('signs for contract');
    await expect(ask({ ...golden, outputs: GOLDEN.map((f, i) => (i === 5 ? '0x1' : feltHex(f))) })).rejects.toThrow('other outputs');
    await expect(ask({ ...golden, epoch: 2 })).rejects.toThrow('not the attestation message');
    await expect(ask({ attestation_hash: '0x1', signature: EVIDENCE.slice(2) })).rejects.toThrow('evidence');
    const refused = answer(422, { error: 'execute: the claimed score 0x1 differs' });
    await expect(requestAttestation('u', CONTRACT, { outputs: GOLDEN }, refused)).rejects.toThrow('422 execute');
    await expect(requestAttestation('u', CONTRACT, { outputs: GOLDEN }, answer(429, { error: 'rate limit' }))).rejects.toThrow('429 rate limit');
  });
});

describe('encoding', () => {
  it('lays out submit(outputs, evidence) as two length-prefixed arrays', () => {
    const calldata = submitCalldata(GOLDEN, EVIDENCE);
    expect(calldata).toHaveLength(1 + 10 + 1 + 4);
    expect(calldata[0]).toBe('0xa');
    expect(calldata.slice(1, 11)).toEqual(GOLDEN.map(feltHex));
    expect(calldata.slice(11)).toEqual(['0x4', ...EVIDENCE]);
    expect(() => submitCalldata(GOLDEN.slice(0, 9), EVIDENCE)).toThrow('9 felts');
    expect(() => submitCalldata(GOLDEN, [(2n ** 252n).toString()])).toThrow('not a felt');
  });

  it('registers a level from its felts', () => {
    const doc = JSON.parse(readFileSync(root('fixtures/levels/one_block.felts.json'), 'utf8')) as { felts: string[] };
    const call = registerLevelCall(CONTRACT, doc.felts);
    expect(call.entrypoint).toBe('register_level');
    expect(call.calldata).toHaveLength(1 + doc.felts.length);
    expect(BigInt((call.calldata as string[])[0])).toBe(BigInt(doc.felts.length));
  });

  it('lays out expire and the v2 admin calls', () => {
    expect(expireCall(CONTRACT, PILE10_HASH, '0x10')).toEqual({ contractAddress: CONTRACT, entrypoint: 'expire', calldata: [feltHex(PILE10_HASH), '0x10'] });
    expect(adminCalls.pinProgram(CONTRACT, '0xc1', 86_400).calldata).toEqual(['0xc1', '0x15180']);
    expect(adminCalls.revokeProgram(CONTRACT, '0xc1')).toMatchObject({ entrypoint: 'revoke_program', calldata: ['0xc1'] });
    expect(adminCalls.setSatelliteConfig(CONTRACT, { atlantic_bootloader_hash: '0xa', sharp_bootloader_hash: '0xb', satellite_address: '0xc' }).calldata).toEqual([
      '0xa',
      '0xb',
      '0xc',
    ]);
    expect(adminCalls.acceptAdmin(CONTRACT)).toEqual({ contractAddress: CONTRACT, entrypoint: 'accept_admin', calldata: [] });
    expect(adminCalls.upgrade(CONTRACT, '0x99').entrypoint).toBe('upgrade');
    expect(adminCalls.setAttestationKey(CONTRACT, '0x5').entrypoint).toBe('set_attestation_key');
  });

  it('decodes Best (7 felts) and the boards', () => {
    expect(decodeRecord(['0x1450', '0x1', '0xabc', '0x7', '0x64', '0x0', '0xc1'])).toEqual({
      score: 5200,
      won: true,
      inputsHash: '0xabc',
      block: 7,
      timestamp: 100,
      settled: false,
      programHash: '0xc1',
    });
    expect(decodeRecord(bestFelts(1, true)).settled).toBe(true);
    expect(() => decodeRecord(['0x1450', '0x1', '0xabc', '0x7', '0x0'])).toThrow('5 felts, expected 7');
    expect(decodeLeaderboard(['0x2', '0x10', '0x64', '0x20', '0x32'])).toEqual([
      { player: '0x10', score: 100 },
      { player: '0x20', score: 50 },
    ]);
    expect(decodeLeaderboard(['0x0'])).toEqual([]);
    expect(() => decodeLeaderboard(['0x2', '0x10'])).toThrow('leaderboard');
  });

  it('finds LevelValidated (with its program hash) among the receipt events', () => {
    const receipt = {
      events: [
        { from_address: '0x123', keys: [LEVEL_VALIDATED, '0x1', '0x2'], data: ['0x3', '0x4', '0x1', '0x0', '0xc1'] },
        { from_address: CONTRACT, keys: ['0x99'], data: [] },
        { from_address: CONTRACT, keys: [LEVEL_VALIDATED, feltHex(C.PLAYER), PILE10_HASH], data: ['0xabc', '0x672', '0x1', '0x0', '0xc1'] },
        { from_address: CONTRACT, keys: [LEVEL_VALIDATED, feltHex(C.PLAYER), PILE10_HASH], data: ['0xabd', '0x672', '0x1', '0x1', '0xc2'] },
        // v3: the trailing `proven` felt (finalize), the program hash a bundle hash.
        { from_address: CONTRACT, keys: [LEVEL_VALIDATED, feltHex(C.PLAYER), PILE10_HASH], data: ['0xabe', '0x672', '0x1', '0x1', '0xbd', '0x1'] },
      ],
    };
    const common = { player: feltHex(C.PLAYER), levelHash: feltHex(PILE10_HASH), score: 1650, won: true };
    expect(levelValidatedEvents(receipt, CONTRACT)).toEqual([
      { ...common, inputsHash: '0xabc', settled: false, programHash: '0xc1', proven: false },
      { ...common, inputsHash: '0xabd', settled: true, programHash: '0xc2', proven: false },
      { ...common, inputsHash: '0xabe', settled: true, programHash: '0xbd', proven: true },
    ]);
    expect(receiptGas({ execution_resources: { l1_gas: 0, l1_data_gas: 128, l2_gas: 1_000_000 }, actual_fee: { amount: '0x10', unit: 'FRI' } })).toEqual({
      l1Gas: 0,
      l1DataGas: 128,
      l2Gas: 1_000_000,
      fee: '16',
      unit: 'FRI',
    });
  });

  it('recognises a panic message in a node error, as text or hex', () => {
    expect(mentionsPanic(new Error("execution reverted: 'submit: nullifier'"), 'submit: nullifier')).toBe(true);
    expect(mentionsPanic(new Error('Failure reason: 0x7375626d69743a206e756c6c6966696572'), 'submit: nullifier')).toBe(true);
    expect(mentionsPanic(new Error('0x7375626d69743a2070726f6f66'), 'submit: nullifier')).toBe(false);
  });

  it('explains a wallet or contract error in plain words (m14)', () => {
    expect(explainWalletError(new Error("Nested error: 0x7375626d69743a2070726f6772616d ('submit: program')"))).toContain('no longer accepts the engine release');
    expect(explainWalletError(new Error("RPC: starknet_estimateFee … ('submit: proof')"))).toContain('refuses this proof or attestation');
    expect(explainWalletError(new Error("execution reverted: 'submit: nullifier'"))).toContain('perhaps by the relay');
    expect(explainWalletError(new Error("'expire: early'"))).toContain('not old enough');
    expect(explainWalletError(new Error("0x66696e616c697a653a20636861696e ('finalize: chain')"))).toContain('SNIP-36 chain');
    expect(explainWalletError(new Error('User rejected request'))).toBe('cancelled in the wallet');
    expect(explainWalletError(new Error('Execute failed'))).toBe('Execute failed');
    expect(explainWalletError('boom')).toBe('boom');
  });
});

/** A fake contract: `best` / `best_settled` / boards per entry point. */
function fakeReader(values: Record<string, string[]>, calls: Call[] = []) {
  return {
    callContract: async (call: Call) => {
      calls.push(call);
      const value = values[call.entrypoint];
      if (value === undefined) throw new Error(`unexpected ${call.entrypoint}`);
      return value;
    },
  };
}

describe('submitLevel', () => {
  const player = feltHex(C.PLAYER);
  const attestation: Attestation = { ...CTX, message: '0x1', evidence: EVIDENCE as Attestation['evidence'], publicKey: '0x2', verified: true, mode: 'execute' };
  const deps = (receipt: Receipt) => {
    const execute = vi.fn(async () => ({ transaction_hash: '0xfeed' }));
    const reader = fakeReader({
      best: bestFelts(1650, false),
      best_settled: bestFelts(0, false, '0x0').map((f, i) => (i === 1 ? '0x0' : f)),
      leaderboard: ['0x0'],
      leaderboard_provisional: ['0x1', player, '0x672'],
      current_program: [CTX.programHash],
    });
    return {
      execute,
      deps: {
        contract: new SlingfallContract(CONTRACT, reader),
        account: { address: player, execute },
        outputsFor: async (p: string) => GOLDEN.map((f, i) => (i === 3 ? p : f)),
        attest: async () => attestation,
        waitForReceipt: async () => receipt,
      },
    };
  };

  it('attests, submits the 4-felt evidence, reads both records and both boards', async () => {
    const event = { from_address: CONTRACT, keys: [LEVEL_VALIDATED, player, PILE10_HASH], data: ['0xabc', '0x672', '0x1', '0x0', CTX.programHash] };
    const { deps: d, execute } = deps({ execution_status: 'SUCCEEDED', events: [event], execution_resources: { l2_gas: 42 } });
    const steps: string[] = [];
    const result = await submitLevel(d, (s) => steps.push(s.kind));
    expect(steps).toEqual(['outputs', 'attested', 'sent', 'accepted']);
    expect(execute).toHaveBeenCalledWith({ contractAddress: CONTRACT, entrypoint: 'submit', calldata: submitCalldata(GOLDEN, EVIDENCE) });
    expect(result).toMatchObject({
      transactionHash: '0xfeed',
      gas: { l2Gas: 42 },
      validated: { score: 1650, won: true, settled: false, programHash: CTX.programHash },
      best: { score: 1650, settled: false },
      bestSettled: { score: 0 },
      boards: { settled: [], provisional: [{ player, score: 1650, settled: false, programHash: CTX.programHash }] },
    });
  });

  it('fails on a revert or a missing event', async () => {
    await expect(submitLevel(deps({ execution_status: 'REVERTED', revert_reason: "'submit: nullifier'" }).deps)).rejects.toThrow('submit: nullifier');
    await expect(submitLevel(deps({ execution_status: 'SUCCEEDED', events: [] }).deps)).rejects.toThrow('no LevelValidated');
  });
});

describe('SlingfallContract (v2)', () => {
  it('reads both tiers and the program set', async () => {
    const calls: Call[] = [];
    const contract = new SlingfallContract(
      CONTRACT,
      fakeReader(
        {
          best: bestFelts(5, false),
          best_settled: bestFelts(3, true),
          leaderboard: ['0x0'],
          leaderboard_provisional: ['0x0'],
          current_program: ['0xc2'],
          program_valid_until: ['0x64'],
          attestation_epoch: ['0x2'],
          attempt: ['0x1'],
          satellite_config: ['0xa', '0xb', '0xc'],
        },
        calls,
      ),
    );
    expect((await contract.best('0x10', PILE10_HASH)).score).toBe(5);
    expect(await contract.bestSettled('0x10', PILE10_HASH)).toMatchObject({ score: 3, settled: true });
    expect(await contract.leaderboardProvisional(PILE10_HASH)).toEqual([]);
    expect(await contract.currentProgram()).toBe('0xc2');
    expect(await contract.programValidUntil('0xc1')).toBe(100n);
    expect(await contract.attestationEpoch()).toBe(2);
    expect(await contract.attempt(PILE10_HASH, '0x10', '0xabc')).toBe(1);
    expect(await contract.satelliteConfig()).toEqual({ atlantic_bootloader_hash: '0xa', sharp_bootloader_hash: '0xb', satellite_address: '0xc' });
    expect(calls.slice(0, 2).map((c) => [c.entrypoint, c.calldata])).toEqual([
      ['best', ['0x10', feltHex(PILE10_HASH)]],
      ['best_settled', ['0x10', feltHex(PILE10_HASH)]],
    ]);
  });

  it('submits from the outputs player only, settles for anyone (relay)', async () => {
    const contract = new SlingfallContract(CONTRACT, fakeReader({}));
    const execute = vi.fn(async () => ({ transaction_hash: '0xfeed' }));
    const player = { address: feltHex(C.PLAYER), execute };
    expect(await contract.submit(player, GOLDEN, EVIDENCE)).toBe('0xfeed');
    await expect(contract.submit({ address: '0x1', execute }, GOLDEN, EVIDENCE)).rejects.toThrow('is not the account');
    const args = ['0x1', '0x2', '0x1', '0x3'];
    const relay = { address: '0x1', execute };
    expect(await contract.submitSettled(relay, GOLDEN, args, '0xc1')).toBe('0xfeed');
    expect(execute).toHaveBeenLastCalledWith(submitSettledCall(CONTRACT, GOLDEN, args, '0xc1'));
    expect(await contract.expire(relay, PILE10_HASH, player.address)).toBe('0xfeed');
    expect(execute).toHaveBeenLastCalledWith(expireCall(CONTRACT, PILE10_HASH, player.address));
  });

  it('reads both boards with the release and the proof of each row', async () => {
    const [a, b, c] = ['0xa1', '0xb2', '0xc3'];
    const reader = {
      callContract: async (call: Call) => {
        const [first, who] = (call.calldata as string[]) ?? [];
        switch (call.entrypoint) {
          case 'leaderboard':
            return ['0x2', c, '0x7', b, '0x5'];
          case 'leaderboard_provisional':
            return ['0x3', a, '0x9', c, '0x7', b, '0x5'];
          case 'current_program':
            return ['0xc2'];
          case 'best':
            return first === a ? bestFelts(9, false, '0xc2') : first === c ? bestFelts(7, true, '0xbd') : bestFelts(5, true, '0xc1');
          case 'best_settled':
            return first === c ? bestFelts(7, true, '0xbd') : bestFelts(5, true, '0xc1');
          case 'attempt': // (level, player, inputs_hash): c proven by SNIP-36, b settled by SHARP
            return [who === c ? '0x3' : '0x2'];
          default:
            throw new Error(call.entrypoint);
        }
      },
    };
    expect(await readBoards(new SlingfallContract(CONTRACT, reader), PILE10_HASH)).toEqual({
      settled: [
        { player: c, score: 7, programHash: '0xbd', settled: true, proof: 'snip36' },
        { player: b, score: 5, programHash: '0xc1', settled: true, proof: 'sharp' },
      ],
      provisional: [
        { player: a, score: 9, programHash: '0xc2', settled: false, proof: null },
        { player: c, score: 7, programHash: '0xbd', settled: true, proof: 'snip36' },
        { player: b, score: 5, programHash: '0xc1', settled: true, proof: 'sharp' },
      ],
      currentProgram: '0xc2',
    });
  });

  it('says which proof validated a row', () => {
    expect([proofKind(false, ATTEMPT.attested), proofKind(true, ATTEMPT.settled), proofKind(true, ATTEMPT.proven)]).toEqual([null, 'sharp', 'snip36']);
    expect(describeProof({ proof: 'snip36', programHash: '0xbd' })).toBe('proven by SNIP-36 · bundle 0xbd');
    expect(describeProof({ proof: 'sharp', programHash: '0xc1' })).toBe('settled by SHARP · program 0xc1');
    expect(describeProof({ proof: null, programHash: '0xc1' })).toBe('provisional · program 0xc1');
  });
});

describe('proven tier (v3)', () => {
  it('lays out submit_chunk(chain, kind, payload) and finalize(chain, level_hash, inputs, outputs)', () => {
    const payload = ['0x51', '0x1a', '0x0', '0x5a', '0x52'];
    expect(submitChunkCall(CONTRACT, '0xc4a1', CHUNK_KIND.step, payload)).toEqual({
      contractAddress: CONTRACT,
      entrypoint: 'submit_chunk',
      calldata: ['0xc4a1', '0x1', '0x5', ...payload],
    });
    const call = finalizeCall(CONTRACT, '0xc4a1', PILE10_HASH, INPUTS, GOLDEN);
    expect(call.entrypoint).toBe('finalize');
    expect(call.calldata).toEqual(['0xc4a1', feltHex(PILE10_HASH), feltHex(INPUTS.length), ...INPUTS, '0xa', ...GOLDEN.map(feltHex)]);
    expect(() => finalizeCall(CONTRACT, '0xc4a1', PILE10_HASH, INPUTS, GOLDEN.slice(1))).toThrow('9 felts');
  });

  it('lays out the v3 admin calls', () => {
    expect(adminCalls.setChunkMarker(CONTRACT, CHUNK_MARKER)).toMatchObject({ entrypoint: 'set_chunk_marker', calldata: [CHUNK_MARKER] });
    expect(adminCalls.pinChain(CONTRACT, '0xc4a1', '0xbd', 3600).calldata).toEqual(['0xc4a1', '0xbd', '0xe10']);
    expect(adminCalls.revokeChain(CONTRACT, '0xc4a1')).toMatchObject({ entrypoint: 'revoke_chain', calldata: ['0xc4a1'] });
    expect(adminCalls.pinVirtualOs(CONTRACT, '0x53f6', 0).calldata).toEqual(['0x53f6', '0x0']);
    expect(adminCalls.revokeVirtualOs(CONTRACT, '0x53f6').entrypoint).toBe('revoke_virtual_os');
  });

  it("uses the contract's marker and the prover service's bundle order", () => {
    const simulate = readFileSync(root('crates/slingfall_contract/src/simulate.cairo'), 'utf8');
    const [, marker] = simulate.match(/pub const MARKER: felt252 = '(\w+)';/)!;
    expect(CHUNK_MARKER).toBe(feltHex(`0x${Buffer.from(marker).toString('hex')}`));
    const service = readFileSync(root('services/prove/snip36.py'), 'utf8');
    const [, tuple] = service.match(/BUNDLE_CLASSES = \(([^)]*)\)/)!;
    expect([...tuple.matchAll(/"(\w+)"/g)].map((m) => m[1])).toEqual([...SPLIT_BUNDLE_CLASSES]);
    const classes = SPLIT_BUNDLE_CLASSES.map((_, i) => feltHex(i + 1));
    expect(bundleHash(classes)).toBe(feltHex(hash.computePoseidonHashOnElements(classes.map(BigInt))));
    expect(bundleHash([...classes].reverse())).not.toBe(bundleHash(classes));
    expect(() => bundleHash(classes.slice(1))).toThrow('16 class hashes');
  });

  it('reads the chain and virtual-OS sets', async () => {
    const contract = new SlingfallContract(
      CONTRACT,
      fakeReader({
        chunk_marker: [CHUNK_MARKER],
        current_chain: ['0xc4a1'],
        chain_valid_until: [feltHex(2n ** 64n - 1n)],
        chain_bundle: ['0xbd'],
        current_virtual_os: ['0x53f6'],
        virtual_os_valid_until: ['0x0'],
        level: ['0xa0', '0x1', '0x1', '0x64'],
      }),
    );
    expect(await contract.chunkMarker()).toBe(CHUNK_MARKER);
    expect(await contract.currentChain()).toBe('0xc4a1');
    expect(await contract.chainValidUntil('0xc4a1')).toBe(2n ** 64n - 1n);
    expect(await contract.chainBundle('0xc4a1')).toBe('0xbd');
    expect(await contract.currentVirtualOs()).toBe('0x53f6');
    expect(await contract.virtualOsValidUntil('0x1')).toBe(0n);
    expect(await contract.level(PILE10_HASH)).toEqual({ author: '0xa0', version: 1, active: true, registeredAt: 100 });
  });
});

describe('settled tier', () => {
  /** The E3a run of pile10-reference (`fixtures/proofs/atlantic`): its outputs and c1main's argument. */
  const e3a = JSON.parse(readFileSync(root('fixtures/proofs/atlantic/pile10-reference.json'), 'utf8')) as {
    args: string[];
    outputs: string[];
    run: { child_program_hash: string };
  };

  it('lays out submit_settled(outputs, args, child_program_hash)', () => {
    const call = submitSettledCall(CONTRACT, e3a.outputs, e3a.args, e3a.run.child_program_hash);
    expect(call.entrypoint).toBe('submit_settled');
    expect(call.calldata).toEqual([...submitCalldata(e3a.outputs, e3a.args), feltHex(e3a.run.child_program_hash)]);
  });

  it('writes the Inputs felts and the run argument as tracec.py does', () => {
    const level = JSON.parse(readFileSync(root('fixtures/levels/pile10.felts.json'), 'utf8')) as { felts: string[] };
    expect(runArgs(level.felts, INPUTS)).toEqual(e3a.args.map(feltHex));
    expect(inputsFelts('0x1', [{ pull_x: 3, pull_y: -1, delay: 30 }])).toEqual(['0x1', '0x1', '0x3', feltHex(2n ** 251n + 17n * 2n ** 192n), '0x1e', '0x0']);
  });
});
