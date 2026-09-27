// Deploys and drives the `Slingfall` registry class (contract v2, docs/contract-v2.md) with
// starknet.js (the client's copy, `client/node_modules`; `npm --prefix client ci` first). Node 24 runs
// this file as is.
//
//   node deploy/slingfall.ts class-hash
//   node deploy/slingfall.ts account [--with-key] [--index N]              (devnet: account #N, default 0)
//   node deploy/slingfall.ts deploy --out FILE [--network NAME] [--verifier stub|satellite]
//        [--attestation-key HEX] [--satellite HEX | --fake-satellite] [--child-hash HEX]
//   node deploy/slingfall.ts pin-program --config FILE --child-hash HEX [--bit-compatible | --grace S]
//   node deploy/slingfall.ts revoke-program --config FILE --child-hash HEX
//   node deploy/slingfall.ts set-attestation-key --config FILE --attestation-key HEX
//   node deploy/slingfall.ts set-satellite --config FILE [--satellite HEX]
//   node deploy/slingfall.ts set-admin --config FILE --admin HEX       node deploy/slingfall.ts accept-admin --config FILE
//   node deploy/slingfall.ts upgrade --config FILE (--class-hash HEX | --declare)
//   node deploy/slingfall.ts set-expire-delay --config FILE --seconds N
//   node deploy/slingfall.ts submit --config FILE --outputs FILE (--attestation FILE | --evidence P,E,R,S) [--expect-panic MSG]
//   node deploy/slingfall.ts submit-settled --config FILE --outputs FILE --args FILE [--child-hash HEX]
//        [--simulate] [--expect-panic MSG]
//   node deploy/slingfall.ts expire --config FILE --level HASH --player HEX [--expect-panic MSG]
//   node deploy/slingfall.ts fake-fact --config FILE [--fact HEX] [--keccak HEX]   (devnet)
//   node deploy/slingfall.ts translate --output FILE [--satellite HEX] [--dry-run]   (Sepolia)
//   node deploy/slingfall.ts best --config FILE --player HEX --level HASH [--settled]
//   node deploy/slingfall.ts leaderboard --config FILE --level HASH [--provisional]
//   node deploy/slingfall.ts boards --config FILE --level HASH
//   node deploy/slingfall.ts attempt --config FILE --level HASH --player HEX --inputs-hash HEX
//   node deploy/slingfall.ts program --config FILE [--child-hash HEX]
//   node deploy/slingfall.ts devnet-time --advance S                                  (devnet)
//
// The RPC is `--rpc` or `$STARKNET_RPC` (default the devnet, http://127.0.0.1:5050/rpc). The
// account is `$SLINGFALL_ACCOUNT_ADDRESS` + `$SLINGFALL_PRIVATE_KEY`, or with `--devnet` the
// devnet's predeployed account `--index` (default #0, `devnet_getPredeployedAccounts`, `--seed 0`).
// The contract is `--config`'s `address`, or `--address`.
//
// `deploy` declares the class (built with its CASM by `deploy/contract/Scarb.toml`), deploys it
// with the account as admin and configures a fresh v2 deployment in one transaction:
// `set_attestation_key` (when given; epoch 1), `pin_program(child, 0)` (`--child-hash`, default the
// pinned `c1main` of `docs/proving.md`), `set_satellite_config` (the two bootloaders and the
// Satellite: `--satellite`, default Herodotus's on Sepolia, or `--fake-satellite`: declares and
// deploys the devnet's `FakeSatellite`) and, with `--verifier satellite`, `set_verifier(Satellite)`
// (the attested tier closed; the constructor's `Stub` otherwise). It then registers the six
// fixture levels (`fixtures/levels/*.felts.json`, checking each `LevelRegistered` hash) and writes
// the addresses, class hashes, program, level hashes, transaction hashes and gas to `--out`.
//
// `pin-program` re-pins `c1main` (a rapier2d / `c1main` bump, docs/DESIGN.md D9):
// `pin_program(hash, grace_s)`, the previous program staying valid `grace_s` seconds. The grace is
// explicit: `--bit-compatible` (the new program gives the same outputs, research 06 §2.3) defaults
// it to 86 400 s, anything else to 0; `--grace S` sets it. `revoke-program` voids a program at once
// (an exploitable defect). `set-admin` proposes an admin, who then runs `accept-admin`. `upgrade`
// replaces the class (`--declare`: declares the built artifacts first). None of them declares or
// deploys otherwise.
// `submit` sends the attested `submit(outputs, [program_hash, expiry, r, s])`: `--attestation` is the
// attest service's answer (`attest.py request`). `submit-settled` sends `submit_settled(outputs,
// args, child_program_hash)`: `--args` is `c1main`'s argument, a JSON array of felts (`tracec.py
// args`) or a prover-service job (`{"level_hash", "inputs", "child_program_hash"?}`); the program
// is `--child-hash`, else the job's, else the contract's `current_program()`. Any account may send
// it (the record is `claim.player`'s: the relay of `services/prove`). `--simulate` only simulates
// it (`starknet_estimateFee`, which executes it unsent) and prints `{simulated: true}`, failing like the transaction would.
// `fake-fact` registers facts on the devnet's `FakeSatellite`. `translate` (lot E3c) calls the
// Satellite's permissionless `translateFactHash(program_hash, output, false)` (`--output`: Atlantic's
// output of the run, `atlantic.py translate`); prints `{transaction_hash, integrity_fact_hash, gas}`.
// `devnet-time --advance S` moves the devnet's block time forward (`devnet_increaseTime`).
// `SlingfallSim` is not declared: over the CASM limit (docs/DESIGN.md D11), `simulate` is unused
// on the attested path.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { Account, RpcProvider, hash, type Call } from '../client/node_modules/starknet/dist/index.mjs';
import {
  SlingfallContract,
  VERIFIER,
  adminCalls,
  expireCall,
  feltHex,
  levelValidatedEvents,
  mentionsPanic,
  readBoards,
  receiptGas,
  registerLevelCall,
  submitSettledCall,
  type TxGas,
} from '../client/src/chain/slingfall.ts';
import type { Receipt } from '../client/src/chain/submission.ts';

const root = (path: string) => fileURLToPath(new URL(`../${path}`, import.meta.url));
const ARTIFACTS = 'deploy/contract/target/dev/slingfall_deploy_Slingfall';
const FAKE_ARTIFACTS = 'deploy/contract/target/dev/slingfall_deploy_FakeSatellite';
// `docs/proving.md` "Program hash history": the pinned `c1main` (rapier2d alpha.6, lot B4,
// `fixtures/proofs/atlantic/child-hash-alpha6.json`), Atlantic's bootloader, Integrity's SHARP
// bootloader, Herodotus's Satellite on Sepolia.
const CHILD_PROGRAM_HASH = '0x580ef5d1896ce36ddc0309eed11218303ed39d1c30ad8ccea4d194be3edf75a';
const ATLANTIC_BOOTLOADER_HASH = '0x288ba12915c0c7e91df572cf3ed0c9f391aa673cb247c5a208beaa50b668f09';
const SHARP_BOOTLOADER_HASH = '0x5ab580b04e3532b6b18f81cfa654a05e29dd8e2352d88df1e765a84072db07';
const SATELLITE_SEPOLIA = '0x421cd95f9ddabdd090db74c9429f257cb6bc1ccc339278d1db1de39156676e';
/** research 06 §2.3: the grace of a bit-compatible re-pin (24 h); any other re-pin gets none. */
const BIT_COMPATIBLE_GRACE_S = 86_400;
const LEVELS = 'fixtures/levels';
const LEVEL_REGISTERED = hash.getSelectorFromName('LevelRegistered');
const TRANSLATED_FACT_HASH_SET = hash.getSelectorFromName('TranslatedFactHashSet');
const PROGRAM_PINNED = hash.getSelectorFromName('ProgramPinned');

const { values: opt, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    rpc: { type: 'string', default: process.env.STARKNET_RPC ?? 'http://127.0.0.1:5050/rpc' },
    devnet: { type: 'boolean', default: false },
    index: { type: 'string', default: '0' },
    'with-key': { type: 'boolean', default: false },
    network: { type: 'string', default: 'devnet' },
    'attestation-key': { type: 'string' },
    verifier: { type: 'string', default: 'stub' },
    satellite: { type: 'string' },
    'fake-satellite': { type: 'boolean', default: false },
    'dry-run': { type: 'boolean', default: false },
    'child-hash': { type: 'string' },
    'bit-compatible': { type: 'boolean', default: false },
    grace: { type: 'string' },
    admin: { type: 'string' },
    'class-hash': { type: 'string' },
    declare: { type: 'boolean', default: false },
    seconds: { type: 'string' },
    advance: { type: 'string' },
    simulate: { type: 'boolean', default: false },
    settled: { type: 'boolean', default: false },
    provisional: { type: 'boolean', default: false },
    args: { type: 'string' },
    fact: { type: 'string' },
    keccak: { type: 'string' },
    out: { type: 'string' },
    config: { type: 'string' },
    address: { type: 'string' },
    output: { type: 'string' },
    outputs: { type: 'string' },
    attestation: { type: 'string' },
    evidence: { type: 'string' },
    'expect-panic': { type: 'string' },
    player: { type: 'string' },
    level: { type: 'string' },
    'inputs-hash': { type: 'string' },
  },
});

function need(name: keyof typeof opt): string {
  const value = opt[name];
  if (typeof value !== 'string' || value === '') throw new Error(`--${name} is required`);
  return value;
}

const readJson = (path: string) => JSON.parse(readFileSync(path, 'utf8'));
const log = (text: string) => console.error(text);
const print = (value: unknown) => console.log(JSON.stringify(value, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
// Public Sepolia nodes answer 403 without a User-Agent.
const rpc = new RpcProvider({ nodeUrl: opt.rpc, headers: { 'User-Agent': 'slingfall/1.0' } });

async function devnetCall(method: string, params: unknown): Promise<unknown> {
  const response = await fetch(opt.rpc!, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const body = (await response.json()) as { result?: unknown; error?: unknown };
  if (body.error !== undefined || body.result === undefined) throw new Error(`${method}: ${JSON.stringify(body.error ?? body)}`);
  return body.result;
}

async function devnetAccount(index = Number(opt.index)): Promise<{ address: string; private_key: string }> {
  const accounts = (await devnetCall('devnet_getPredeployedAccounts', {})) as { address: string; private_key: string }[];
  if (!accounts[index]) throw new Error(`devnet: no predeployed account #${index} (${accounts.length} accounts)`);
  return accounts[index];
}

async function account(): Promise<Account> {
  let address = process.env.SLINGFALL_ACCOUNT_ADDRESS;
  let key = process.env.SLINGFALL_PRIVATE_KEY;
  if (opt.devnet) ({ address, private_key: key } = await devnetAccount());
  if (!address || !key) throw new Error('no account: pass --devnet or set SLINGFALL_ACCOUNT_ADDRESS and SLINGFALL_PRIVATE_KEY');
  return new Account({ provider: rpc, address, signer: key });
}

/** The contract: `--address`, else `--config`'s `address`. */
function contractAddress(): string {
  return feltHex(opt.address ?? (readJson(need('config')) as { address: string }).address);
}

const contract = () => new SlingfallContract(contractAddress(), rpc);

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

/** Declares a class if needed; records the gas and the transaction hash. */
async function declare(admin: Account, artifacts: string, label: string, gas: Record<string, TxGas>, txs: Record<string, string>): Promise<string> {
  const { contract: sierra, casm } = classFiles(artifacts);
  const declared = await admin.declareIfNot({ contract: sierra as never, casm: casm as never });
  const classHash = feltHex(declared.class_hash);
  if (declared.transaction_hash) {
    gas[`declare ${label}`] = receiptGas(await receipt(declared.transaction_hash));
    txs[`declare ${label}`] = declared.transaction_hash;
    log(gasLine(`declared ${label} ${classHash}`, gas[`declare ${label}`]));
  } else {
    log(`class ${label} ${classHash} already declared`);
  }
  return classHash;
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
  const classHash = await declare(admin, artifacts, label, gas, txs);
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
  const childHash = feltHex(opt['child-hash'] ?? CHILD_PROGRAM_HASH);
  const admin = await account();
  const gas: Record<string, TxGas> = {};
  const txs: Record<string, string> = {};

  const { classHash, address } = await declareAndDeploy(admin, ARTIFACTS, [admin.address], 'Slingfall', gas, txs);
  let satellite = feltHex(opt.satellite ?? SATELLITE_SEPOLIA);
  let fakeClassHash: string | null = null;
  if (opt['fake-satellite']) {
    const fake = await declareAndDeploy(admin, FAKE_ARTIFACTS, [admin.address], 'FakeSatellite', gas, txs);
    satellite = fake.address;
    fakeClassHash = fake.classHash;
  }
  const satelliteConfig = { atlantic_bootloader_hash: ATLANTIC_BOOTLOADER_HASH, sharp_bootloader_hash: SHARP_BOOTLOADER_HASH, satellite_address: satellite };

  // A fresh v2 deployment: key (epoch 1), program (no grace: nothing came before), Satellite, verifier.
  const configure: Call[] = [];
  if (attestationKey !== null) configure.push(adminCalls.setAttestationKey(address, attestationKey));
  configure.push(adminCalls.pinProgram(address, childHash, 0), adminCalls.setSatelliteConfig(address, satelliteConfig));
  if (verifier === 'satellite') configure.push(adminCalls.setVerifier(address, VERIFIER.satellite));
  const configured = await admin.execute(configure);
  gas.configure = receiptGas(await receipt(configured.transaction_hash));
  txs.configure = configured.transaction_hash;
  log(gasLine(`configured: ${attestationKey ? 'attestation key, ' : ''}program ${childHash}, satellite ${satellite}, verifier ${verifier}`, gas.configure));

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
    contract_version: 2,
    class_hash: classHash,
    address,
    admin: feltHex(admin.address),
    verifier: verifier === 'stub' ? 'Stub' : 'Satellite',
    attestation_key: attestationKey,
    program: { current: childHash, pins: [{ program_hash: childHash, grace_s: 0, transaction_hash: configured.transaction_hash }] },
    satellite: satelliteConfig,
    fake_satellite_class_hash: fakeClassHash,
    levels: registered,
    transactions: txs,
    gas,
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 2)}\n`);
  log(`wrote ${out}`);
}

/** One admin transaction; prints `{transaction_hash, ...extra, ...after(), gas}` (`after`: reads made
 * once it landed). */
async function adminTx(label: string, call: Call, extra: Record<string, unknown> = {}, after = async (): Promise<Record<string, unknown>> => ({})): Promise<void> {
  const admin = await account();
  const tx = await admin.execute(call);
  const gas = receiptGas(await receipt(tx.transaction_hash));
  log(gasLine(`${label} ${tx.transaction_hash}`, gas));
  print({ transaction_hash: tx.transaction_hash, ...extra, ...(await after()), gas });
}

/** `--grace S`, else 86 400 s with `--bit-compatible`, else 0: the grace is always a decision. */
function graceSeconds(): number {
  if (opt.grace !== undefined) return Number(opt.grace);
  return opt['bit-compatible'] ? BIT_COMPATIBLE_GRACE_S : 0;
}

async function cmdPinProgram(): Promise<void> {
  const address = contractAddress();
  const programHash = feltHex(need('child-hash'));
  const graceS = graceSeconds();
  if (!Number.isInteger(graceS) || graceS < 0) throw new Error(`--grace: a number of seconds, not ${opt.grace}`);
  const previous = await contract().currentProgram();
  const admin = await account();
  const tx = await admin.execute(adminCalls.pinProgram(address, programHash, graceS));
  const r = await receipt(tx.transaction_hash);
  const event = (r.events ?? []).find((e) => BigInt(e.keys[0]) === BigInt(PROGRAM_PINNED));
  const gas = receiptGas(r);
  log(gasLine(`pin_program ${programHash} (grace ${graceS} s, previous ${previous})`, gas));
  print({
    transaction_hash: tx.transaction_hash,
    program_hash: programHash,
    grace_s: graceS,
    previous: event ? feltHex(event.data[0]) : previous,
    previous_valid_until: event ? BigInt(event.data[1]).toString() : null,
    gas,
  });
}

async function cmdUpgrade(): Promise<void> {
  const address = contractAddress();
  let classHash = opt['class-hash'] ? feltHex(opt['class-hash']) : null;
  if (opt.declare) classHash = await declare(await account(), ARTIFACTS, 'Slingfall', {}, {});
  if (classHash === null) throw new Error('upgrade: --class-hash HEX or --declare');
  await adminTx('upgrade', adminCalls.upgrade(address, classHash), { class_hash: classHash });
}

/** `--args`: a JSON array of felts, or a prover-service job (`level_hash`, `inputs`, `child_program_hash`?). */
function runArgs(path: string): { args: string[]; childHash: string | null } {
  const doc = readJson(path);
  if (Array.isArray(doc)) return { args: doc.map(feltHex), childHash: null };
  const level = levels().find((l) => BigInt(l.levelHash) === BigInt(doc.level_hash));
  if (!level) throw new Error(`--args: level ${doc.level_hash} is not a fixture level`);
  const args = [feltHex(level.felts.length), ...level.felts.map(feltHex), feltHex(doc.inputs.length), ...doc.inputs.map(feltHex)];
  return { args, childHash: doc.child_program_hash ? feltHex(doc.child_program_hash) : null };
}

/** Sends a transaction, handles `--expect-panic`, prints the receipt's `LevelValidated` and gas. */
async function sendChecked(label: string, send: () => Promise<string>, address: string, validations: number | null = 1): Promise<void> {
  const expected = opt['expect-panic'];
  let transactionHash: string;
  try {
    transactionHash = await send();
  } catch (e) {
    // The fee estimate of a reverting transaction fails before anything is sent.
    if (expected && mentionsPanic(e, expected)) {
      print({ rejected: expected });
      return;
    }
    throw e;
  }
  const r = (await rpc.waitForTransaction(transactionHash)) as unknown as Receipt;
  if (r.execution_status === 'REVERTED') {
    if (expected && r.revert_reason?.includes(expected)) {
      print({ rejected: expected, transaction_hash: transactionHash });
      return;
    }
    throw new Error(`${label} reverted: ${r.revert_reason}`);
  }
  if (expected) throw new Error(`${label} was accepted, expected '${expected}' (${transactionHash})`);
  const validated = levelValidatedEvents(r, address);
  const gas = receiptGas(r);
  log(gasLine(`${label} ${transactionHash}`, gas));
  print({ transaction_hash: transactionHash, level_validated: validated, gas });
  if (validations !== null && validated.length !== validations) throw new Error(`${label} ${transactionHash}: ${validated.length} LevelValidated events`);
}

function readOutputs(): string[] {
  const outputsDoc = readJson(need('outputs'));
  return (Array.isArray(outputsDoc) ? outputsDoc : outputsDoc.outputs).map(feltHex);
}

async function cmdSubmit(): Promise<void> {
  const address = contractAddress();
  const outputs = readOutputs();
  const evidence = opt.attestation ? (readJson(opt.attestation) as { evidence: string[] }).evidence.map(feltHex) : need('evidence').split(',').map(feltHex);
  if (evidence.length !== 4) throw new Error(`submit: the evidence is [program_hash, expiry, r, s], got ${evidence.length} felts`);
  const player = await account();
  await sendChecked('submit', () => new SlingfallContract(address, rpc).submit(player, outputs, evidence), address);
}

async function cmdSubmitSettled(): Promise<void> {
  const address = contractAddress();
  const outputs = readOutputs();
  const { args, childHash } = runArgs(need('args'));
  const c = new SlingfallContract(address, rpc);
  const program = opt['child-hash'] ? feltHex(opt['child-hash']) : (childHash ?? (await c.currentProgram()));
  const sender = await account();
  if (opt.simulate) {
    const expected = opt['expect-panic'];
    const call = submitSettledCall(address, outputs, args, program);
    // `starknet_estimateFee` executes the transaction without sending it and fails with the
    // revert reason when it would revert (the simulation the relay needs, M6).
    let reason: string | null = null;
    try {
      await sender.estimateInvokeFee(call);
    } catch (e) {
      reason = `${e instanceof Error ? e.message : String(e)} ${String((e as { data?: unknown }).data ?? '')}`;
    }
    if (reason === null && !expected) return print({ simulated: true, child_program_hash: program });
    if (reason !== null && expected && mentionsPanic(new Error(reason), expected)) return print({ simulated: false, rejected: expected });
    throw new Error(reason === null ? `submit_settled simulation passed, expected '${expected}'` : `submit_settled simulation reverts: ${reason}`);
  }
  await sendChecked('submit_settled', () => c.submitSettled(sender, outputs, args, program), address);
}

async function cmdExpire(): Promise<void> {
  const address = contractAddress();
  const sender = await account();
  await sendChecked('expire', async () => (await sender.execute(expireCall(address, need('level'), need('player')))).transaction_hash, address, 0);
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
  const satellite = feltHex(opt.satellite ?? SATELLITE_SEPOLIA);
  const call = translateCall(satellite, output);
  if (opt['dry-run']) {
    print({ entrypoint: call.entrypoint, satellite, calldata_felts: (call.calldata as string[]).length });
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
  print({ transaction_hash: tx.transaction_hash, integrity_fact_hash: feltHex(event.data[2]), gas });
}

async function cmdProgram(): Promise<void> {
  const c = contract();
  const current = await c.currentProgram();
  const program = opt['child-hash'] ? feltHex(opt['child-hash']) : current;
  const [validUntil, block] = await Promise.all([c.programValidUntil(program), rpc.getBlock('latest')]);
  print({ current, program_hash: program, valid_until: validUntil, now: block.timestamp, valid: validUntil > BigInt(block.timestamp) });
}

async function main(): Promise<void> {
  switch (positionals[0]) {
    case 'class-hash': {
      const { contract: sierra } = classFiles();
      console.log(hash.computeContractClassHash(sierra as never));
      return;
    }
    case 'account': {
      const a = await devnetAccount();
      console.log(opt['with-key'] ? JSON.stringify({ address: feltHex(a.address), private_key: a.private_key }) : feltHex(a.address));
      return;
    }
    case 'deploy':
      return cmdDeploy();
    case 'pin-program':
      return cmdPinProgram();
    case 'revoke-program': {
      const programHash = feltHex(need('child-hash'));
      await adminTx('revoke_program', adminCalls.revokeProgram(contractAddress(), programHash), { program_hash: programHash });
      return;
    }
    case 'set-attestation-key': {
      const key = feltHex(need('attestation-key'));
      await adminTx('set_attestation_key', adminCalls.setAttestationKey(contractAddress(), key), { attestation_key: key }, async () => ({
        attestation_epoch: await contract().attestationEpoch(),
      }));
      return;
    }
    case 'set-satellite': {
      const config = readJson(need('config')) as { satellite?: { satellite_address: string } };
      const satellite = feltHex(opt.satellite ?? config.satellite?.satellite_address ?? SATELLITE_SEPOLIA);
      const satelliteConfig = { atlantic_bootloader_hash: ATLANTIC_BOOTLOADER_HASH, sharp_bootloader_hash: SHARP_BOOTLOADER_HASH, satellite_address: satellite };
      await adminTx('set_satellite_config', adminCalls.setSatelliteConfig(contractAddress(), satelliteConfig), { satellite: satelliteConfig });
      return;
    }
    case 'set-admin': {
      const admin = feltHex(need('admin'));
      await adminTx('set_admin (proposed)', adminCalls.setAdmin(contractAddress(), admin), { pending_admin: admin });
      return;
    }
    case 'accept-admin':
      await adminTx('accept_admin', adminCalls.acceptAdmin(contractAddress()));
      return;
    case 'upgrade':
      return cmdUpgrade();
    case 'set-expire-delay':
      await adminTx('set_expire_delay', adminCalls.setExpireDelay(contractAddress(), Number(need('seconds'))), { expire_delay: Number(opt.seconds) });
      return;
    case 'submit':
      return cmdSubmit();
    case 'submit-settled':
      return cmdSubmitSettled();
    case 'expire':
      return cmdExpire();
    case 'fake-fact':
      return cmdFakeFact();
    case 'translate':
      return cmdTranslate();
    case 'best': {
      const c = contract();
      print(await (opt.settled ? c.bestSettled(need('player'), need('level')) : c.best(need('player'), need('level'))));
      return;
    }
    case 'leaderboard': {
      const c = contract();
      print(await (opt.provisional ? c.leaderboardProvisional(need('level')) : c.leaderboard(need('level'))));
      return;
    }
    case 'boards':
      print(await readBoards(contract(), need('level')));
      return;
    case 'attempt':
      print({ attempt: await contract().attempt(need('level'), need('player'), need('inputs-hash')) });
      return;
    case 'program':
      return cmdProgram();
    case 'devnet-time': {
      const seconds = Number(need('advance'));
      print(await devnetCall('devnet_increaseTime', { time: seconds }));
      return;
    }
    default:
      throw new Error(
        'usage: node deploy/slingfall.ts class-hash | account | deploy | pin-program | revoke-program | set-attestation-key | set-satellite | ' +
          'set-admin | accept-admin | upgrade | set-expire-delay | submit | submit-settled | expire | fake-fact | translate | best | ' +
          'leaderboard | boards | attempt | program | devnet-time (see the header)',
      );
  }
}

main().catch((e) => {
  console.error(`slingfall: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
});
