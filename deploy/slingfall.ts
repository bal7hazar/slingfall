// Deploys and drives the `Slingfall` registry class with starknet.js (the client's copy,
// `client/node_modules`; `npm --prefix client ci` first). Node 24 runs this file as is.
//
//   node deploy/slingfall.ts class-hash
//   node deploy/slingfall.ts account [--with-key]                      (devnet: account #0)
//   node deploy/slingfall.ts deploy --out FILE [--network NAME] [--verifier stub|satellite]
//        [--attestation-key HEX] [--satellite HEX | --fake-satellite] [--child-hash HEX]
//   node deploy/slingfall.ts submit --config FILE --outputs FILE --signature R,S [--expect-panic MSG]
//   node deploy/slingfall.ts submit-settled --config FILE --outputs FILE --args FILE [--expect-panic MSG]
//   node deploy/slingfall.ts fake-fact --config FILE [--fact HEX] [--keccak HEX]   (devnet)
//   node deploy/slingfall.ts translate --output FILE [--satellite HEX] [--dry-run]   (Sepolia)
//   node deploy/slingfall.ts best --config FILE --player HEX --level HASH
//   node deploy/slingfall.ts leaderboard --config FILE --level HASH
//
// The RPC is `--rpc` or `$STARKNET_RPC` (default the devnet, http://127.0.0.1:5050/rpc). The
// account is `$SLINGFALL_ACCOUNT_ADDRESS` + `$SLINGFALL_PRIVATE_KEY`, or with `--devnet` the
// devnet's predeployed account #0 (`devnet_getPredeployedAccounts`, `--seed 0`).
//
// `deploy` declares the class (built with its CASM by `deploy/contract/Scarb.toml`), deploys it
// with the account as admin, sets the verifier (`--verifier`, default `stub`), the attestation key
// (when given) and the constants of `SatelliteVerifier` (`--child-hash`, default the pinned
// `c1main` of rapier2d alpha.3; the two bootloaders; the Satellite: `--satellite`, default
// Herodotus's on Sepolia, or `--fake-satellite`: declares and deploys the devnet's
// `FakeSatellite`), registers the six fixture levels (`fixtures/levels/*.felts.json`, checking
// each `LevelRegistered` hash) and writes the addresses, class hashes, level hashes, transaction
// hashes and the gas of each transaction to `--out`.
//
// `submit-settled` sends `submit_settled(outputs, args)`: `--args` is `c1main`'s argument, a JSON
// array of felts (`tracec.py args`) or a prover-service job (`{"level_hash", "inputs"}`).
// `fake-fact` registers facts on the devnet's `FakeSatellite`.
// `translate` (lot E3c) calls the Satellite's permissionless `translateFactHash(program_hash, output,
// false)`: `--output` is a JSON array of felts, Atlantic's output of the run (`tools/atlantic`,
// `atlantic.py translate` computes it and checks the keccak fact is bridged first); the Satellite
// re-derives the keccak fact and registers the Poseidon one. Prints `{transaction_hash,
// integrity_fact_hash, gas}`; `--dry-run` prints the call's size and sends nothing.
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
const FAKE_ARTIFACTS = 'deploy/contract/target/dev/slingfall_deploy_FakeSatellite';
// `docs/proving.md` "Fact formula": the pinned `c1main` (rapier2d alpha.3, local hash, proven by
// E3b), Atlantic's bootloader, Integrity's SHARP bootloader, Herodotus's Satellite on Sepolia.
const CHILD_PROGRAM_HASH = '0x674479c20ac59520857856f672b063c6896d7ef1c86d385c54bb5982c72cf99';
const ATLANTIC_BOOTLOADER_HASH = '0x288ba12915c0c7e91df572cf3ed0c9f391aa673cb247c5a208beaa50b668f09';
const SHARP_BOOTLOADER_HASH = '0x5ab580b04e3532b6b18f81cfa654a05e29dd8e2352d88df1e765a84072db07';
const SATELLITE_SEPOLIA = '0x421cd95f9ddabdd090db74c9429f257cb6bc1ccc339278d1db1de39156676e';
const LEVELS = 'fixtures/levels';
const LEVEL_REGISTERED = hash.getSelectorFromName('LevelRegistered');
const TRANSLATED_FACT_HASH_SET = hash.getSelectorFromName('TranslatedFactHashSet');

const { values: opt, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    rpc: { type: 'string', default: process.env.STARKNET_RPC ?? 'http://127.0.0.1:5050/rpc' },
    devnet: { type: 'boolean', default: false },
    'with-key': { type: 'boolean', default: false },
    network: { type: 'string', default: 'devnet' },
    'attestation-key': { type: 'string' },
    verifier: { type: 'string', default: 'stub' },
    satellite: { type: 'string', default: SATELLITE_SEPOLIA },
    'fake-satellite': { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
    'child-hash': { type: 'string', default: CHILD_PROGRAM_HASH },
    args: { type: 'string' },
    fact: { type: 'string' },
    keccak: { type: 'string' },
    out: { type: 'string' },
    config: { type: 'string' },
    output: { type: 'string' },
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
// Public Sepolia nodes answer 403 without a User-Agent.
const rpc = new RpcProvider({ nodeUrl: opt.rpc, headers: { 'User-Agent': 'slingfall/1.0' } });

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

function classFiles(artifacts = ARTIFACTS): { contract: unknown; casm: unknown } {
  try {
    return { contract: readJson(root(`${artifacts}.contract_class.json`)), casm: readJson(root(`${artifacts}.compiled_contract_class.json`)) };
  } catch {
    throw new Error(`no class artifacts: scarb --manifest-path deploy/contract/Scarb.toml build`);
  }
}

/** Declares (if needed) and deploys a class; records the gas and transaction hashes. */
async function declareAndDeploy(
  admin: Account,
  artifacts: string,
  constructorCalldata: string[],
  label: string,
  gas: Record<string, TxGas>,
  txs: Record<string, string>,
): Promise<{ classHash: string; address: string }> {
  const { contract, casm } = classFiles(artifacts);
  const declared = await admin.declareIfNot({ contract: contract as never, casm: casm as never });
  const classHash = feltHex(declared.class_hash);
  if (declared.transaction_hash) {
    gas[`declare ${label}`] = receiptGas(await receipt(declared.transaction_hash));
    txs[`declare ${label}`] = declared.transaction_hash;
    log(gasLine(`declared ${label} ${classHash}`, gas[`declare ${label}`]));
  } else {
    log(`class ${label} ${classHash} already declared`);
  }
  const deployed = await admin.deployContract({ classHash, constructorCalldata, unique: false, salt: '0x0' });
  const address = feltHex(deployed.contract_address);
  gas[`deploy ${label}`] = receiptGas(await receipt(deployed.transaction_hash));
  txs[`deploy ${label}`] = deployed.transaction_hash;
  log(gasLine(`deployed ${label} ${address}`, gas[`deploy ${label}`]));
  return { classHash, address };
}

async function cmdDeploy(): Promise<void> {
  const out = need('out');
  const verifier = opt.verifier as keyof typeof VERIFIER;
  if (verifier !== 'stub' && verifier !== 'satellite') throw new Error(`--verifier: stub or satellite, not ${opt.verifier}`);
  const attestationKey = opt['attestation-key'] ? feltHex(opt['attestation-key']) : null;
  if (verifier === 'stub' && attestationKey === null) throw new Error('--attestation-key is required with --verifier stub');
  const admin = await account();
  const gas: Record<string, TxGas> = {};
  const txs: Record<string, string> = {};

  const { classHash, address } = await declareAndDeploy(admin, ARTIFACTS, [admin.address], 'Slingfall', gas, txs);
  let satellite = feltHex(need('satellite'));
  let fakeClassHash: string | null = null;
  if (opt['fake-satellite']) {
    const fake = await declareAndDeploy(admin, FAKE_ARTIFACTS, [admin.address], 'FakeSatellite', gas, txs);
    satellite = fake.address;
    fakeClassHash = fake.classHash;
  }
  const satelliteConfig = {
    child_program_hash: feltHex(need('child-hash')),
    atlantic_bootloader_hash: ATLANTIC_BOOTLOADER_HASH,
    sharp_bootloader_hash: SHARP_BOOTLOADER_HASH,
    satellite_address: satellite,
  };

  const configure: Call[] = [
    { contractAddress: address, entrypoint: 'set_verifier', calldata: [String(VERIFIER[verifier])] },
    { contractAddress: address, entrypoint: 'set_satellite_config', calldata: Object.values(satelliteConfig) },
  ];
  if (attestationKey !== null) configure.push({ contractAddress: address, entrypoint: 'set_attestation_key', calldata: [attestationKey] });
  const configured = await admin.execute(configure);
  gas.configure = receiptGas(await receipt(configured.transaction_hash));
  txs.configure = configured.transaction_hash;
  log(gasLine(`verifier = ${verifier}, satellite ${satellite}${attestationKey ? ', attestation key' : ''} set`, gas.configure));

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
    txs[`register_level ${level.name}`] = tx.transaction_hash;
    log(gasLine(`registered ${level.name} ${level.levelHash}`, gas[`register_level ${level.name}`]));
  }

  const doc = {
    network: opt.network,
    rpc_url: opt.network === 'devnet' ? opt.rpc : undefined,
    chain_id: await rpc.getChainId(),
    class_hash: classHash,
    address,
    admin: feltHex(admin.address),
    verifier: verifier === 'stub' ? 'Stub' : 'Satellite',
    attestation_key: attestationKey,
    satellite: satelliteConfig,
    fake_satellite_class_hash: fakeClassHash,
    levels: registered,
    transactions: txs,
    gas,
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 2)}\n`);
  log(`wrote ${out}`);
}

/** `--args`: a JSON array of felts, or a prover-service job (`level_hash`, `inputs`). */
function runArgs(path: string): string[] {
  const doc = readJson(path);
  if (Array.isArray(doc)) return doc.map(feltHex);
  const level = levels().find((l) => BigInt(l.levelHash) === BigInt(doc.level_hash));
  if (!level) throw new Error(`--args: level ${doc.level_hash} is not a fixture level`);
  return [feltHex(level.felts.length), ...level.felts.map(feltHex), feltHex(doc.inputs.length), ...doc.inputs.map(feltHex)];
}

/** Sends a submission, handles `--expect-panic`, prints the receipt's `LevelValidated` and gas. */
async function sendSubmission(label: string, send: () => Promise<string>, contractAddress: string): Promise<void> {
  const expected = opt['expect-panic'];
  let transactionHash: string;
  try {
    transactionHash = await send();
  } catch (e) {
    // The fee estimate of a reverting submission fails before anything is sent.
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
    throw new Error(`${label} reverted: ${r.revert_reason}`);
  }
  if (expected) throw new Error(`${label} was accepted, expected '${expected}' (${transactionHash})`);
  const validated = levelValidatedEvents(r, contractAddress);
  const gas = receiptGas(r);
  log(gasLine(`${label} ${transactionHash}`, gas));
  console.log(JSON.stringify({ transaction_hash: transactionHash, level_validated: validated, gas }, null, 2));
  if (validated.length !== 1) throw new Error(`${label} ${transactionHash}: ${validated.length} LevelValidated events`);
}

function readOutputs(): string[] {
  const outputsDoc = readJson(need('outputs'));
  return (Array.isArray(outputsDoc) ? outputsDoc : outputsDoc.outputs).map(feltHex);
}

async function cmdSubmitSettled(): Promise<void> {
  const config = readJson(need('config')) as { address: string };
  const outputs = readOutputs();
  const args = runArgs(need('args'));
  const player = await account();
  const contract = new SlingfallContract(config.address, rpc);
  await sendSubmission('submit_settled', () => contract.submitSettled(player, outputs, args), config.address);
}

async function cmdFakeFact(): Promise<void> {
  const config = readJson(need('config')) as { satellite: { satellite_address: string } };
  const satellite = config.satellite.satellite_address;
  const calls: Call[] = [];
  if (opt.fact) calls.push({ contractAddress: satellite, entrypoint: 'register', calldata: [feltHex(opt.fact)] });
  if (opt.keccak) {
    const k = BigInt(opt.keccak);
    calls.push({ contractAddress: satellite, entrypoint: 'register_keccak', calldata: [feltHex(k & ((1n << 128n) - 1n)), feltHex(k >> 128n)] });
  }
  if (calls.length === 0) throw new Error('fake-fact: --fact and / or --keccak');
  const admin = await account();
  const tx = await admin.execute(calls);
  await receipt(tx.transaction_hash);
  log(`fake satellite ${satellite}: registered ${[opt.fact, opt.keccak && `keccak ${opt.keccak}`].filter(Boolean).join(', ')}`);
}

/** `translateFactHash(program_hash, output, is_mocked = false)` of Herodotus's Satellite. */
function translateCall(satellite: string, output: readonly string[]): Call {
  return {
    contractAddress: satellite,
    entrypoint: 'translateFactHash',
    calldata: [ATLANTIC_BOOTLOADER_HASH, feltHex(output.length), ...output, '0x0'],
  };
}

async function cmdTranslate(): Promise<void> {
  const output = (readJson(need('output')) as (string | number)[]).map(feltHex);
  const satellite = feltHex(need('satellite'));
  const call = translateCall(satellite, output);
  if (opt['dry-run']) {
    console.log(JSON.stringify({ entrypoint: call.entrypoint, satellite, calldata_felts: (call.calldata as string[]).length }));
    return;
  }
  const sender = await account();
  const tx = await sender.execute(call);
  const r = await receipt(tx.transaction_hash);
  const event = (r.events ?? []).find(
    (e) => BigInt(e.from_address ?? satellite) === BigInt(satellite) && BigInt(e.keys[0]) === BigInt(TRANSLATED_FACT_HASH_SET),
  );
  if (!event) throw new Error(`translateFactHash ${tx.transaction_hash}: no TranslatedFactHashSet event`);
  // data: keccak_fact_hash (u256: low, high), integrity_fact_hash, is_mocked
  const gas = receiptGas(r);
  log(gasLine(`translateFactHash ${tx.transaction_hash}`, gas));
  console.log(JSON.stringify({ transaction_hash: tx.transaction_hash, integrity_fact_hash: feltHex(event.data[2]), gas }, null, 2));
}

async function cmdSubmit(): Promise<void> {
  const config = readJson(need('config')) as { address: string };
  const outputs = readOutputs();
  const signature = need('signature').split(',').map(feltHex);
  const player = await account();
  const contract = new SlingfallContract(config.address, rpc);
  await sendSubmission('submit', () => contract.submit(player, outputs, signature), config.address);
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
    case 'submit-settled':
      return cmdSubmitSettled();
    case 'fake-fact':
      return cmdFakeFact();
    case 'translate':
      return cmdTranslate();
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
      throw new Error('usage: node deploy/slingfall.ts class-hash | account | deploy | submit | submit-settled | fake-fact | translate | best | leaderboard (see the header)');
  }
}

main().catch((e) => {
  console.error(`slingfall: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
});
