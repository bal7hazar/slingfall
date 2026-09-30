// Headless check of `scripts/play.sh up` (lot L1, CI job `play-local`): the calls the page makes, with
// the page's own modules (client/src/chain), through the dev server's proxy, as the local player
// (devnet account #1). Node 24 runs it as is:
//
//   node scripts/play/check.ts [--url http://127.0.0.1:5173]
//
// 1. provisional: the pile10 reference shot, attested (`POST /attest-service/attest`, the service
//    re-executes it) and submitted by the player; then the proven tier (`POST /prove-service/prove`
//    `tier: proven`: the fake SNIP-36 prover, the service finalizes for the player);
// 2. provisional, then settled: a bridge shot, the settled tier (fake Atlantic, FakeSatellite,
//    the service's relay sends `submit_settled` for the player);
// 3. both boards of both levels: the player's rows, `proven by SNIP-36` and `settled by SHARP`.
// The shots' outputs come from `deploy/outputs.py` (`scarb execute` of the replay, the same Cairo as the
// page's VM). An attempt already recorded (a second run on a saved devnet state) is not sent again.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { Account, RpcProvider } from '../../client/node_modules/starknet/dist/index.mjs';
import { requestAttestation } from '../../client/src/chain/attest.ts';
import { chainConfig } from '../../client/src/chain/config.ts';
import { requestProof, waitRelayed, waitSettleable, describeJob, type Tier } from '../../client/src/chain/prove.ts';
import { ATTEMPT, SlingfallContract, describeProof, readBoards } from '../../client/src/chain/slingfall.ts';
import { submitLevel, type Receipt } from '../../client/src/chain/submission.ts';

const ROOT = new URL('../../', import.meta.url).pathname;
const PLAY = join(ROOT, 'target/play');
const { values: opt } = parseArgs({ options: { url: { type: 'string', default: `http://127.0.0.1:${process.env.PLAY_PORT ?? 5173}` } } });
const started = Date.now();
const log = (text: string) => console.error(`check: [${((Date.now() - started) / 1000).toFixed(0)} s] ${text}`);

const devnet = JSON.parse(readFileSync(join(PLAY, 'devnet.json'), 'utf8'));
const [, player, key] = readFileSync(join(PLAY, 'accounts.txt'), 'utf8').split('\n')[0].split(' ');
// The page's configuration as `scripts/play.sh` gives it (paths on the dev server's origin).
const config = chainConfig({
  VITE_PLAY_LOCAL: '1', VITE_NETWORK: 'devnet', VITE_SLINGFALL_ADDRESS: devnet.address,
  VITE_STARKNET_RPC_URL: `${opt.url}/rpc`, VITE_ATTEST_URL: `${opt.url}/attest-service`, VITE_PROVE_URL: `${opt.url}/prove-service`,
  VITE_DEVNET_ACCOUNT_ADDRESS: player, VITE_DEVNET_PRIVATE_KEY: key,
})!;
// One retry of a request whose kept-alive socket the dev server closed as it was reused (seen once:
// Node's `fetch failed` after an idle pause; a browser retries these itself).
const retrying: typeof fetch = (input, init) => fetch(input, init).catch(async (e) => {
  if (!(e instanceof TypeError)) throw e;
  log(`retrying a request (${e.message})`);
  return fetch(input, init);
});
const rpc = new RpcProvider({ nodeUrl: config.rpcUrl, baseFetch: retrying });
const contract = new SlingfallContract(config.address, rpc);
const account = new Account({ provider: rpc, address: player, signer: key });
const poll = { intervalMs: 3_000, fetchFn: retrying };

/** A golden shot replayed for the player: `{level, inputs, outputs}` (deploy/outputs.py). */
function shot(name: string): { level: string; inputs: string[]; outputs: string[] } {
  const out = join(mkdtempSync(join(tmpdir(), 'play-check-')), `${name}.json`);
  execFileSync('python3', [join(ROOT, 'deploy/outputs.py'), '--case', name, '--player', player, '--out', out, '--no-build'], { stdio: ['ignore', 'ignore', 'inherit'] });
  return JSON.parse(readFileSync(out, 'utf8'));
}

async function provisional(name: string): Promise<{ levelHash: string; inputs: string[]; outputs: string[] }> {
  const run = shot(name);
  const levelHash = run.outputs[1];
  if ((await contract.attempt(levelHash, player, run.outputs[4])) !== ATTEMPT.none) {
    log(`${name}: already recorded on this devnet (a saved state), not sent again`);
    return { levelHash, ...run };
  }
  const result = await submitLevel({
    contract,
    account,
    outputsFor: async () => run.outputs,
    attest: (outputs) => requestAttestation(config.attestUrl, config.address, { outputs, level: levelHash, inputs: run.inputs }, retrying),
    waitForReceipt: async (hash) => (await rpc.waitForTransaction(hash)) as unknown as Receipt,
  });
  if (result.validated.settled || !result.boards.provisional.some((r) => BigInt(r.player) === BigInt(player))) {
    throw new Error(`${name}: no provisional record: ${JSON.stringify(result.validated)}`);
  }
  log(`${name}: provisional record in ${result.transactionHash}, score ${result.best.score} (L2 gas ${result.gas.l2Gas.toLocaleString()})`);
  return { levelHash, ...run };
}

/** Waits, bounded, for the receipt of a transaction the service sent (nothing to wait for without a hash). */
async function included(name: string, what: string, hash: string | null | undefined, timeoutMs = 120_000): Promise<void> {
  if (!hash) return;
  log(`${name}: waiting for the ${what} transaction ${hash}`);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${name}: the ${what} transaction ${hash} has no receipt after ${timeoutMs / 1000} s`)), timeoutMs);
  });
  try {
    await Promise.race([rpc.waitForTransaction(hash, { retryInterval: poll.intervalMs }), timeout]);
  } catch (e) {
    await diagnose(hash);
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

/** What the dev server's proxy and the devnet itself answer for a transaction that has no receipt (CI log). */
async function diagnose(hash: string): Promise<void> {
  for (const file of ['prove.log', `devnet-${process.env.PLAY_DEVNET_PORT ?? 5050}.log`]) {
    try {
      const tail = readFileSync(join(PLAY, file), 'utf8').replace(/\x1b\[[0-9;]*m/g, '').split('\n').filter(Boolean).slice(-40);
      log(`diagnose tail of ${file}:\n${tail.join('\n')}`);
    } catch (e) {
      log(`diagnose ${file}: ${e}`);
    }
  }
  const devnetUrl = `http://127.0.0.1:${process.env.PLAY_DEVNET_PORT ?? 5050}/rpc`;
  for (const [label, url] of [['proxy', config.rpcUrl], ['devnet', devnetUrl]] as const) {
    for (const [method, params] of [['starknet_blockNumber', {}], ['starknet_getTransactionStatus', { transaction_hash: hash }], ['starknet_getTransactionReceipt', { transaction_hash: hash }]] as const) {
      try {
        const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
        log(`diagnose ${label} ${method}: ${(await res.text()).slice(0, 600)}`);
      } catch (e) {
        log(`diagnose ${label} ${method}: ${e}`);
      }
    }
  }
}

async function prove(name: string, attempt: { levelHash: string; inputs: string[]; outputs: string[] }, tier: Tier): Promise<void> {
  const want = tier === 'proven' ? ATTEMPT.proven : ATTEMPT.settled;
  if ((await contract.attempt(attempt.levelHash, player, attempt.outputs[4])) === want) {
    log(`${name}: already ${tier} on this devnet`);
    return;
  }
  const url = config.proveUrl!;
  const job = await requestProof(url, attempt.levelHash, attempt.inputs, retrying, tier);
  log(`${name}: ${tier} requested, job ${job.id}`);
  let last = '';
  const show = (j: { state: string }) => {
    const text = describeJob(j as Parameters<typeof describeJob>[0]);
    if (text !== last) log(`${name}: ${(last = text)}`);
  };
  let done = await waitSettleable(url, job.id, show, poll);
  if (done && tier === 'settled' && !done.relayed && done.relayState === 'waiting') done = await waitRelayed(url, job.id, show, poll);
  // `proven` is reported when the job holds the finalize hash, not when the transaction is included
  // (CI run 36732025089): wait for the receipts of the transactions that write the tier, then read.
  if (done) {
    await included(name, 'finalize', done.finalizeTransactionHash);
    if (tier === 'settled') await included(name, 'relay settle', done.relayTransactionHash);
  }
  const got = await contract.attempt(attempt.levelHash, player, attempt.outputs[4]);
  if (got !== want) throw new Error(`${name}: attempt() = ${got} after the ${tier} job (${JSON.stringify(done)})`);
  log(`${name}: ${tier} (attempt() = ${got})`);
}

const pile10 = await provisional('pile10-reference');
await prove('pile10-reference', pile10, 'proven');
const bridge = await provisional('bridge-reference');
await prove('bridge-reference', bridge, 'settled');

for (const [name, attempt, proof] of [['pile10', pile10, 'snip36'], ['bridge', bridge, 'sharp']] as const) {
  const boards = await readBoards(contract, attempt.levelHash);
  const mine = (rows: typeof boards.settled) => rows.filter((r) => BigInt(r.player) === BigInt(player));
  const [settled] = mine(boards.settled);
  if (!settled || settled.proof !== proof || mine(boards.provisional).length !== 1) {
    throw new Error(`${name}: boards ${JSON.stringify(boards)}`);
  }
  log(`${name}: settled board ${settled.score} · ${describeProof(settled)}; live board ${mine(boards.provisional).map((r) => `${r.score} · ${describeProof(r)}`).join(', ')}`);
}
log('OK: provisional, proven and settled, both boards');
