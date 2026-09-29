// @vitest-environment happy-dom
// DOM tests of the chain panel (lots W1, W3): the tiers, the background proof (settled or proven),
// the relay, the player's own settle, and the refusals, over a fake contract, a fake wallet and
// fake services.
import { describe, expect, it, vi } from 'vitest';
import type { Call } from 'starknet';
import { attestationMessage } from './attest';
import type { ChainConfig } from './config';
import { SubmitPanel, type PanelDeps } from './panel';
import { LEVEL_VALIDATED, SlingfallContract, feltHex, runArgs, shortFelt, submitCalldata, submitSettledCall } from './slingfall';
import type { Receipt } from './submission';

const CONTRACT = '0x5afe';
const PLAYER = '0x706c61796572';
const LEVEL = '0x17876831f245e0ec3d63220f2cb73c429ec93e7c888c2aa916d237cd9c114a3';
const PROGRAM = '0xc1';
const LEVEL_FELTS = ['0x5', '0x6'];
const OUTPUTS = (player: string) => ['0x1', LEVEL, '0x0', player, '0xabc', '0x672', '0x1', '0x2', '0x1af', '0x33'];
const INPUTS = (player: string) => [player, '0x1', '0x1', '0x2', '0x0', '0x0'];
const CONFIG: ChainConfig = {
  address: CONTRACT,
  network: 'devnet',
  rpcUrl: 'http://rpc',
  explorerUrl: null,
  attestUrl: 'http://attest',
  proveUrl: 'http://prove',
  devnetAccount: { address: PLAYER, privateKey: '0x1' },
  deployBlock: 0,
  local: false,
};
const JOB = { id: 'bcbdf222b4585dc0821f5b88135a3026', state: 'submitted', level_hash: LEVEL, inputs: INPUTS(PLAYER), program_hash: PROGRAM };
/** The SNIP-36 chain's bundle hash: the release of a proven record. */
const BUNDLE = '0xbd';
const PROVEN_JOB = { id: 'f55f0fdd2eeb24d7d4ab25e6aeaaf0f2', tier: 'proven', state: 'queued', level_hash: LEVEL, inputs: INPUTS(PLAYER), proofs: [] };

/** Lets every pending promise and timer-free continuation run. */
const flush = async () => {
  for (let i = 0; i < 30; i++) await new Promise((r) => setTimeout(r, 0));
};

interface Harness {
  panel: SubmitPanel;
  root: HTMLElement;
  execute: ReturnType<typeof vi.fn>;
  requests: { url: string; body: unknown }[];
  /** Resolves the pending polls (`sleep`) one round. */
  tick(): Promise<void>;
  /** The delays the panel slept for, in order. */
  sleeps: number[];
  text(selector: string): string;
  button(label: RegExp): HTMLButtonElement;
}

/** A contract with one player's records: `settled` once a settle (or the relay) lands. */
function setup({
  relay = null as string | null,
  statuses = [] as Record<string, unknown>[],
  programMatch = true,
  verifier = 1,
  refuseSettle = null as string | null,
  proven = false,
  chainMismatch = false,
  local = false,
} = {}): Harness {
  const chain = { provisional: false, settled: false, proven: false };
  const release = () => (chain.proven ? BUNDLE : PROGRAM);
  const best = (settled: boolean, score: number) => [feltHex(score), score ? '0x1' : '0x0', '0xabc', '0x3', '0x64', settled ? '0x1' : '0x0', score ? release() : '0x0'];
  const reader = {
    callContract: async (call: Call): Promise<string[]> => {
      switch (call.entrypoint) {
        case 'verifier':
          return [feltHex(verifier)];
        case 'best':
          return best(chain.settled, chain.provisional || chain.settled ? 1650 : 0);
        case 'best_settled':
          return best(chain.settled, chain.settled ? 1650 : 0);
        case 'leaderboard':
          return chain.settled ? ['0x1', PLAYER, '0x672'] : ['0x0'];
        case 'leaderboard_provisional':
          return chain.provisional || chain.settled ? ['0x1', PLAYER, '0x672'] : ['0x0'];
        case 'current_program':
          return [PROGRAM];
        case 'level_data':
          return [feltHex(LEVEL_FELTS.length), ...LEVEL_FELTS];
        case 'attempt':
          return [chain.proven ? '0x3' : chain.settled ? '0x2' : '0x1'];
        default:
          throw new Error(`unexpected read ${call.entrypoint}`);
      }
    },
  };
  let n = 0;
  const sent = new Map<string, Call>();
  const executeFn = vi.fn(async (call: Call) => {
    if (refuseSettle && call.entrypoint === 'submit_settled') throw new Error(`execution reverted: '${refuseSettle}'`);
    const hash = feltHex(0xfeed0 + n++);
    sent.set(hash, call);
    return { transaction_hash: hash };
  });
  const receipt = async (hash: string): Promise<Receipt> => {
    const call = sent.get(hash)!;
    const settled = call.entrypoint === 'submit_settled';
    if (settled) chain.settled = true;
    else chain.provisional = true;
    const data = ['0xabc', '0x672', '0x1', settled ? '0x1' : '0x0', PROGRAM];
    return { execution_status: 'SUCCEEDED', events: [{ from_address: CONTRACT, keys: [LEVEL_VALIDATED, PLAYER, LEVEL], data }], execution_resources: { l2_gas: 7 } };
  };
  const requests: { url: string; body: unknown }[] = [];
  let status = 0;
  const json = (body: unknown, code = 200) => new Response(JSON.stringify(body), { status: code });
  const fetchFn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    requests.push({ url, body });
    if (url.endsWith('/health')) {
      const path = proven ? { available: true, prover: 'fake', chain: '0xc4a1', own_bundle_hash: BUNDLE, chain_match: true } : null;
      return json({ result: 'x', submit: true, queued: 0, program_hash: PROGRAM, contract_program_hash: PROGRAM, program_match: programMatch, relay, proven: path });
    }
    if (url.endsWith('/attest')) {
      const ctx = { chainId: '0x534e5f5345504f4c4941', contract: CONTRACT, programHash: PROGRAM, epoch: 1, expiry: 2_000 };
      return json({
        message: attestationMessage(ctx, body.outputs),
        evidence: [PROGRAM, '0x7d0', '0x1', '0x2'],
        public_key: '0x3',
        chain_id: ctx.chainId,
        contract: CONTRACT,
        epoch: 1,
        outputs: body.outputs,
        verified: true,
        mode: 'execute',
      });
    }
    if (url.endsWith('/prove')) {
      if (body.tier !== 'proven') return json(JOB, 202);
      if (chainMismatch) return json({ error: 'prove: chain mismatch', chain: '0xc4a1', own_bundle_hash: BUNDLE, bundle_hash: '0xbe', chain_match: false }, 409);
      return json(PROVEN_JOB, 202);
    }
    if (url.includes('/status/')) {
      const answer = statuses[Math.min(status++, statuses.length - 1)];
      if (answer.relayed) chain.settled = true;
      if (answer.proven) Object.assign(chain, { settled: true, proven: true });
      return json({ ...(answer.tier === 'proven' ? PROVEN_JOB : JOB), ...answer });
    }
    return json({ error: 'not found' }, 404);
  });
  const gates: (() => void)[] = [];
  const sleeps: number[] = [];
  const deps: PanelDeps = {
    contract: new SlingfallContract(CONTRACT, reader),
    waitForReceipt: receipt,
    connect: async () => ({ address: PLAYER, execute: executeFn }),
    events: { getEvents: async () => ({ events: [] }) },
    fetchFn: fetchFn as unknown as typeof fetch,
    sleep: (ms) => {
      sleeps.push(ms);
      return new Promise<void>((r) => gates.push(r));
    },
  };
  const parent = document.createElement('div');
  document.body.replaceChildren(parent);
  const panel = new SubmitPanel(parent, { ...CONFIG, local }, deps);
  const root = parent.querySelector<HTMLElement>('.submit')!;
  return {
    panel,
    root,
    execute: executeFn,
    requests,
    sleeps,
    tick: async () => {
      gates.splice(0).forEach((open) => open());
      await flush();
    },
    text: (selector) => root.querySelector(selector)?.textContent ?? '',
    button: (label) => [...root.querySelectorAll('button')].find((b) => label.test(b.textContent ?? ''))!,
  };
}

async function connectAndOffer(h: Harness): Promise<string[]> {
  const accounts: string[] = [];
  h.panel.onAccount = (player) => accounts.push(player);
  await flush();
  h.panel.offer(LEVEL, async (player) => OUTPUTS(player), INPUTS);
  await flush();
  h.button(/^Connect$/).click();
  await flush();
  return accounts;
}

describe('SubmitPanel', () => {
  it('shows both boards, and tells the page the connected account (m11)', async () => {
    const h = setup();
    const accounts = await connectAndOffer(h);
    expect(h.root.hidden).toBe(false);
    expect(accounts).toEqual([PLAYER]);
    expect(h.text('.submit-outputs')).toBe(`Outputs for ${shortFelt(PLAYER)}: inputs_hash 0xabc, final_state_hash 0x33`);
    expect([...h.root.querySelectorAll('h4')].map((e) => e.textContent)).toEqual(['Settled (proven: SHARP or SNIP-36)', 'Live (provisional and settled)']);
    expect(h.text('.submit-board.settled')).toBe('no record yet');
    expect(h.button(/^Submit$/).disabled).toBe(false);
  });

  it('provisional in seconds, proof in the background, settled by the relay; never "keep this page open"', async () => {
    const h = setup({ relay: '0xre1a7', statuses: [{ settleable: false }, { settleable: true, settleable_poseidon: true, relayed: true, relay: { state: 'relayed' }, relay_transaction_hash: '0x5e7' }] });
    await connectAndOffer(h);
    h.button(/^Submit$/).click();
    await flush();
    // The attested submit: the service replays level + inputs, the evidence is 4 felts.
    const attest = h.requests.find((r) => r.url.endsWith('/attest'))!.body as Record<string, unknown>;
    expect(attest).toMatchObject({ level: LEVEL, inputs: INPUTS(PLAYER) });
    expect(h.execute).toHaveBeenCalledWith({ contractAddress: CONTRACT, entrypoint: 'submit', calldata: submitCalldata(OUTPUTS(PLAYER), [PROGRAM, '0x7d0', '0x1', '0x2']) });
    expect(h.text('.submit-status')).toContain('Provisional record in');
    const live = h.root.querySelector('.submit-board.provisional li')!;
    expect(live.textContent).toBe(`${shortFelt(PLAYER)} 1650 · provisional · program ${PROGRAM}`);
    expect(live.className).toBe('mine');
    // The proof was requested on its own; with a relay the page may be closed.
    expect(h.requests.some((r) => r.url.endsWith('/prove'))).toBe(true);
    expect(h.text('.submit-tier')).toContain('you may close this page');
    await h.tick();
    expect(h.text('.submit-tier')).toBe(`Settled by the relay in 0x5e7: your settled best 1650 (won, engine ${PROGRAM})`);
    expect(h.execute).toHaveBeenCalledTimes(1); // the player signed nothing more
    expect(h.text('.submit-board.settled li')).toBe(`${shortFelt(PLAYER)} 1650 · settled by SHARP · program ${PROGRAM}`);
    expect(h.root.textContent).not.toContain('keep this page open');
    expect(h.button(/^Settle/).hidden).toBe(true);
  });

  it('proven path: the prover service proves the chain and records it (SNIP-36); the player signs nothing more', async () => {
    const proving = { tier: 'proven', state: 'proving', proofs: [{ state: 'proved', messages: 2 }, { state: 'proving' }] };
    const done = { tier: 'proven', state: 'proven', proven: true, proofs: [{ state: 'submitted' }, { state: 'submitted' }], finalize: { transaction_hash: '0xf1' } };
    const h = setup({ proven: true, statuses: [proving, done] });
    await connectAndOffer(h);
    h.button(/^Submit$/).click();
    await flush();
    const prove = h.requests.find((r) => r.url.endsWith('/prove'))!.body as Record<string, unknown>;
    expect(prove).toMatchObject({ level: LEVEL, inputs: INPUTS(PLAYER), tier: 'proven' });
    expect(h.text('.submit-tier')).toContain('proving by SNIP-36: 1/2 transactions proven');
    expect(h.text('.submit-tier')).toContain('you may close this page');
    await h.tick();
    expect(h.text('.submit-tier')).toBe(`Proven by SNIP-36 (the prover service finalized it in 0xf1): your settled best 1650 (won, bundle ${BUNDLE})`);
    expect(h.execute).toHaveBeenCalledTimes(1); // only the attested submit
    expect(h.text('.submit-board.settled li')).toBe(`${shortFelt(PLAYER)} 1650 · proven by SNIP-36 · bundle ${BUNDLE}`);
    expect(h.button(/^Settle/).hidden).toBe(true);
  });

  it("falls back to the settled path when the contract's chain is not the service's (409)", async () => {
    const h = setup({ proven: true, chainMismatch: true, relay: '0xre1a7', statuses: [{ relayed: true, relay: { state: 'relayed' }, relay_transaction_hash: '0x5e7' }] });
    await connectAndOffer(h);
    h.button(/^Submit$/).click();
    await flush();
    const tiers = h.requests.filter((r) => r.url.endsWith('/prove')).map((r) => (r.body as Record<string, unknown>).tier ?? 'settled');
    expect(tiers).toEqual(['proven', 'settled']);
    expect(h.text('.submit-tier')).toBe(`Settled by the relay in 0x5e7: your settled best 1650 (won, engine ${PROGRAM})`);
  });

  it('without a relay, offers Settle with the proof\'s program and settles for the player', async () => {
    const h = setup({ statuses: [{ settleable: true, settleable_poseidon: true, relay: { state: 'off' } }] });
    await connectAndOffer(h);
    h.button(/^Submit$/).click();
    await flush();
    const settle = h.button(/^Settle/);
    expect(settle.hidden).toBe(false);
    expect(settle.textContent).toBe('Settle (cheap)');
    settle.click();
    await flush();
    expect(h.execute).toHaveBeenLastCalledWith(submitSettledCall(CONTRACT, OUTPUTS(PLAYER), runArgs(LEVEL_FELTS, INPUTS(PLAYER)), PROGRAM));
    expect(h.text('.submit-tier')).toMatch(/^Settled in 0x[0-9a-f]+: your settled best 1650/);
    expect(settle.hidden).toBe(true);
  });

  it('explains a refused settle in plain words (m14)', async () => {
    const h = setup({ statuses: [{ settleable: true, settleable_poseidon: true, relay: { state: 'off' } }], refuseSettle: 'submit: program' });
    await connectAndOffer(h);
    h.button(/^Submit$/).click();
    await flush();
    h.button(/^Settle/).click();
    await flush();
    expect(h.text('.submit-tier')).toContain('Settle failed: the contract no longer accepts the engine release');
  });

  it('local mode (scripts/play.sh): the devnet account connects by itself, the player picks proven', async () => {
    const done = { tier: 'proven', state: 'proven', proven: true, proofs: [{ state: 'submitted' }], finalize: { transaction_hash: '0xf1' } };
    const h = setup({ local: true, proven: true, statuses: [{ tier: 'proven', state: 'planning' }, done] });
    await flush();
    expect(h.panel.player).toBe(PLAYER); // no Connect click
    expect(h.root.querySelector('h3')!.textContent).toContain('proofs are simulated');
    h.panel.offer(LEVEL, async (player) => OUTPUTS(player), INPUTS);
    await flush();
    h.button(/^Submit$/).click();
    await flush();
    // No proof requested before the player picks its tier.
    expect(h.requests.some((r) => r.url.endsWith('/prove'))).toBe(false);
    expect(h.text('.submit-tier')).toContain('ask for a proof');
    const proven = h.button(/^Prove \(SNIP-36, simulated\)$/);
    expect(proven.disabled).toBe(false);
    proven.click();
    await flush();
    expect(h.root.querySelector<HTMLElement>('.submit-tiers')!.hidden).toBe(true);
    expect(h.requests.filter((r) => r.url.endsWith('/prove')).map((r) => r.body)).toEqual([{ level: LEVEL, inputs: INPUTS(PLAYER), tier: 'proven' }]);
    expect(h.text('.submit-tier')).toContain('simulated: the fake prover');
    await h.tick();
    expect(h.sleeps).toEqual([3_000]);
    expect(h.text('.submit-tier')).toBe(`Proven by SNIP-36 (the prover service finalized it in 0xf1): your settled best 1650 (won, bundle ${BUNDLE})`);
  });

  it('local mode: the settled tier on request, the fact on the FakeSatellite, settled by the relay', async () => {
    const relayed = { settleable: true, settleable_poseidon: true, relayed: true, relay: { state: 'relayed' }, relay_transaction_hash: '0x5e7' };
    const h = setup({ local: true, proven: true, relay: '0xre1a7', statuses: [{ state: 'running', relay: { state: 'waiting' } }, relayed] });
    await flush();
    h.panel.offer(LEVEL, async (player) => OUTPUTS(player), INPUTS);
    await flush();
    h.button(/^Submit$/).click();
    await flush();
    h.button(/^Settle \(Atlantic, simulated\)$/).click();
    await flush();
    expect(h.requests.filter((r) => r.url.endsWith('/prove')).map((r) => r.body)).toEqual([{ level: LEVEL, inputs: INPUTS(PLAYER) }]);
    expect(h.text('.submit-tier')).toContain("FakeSatellite");
    await h.tick();
    expect(h.text('.submit-tier')).toBe(`Settled by the relay in 0x5e7: your settled best 1650 (won, engine ${PROGRAM})`);
    expect(h.execute).toHaveBeenCalledTimes(1); // the attested submit only
  });

  it('blocks proving up front when the service\'s program is no longer valid (M6)', async () => {
    const h = setup({ programMatch: false, verifier: 2 });
    await connectAndOffer(h);
    expect(h.text('.submit-tier')).toContain('Proofs blocked');
    const prove = h.button(/Prove \(settled\)/);
    expect(prove.disabled).toBe(true);
  });
});
