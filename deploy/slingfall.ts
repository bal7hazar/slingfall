// Deploys and drives the `Slingfall` registry class with starknet.js (the client's copy,
// `client/node_modules`; `npm --prefix client ci` first). Node 24 runs this file as is.
//
//   node deploy/slingfall.ts class-hash
//   node deploy/slingfall.ts account [--with-key]                      (devnet: account #0)
//   node deploy/slingfall.ts deploy --attestation-key HEX --out FILE [--network NAME]
//   node deploy/slingfall.ts submit --config FILE --outputs FILE --signature R,S [--expect-panic MSG]
//   node deploy/slingfall.ts best --config FILE --player HEX --level HASH
//   node deploy/slingfall.ts leaderboard --config FILE --level HASH
//
// The RPC is `--rpc` or `$STARKNET_RPC` (default the devnet, http://127.0.0.1:5050/rpc). The
// account is `$SLINGFALL_ACCOUNT_ADDRESS` + `$SLINGFALL_PRIVATE_KEY`, or with `--devnet` the
// devnet's predeployed account #0 (`devnet_getPredeployedAccounts`, `--seed 0`).
//
// `deploy` declares the class (built with its CASM by `deploy/contract/Scarb.toml`), deploys it
// with the account as admin, sets `verifier = Stub` and the attestation key, registers the six
// fixture levels (`fixtures/levels/*.felts.json`, checking each `LevelRegistered` hash) and writes
// the addresses, class hash, level hashes and the gas of each transaction to `--out`.
// `SlingfallSim` is not declared: over the CASM limit (docs/DESIGN.md D11), `simulate` is unused
// on the Stub path.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { Account, RpcProvider, hash, type Call } from '../client/node_modules/starknet/dist/index.mjs';
import {
  SlingfallContract,
  VERIFIER,
  feltHex,
  levelValidatedEvents,
  mentionsPanic,
  receiptGas,
  registerLevelCall,
  type TxGas,
} from '../client/src/chain/slingfall.ts';
import type { Receipt } from '../client/src/chain/submission.ts';

const root = (path: string) => fileURLToPath(new URL(`../${path}`, import.meta.url));
const ARTIFACTS = 'deploy/contract/target/dev/slingfall_deploy_Slingfall';
const LEVELS = 'fixtures/levels';
const LEVEL_REGISTERED = hash.getSelectorFromName('LevelRegistered');

const { values: opt, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    rpc: { type: 'string', default: process.env.STARKNET_RPC ?? 'http://127.0.0.1:5050/rpc' },
    devnet: { type: 'boolean', default: false },
    'with-key': { type: 'boolean', default: false },
    network: { type: 'string', default: 'devnet' },
    'attestation-key': { type: 'string' },
    out: { type: 'string' },
    config: { type: 'string' },
    outputs: { type: 'string' },
    signature: { type: 'string' },
    'expect-panic': { type: 'string' },
    player: { type: 'string' },
    level: { type: 'string' },
  },
});

function need(name: keyof typeof opt): string {
  const value = opt[name];
  if (typeof value !== 'string' || value === '') throw new Error(`--${name} is required`);
  return value;
}

const readJson = (path: string) => JSON.parse(readFileSync(path, 'utf8'));
const log = (text: string) => console.error(text);
const rpc = new RpcProvider({ nodeUrl: opt.rpc });

async function devnetAccount0(): Promise<{ address: string; private_key: string }> {
  const response = await fetch(opt.rpc!, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'devnet_getPredeployedAccounts', params: {} }),
  });
  const body = (await response.json()) as { result?: { address: string; private_key: string }[]; error?: unknown };
  if (!body.result?.length) throw new Error(`devnet_getPredeployedAccounts: ${JSON.stringify(body.error ?? body)}`);
  return body.result[0];
}

async function account(): Promise<Account> {
  let address = process.env.SLINGFALL_ACCOUNT_ADDRESS;
  let key = process.env.SLINGFALL_PRIVATE_KEY;
  if (opt.devnet) ({ address, private_key: key } = await devnetAccount0());
  if (!address || !key) throw new Error('no account: pass --devnet or set SLINGFALL_ACCOUNT_ADDRESS and SLINGFALL_PRIVATE_KEY');
  return new Account({ provider: rpc, address, signer: key });
}

async function receipt(transactionHash: string): Promise<Receipt> {
  const r = (await rpc.waitForTransaction(transactionHash)) as unknown as Receipt;
  if (r.execution_status === 'REVERTED') throw new Error(`${transactionHash} reverted: ${r.revert_reason}`);
  return r;
}

const gasLine = (label: string, g: TxGas) =>
  `${label}: l2_gas ${g.l2Gas.toLocaleString('en')}, l1_data_gas ${g.l1DataGas}, l1_gas ${g.l1Gas}, fee ${g.fee} ${g.unit}`;

function levels(): { name: string; levelHash: string; felts: string[] }[] {
  return readdirSync(root(LEVELS))
    .filter((f) => f.endsWith('.felts.json'))
    .sort()
    .map((f) => {
      const doc = readJson(root(`${LEVELS}/${f}`)) as { level_hash: string; felts: string[] };
      return { name: f.slice(0, -'.felts.json'.length), levelHash: feltHex(doc.level_hash), felts: doc.felts };
    });
}

function classFiles(): { contract: unknown; casm: unknown } {
  try {
    return { contract: readJson(root(`${ARTIFACTS}.contract_class.json`)), casm: readJson(root(`${ARTIFACTS}.compiled_contract_class.json`)) };
  } catch {
    throw new Error(`no class artifacts: scarb --manifest-path deploy/contract/Scarb.toml build`);
  }
}

async function cmdDeploy(): Promise<void> {
  const attestationKey = feltHex(need('attestation-key'));
  const out = need('out');
  const admin = await account();
  const { contract, casm } = classFiles();
  const gas: Record<string, TxGas> = {};

  const declared = await admin.declareIfNot({ contract: contract as never, casm: casm as never });
  const classHash = feltHex(declared.class_hash);
  if (declared.transaction_hash) {
    gas.declare = receiptGas(await receipt(declared.transaction_hash));
    log(gasLine(`declared ${classHash}`, gas.declare));
  } else {
    log(`class ${classHash} already declared`);
  }

  const deployed = await admin.deployContract({ classHash, constructorCalldata: [admin.address], unique: false, salt: '0x0' });
  const address = feltHex(deployed.contract_address);
  gas.deploy = receiptGas(await receipt(deployed.transaction_hash));
  log(gasLine(`deployed ${address}`, gas.deploy));

  const configure: Call[] = [
    { contractAddress: address, entrypoint: 'set_verifier', calldata: [String(VERIFIER.stub)] },
    { contractAddress: address, entrypoint: 'set_attestation_key', calldata: [attestationKey] },
  ];
  const configured = await admin.execute(configure);
  gas.configure = receiptGas(await receipt(configured.transaction_hash));
  log(gasLine('verifier = Stub, attestation key set', gas.configure));

  const registered: Record<string, string> = {};
  for (const level of levels()) {
    const tx = await admin.execute(registerLevelCall(address, level.felts));
    const r = await receipt(tx.transaction_hash);
    const event = (r.events ?? []).find((e) => BigInt(e.from_address ?? address) === BigInt(address) && BigInt(e.keys[0]) === BigInt(LEVEL_REGISTERED));
    if (!event || BigInt(event.keys[1]) !== BigInt(level.levelHash)) {
      throw new Error(`register_level ${level.name}: LevelRegistered ${event?.keys[1]} != fixture ${level.levelHash}`);
    }
    registered[level.name] = level.levelHash;
    gas[`register_level ${level.name}`] = receiptGas(r);
    log(gasLine(`registered ${level.name} ${level.levelHash}`, gas[`register_level ${level.name}`]));
  }

  const doc = {
    network: opt.network,
    rpc_url: opt.rpc,
    chain_id: await rpc.getChainId(),
    class_hash: classHash,
    address,
    admin: feltHex(admin.address),
    verifier: 'Stub',
    attestation_key: attestationKey,
    levels: registered,
    gas,
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 2)}\n`);
  log(`wrote ${out}`);
}

async function cmdSubmit(): Promise<void> {
  const config = readJson(need('config')) as { address: string };
  const outputsDoc = readJson(need('outputs'));
  const outputs: string[] = (Array.isArray(outputsDoc) ? outputsDoc : outputsDoc.outputs).map(feltHex);
  const signature = need('signature').split(',').map(feltHex);
  const player = await account();
  const contract = new SlingfallContract(config.address, rpc);
  const expected = opt['expect-panic'];
  let transactionHash: string;
  try {
    transactionHash = await contract.submit(player, outputs, signature);
  } catch (e) {
    // The fee estimate of a reverting `submit` fails before anything is sent.
    if (expected && mentionsPanic(e, expected)) {
      console.log(JSON.stringify({ rejected: expected }));
      return;
    }
    throw e;
  }
  const r = (await rpc.waitForTransaction(transactionHash)) as unknown as Receipt;
  if (r.execution_status === 'REVERTED') {
    if (expected && r.revert_reason?.includes(expected)) {
      console.log(JSON.stringify({ rejected: expected, transaction_hash: transactionHash }));
      return;
    }
    throw new Error(`submit reverted: ${r.revert_reason}`);
  }
  if (expected) throw new Error(`submit was accepted, expected '${expected}' (${transactionHash})`);
  const validated = levelValidatedEvents(r, config.address);
  const gas = receiptGas(r);
  log(gasLine(`submit ${transactionHash}`, gas));
  console.log(JSON.stringify({ transaction_hash: transactionHash, level_validated: validated, gas }, null, 2));
  if (validated.length !== 1) throw new Error(`submit ${transactionHash}: ${validated.length} LevelValidated events`);
}

async function main(): Promise<void> {
  switch (positionals[0]) {
    case 'class-hash': {
      const { contract } = classFiles();
      console.log(hash.computeContractClassHash(contract as never));
      return;
    }
    case 'account': {
      const a = await devnetAccount0();
      console.log(opt['with-key'] ? JSON.stringify({ address: feltHex(a.address), private_key: a.private_key }) : feltHex(a.address));
      return;
    }
    case 'deploy':
      return cmdDeploy();
    case 'submit':
      return cmdSubmit();
    case 'best': {
      const config = readJson(need('config')) as { address: string };
      const best = await new SlingfallContract(config.address, rpc).best(need('player'), need('level'));
      console.log(JSON.stringify(best));
      return;
    }
    case 'leaderboard': {
      const config = readJson(need('config')) as { address: string };
      console.log(JSON.stringify(await new SlingfallContract(config.address, rpc).leaderboard(need('level'))));
      return;
    }
    default:
      throw new Error('usage: node deploy/slingfall.ts class-hash | account | deploy | submit | best | leaderboard (see the header)');
  }
}

main().catch((e) => {
  console.error(`slingfall: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
});
