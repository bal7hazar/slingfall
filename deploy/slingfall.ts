// Deploys and drives the `Slingfall` registry class (contract v3, docs/contract-v3.md; v2,
// docs/contract-v2.md, for its upgrade) with starknet.js (the client's copy, `client/node_modules`;
// `npm --prefix client ci` first). Node 24 runs this file as is.
//
//   node deploy/slingfall.ts class-hash [--artifacts PREFIX]
//   node deploy/slingfall.ts account [--with-key] [--index N]              (devnet: account #N, default 0)
//   node deploy/slingfall.ts deploy --out FILE [--network NAME] [--verifier stub|satellite]
//        [--attestation-key HEX] [--satellite HEX | --fake-satellite] [--child-hash HEX] [--artifacts PREFIX]
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
//   node deploy/slingfall.ts snapshot --config FILE [--players HEX,...]
//   node deploy/slingfall.ts devnet-time --advance S                                  (devnet)
//   node deploy/slingfall.ts devnet-blocks --count N                                  (devnet)
// The proven tier (contract v3, SNIP-36; docs/contract-v3.md "Wiring"):
//   node deploy/slingfall.ts deploy-split --out FILE [--salt HEX]
//   node deploy/slingfall.ts set-chunk-marker --config FILE [--marker HEX]
//   node deploy/slingfall.ts pin-virtual-os --config FILE --program HEX [--grace S]
//   node deploy/slingfall.ts revoke-virtual-os --config FILE --program HEX
//   node deploy/slingfall.ts pin-chain --config FILE --split FILE [--grace S]
//   node deploy/slingfall.ts revoke-chain --config FILE --chain HEX
//   node deploy/slingfall.ts chain --config FILE [--chain HEX]
//   node deploy/slingfall.ts submit-proof --config FILE --proof FILE [--expect-panic MSG]
//   node deploy/slingfall.ts finalize --config FILE --chain HEX --level HASH --inputs FILE --outputs FILE [--expect-panic MSG]
//   node deploy/slingfall.ts sign-virtual --calls FILE --block N
//
// The RPC is `--rpc` or `$STARKNET_RPC` (default the devnet, http://127.0.0.1:5050/rpc). The
// account is `$SLINGFALL_ACCOUNT_ADDRESS` + `$SLINGFALL_PRIVATE_KEY`, or with `--devnet` the
// devnet's predeployed account `--index` (default #0, `devnet_getPredeployedAccounts`, `--seed 0`).
// The contract is `--config`'s `address`, or `--address`.
//
// `deploy` declares the class (built with its CASM by `deploy/contract/Scarb.toml`), deploys it
// with the account as admin and configures a fresh deployment's two first tiers in one transaction
// (v3's proven tier stays closed until `set-chunk-marker`, `pin-virtual-os` and `pin-chain`):
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
// `devnet-time --advance S` moves the devnet's block time forward (`devnet_increaseTime`);
// `devnet-blocks --count N` closes N empty blocks (`devnet_createBlock`: a proof's base block must
// be 10 blocks old). `snapshot` reads every value a deployment holds (admin, keys, verifier,
// programs, Satellite, expiry, each fixture level's registration, both records and both boards of
// `--players`, and the tier of each record's attempt): `deploy/e2e.sh` compares it across `upgrade`.
// `--artifacts` names another build of the class (`<dir>/slingfall_deploy_Slingfall`, the v2 build
// of `deploy/v2.sh`); `contract_version` is 3 when its ABI has `submit_chunk`, else 2.
//
// The proven tier. `deploy-split` declares layout (e)'s classes (`target/dev/slingfall_split_*`,
// `scarb build -p slingfall_split`; their hashes are the crate's pins, `deploy/split.ts`), checks that
// `SplitChain` has no entry point but `init`, `step_chunk`, `outputs`, deploys it over its five
// classes (`raw = true`), reads the deployment back and writes `--out`: the chain, its classes and
// its bundle hash (Poseidon of the ordered class hashes, `SPLIT_BUNDLE_CLASSES`). `pin-chain`
// re-reads the chain on-chain (class, storage), recomputes and prints the bundle hash and sends
// `pin_chain(chain, bundle, grace)`; `set-chunk-marker` (default 'SLINGFALL'), `pin-virtual-os`,
// `revoke-virtual-os`, `revoke-chain` are the other admin calls; `chain` reads the chain set.
// `submit-proof` sends one real Invoke per proof: `submit_chunk(chain, kind, payload)` for each of
// its messages, the proof and its facts attached (`--proof`: `{chain, messages: [{kind, payload}],
// proof_facts, proof}`, `services/prove/snip36.py`). `finalize` sends `finalize(chain, level_hash,
// inputs, outputs)` (any account: the relay). `sign-virtual` prints the signed virtual Invoke of
// `--calls` (a JSON array of `{contractAddress, entrypoint, calldata}`) at base block `--block`, the
// transaction `starknet_proveTransaction` takes.
// `SlingfallSim` is not declared: over the CASM limit (docs/DESIGN.md D11), `simulate` is unused
// on the attested path.
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { Account, RpcProvider, hash, type Call } from '../client/node_modules/starknet/dist/index.mjs';
import {
  ATTEMPT,
  CHUNK_MARKER,
  SlingfallContract,
  VERIFIER,
  adminCalls,
  expireCall,
  feltHex,
  finalizeCall,
  levelValidatedEvents,
  mentionsPanic,
  readBoards,
  receiptGas,
  registerLevelCall,
  submitChunkCall,
  submitSettledCall,
  type TxGas,
} from '../client/src/chain/slingfall.ts';
import type { Receipt } from '../client/src/chain/submission.ts';
import { SPLIT_ARTIFACTS, bundleOf, checkChainEntryPoints, pinnedHashes, verifyChain, virtualInvoke } from './split.ts';

const root = (path: string) => fileURLToPath(new URL(`../${path}`, import.meta.url));
const ARTIFACTS = 'deploy/contract/target/dev/slingfall_deploy_Slingfall';
const FAKE_ARTIFACTS = 'deploy/contract/target/dev/slingfall_deploy_FakeSatellite';
// `docs/proving.md` "Program hash history": the pinned `c1main` (rapier2d alpha.6, lot B4; unchanged by alpha.7, lot B5,
// and alpha.8, lot B6: `fixtures/proofs/atlantic/child-hash-alpha8.json`), Atlantic's bootloader, Integrity's SHARP
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
const CHAIN_PINNED = hash.getSelectorFromName('ChainPinned');
const VIRTUAL_OS_PINNED = hash.getSelectorFromName('VirtualOsPinned');

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
    artifacts: { type: 'string' },
    players: { type: 'string' },
    count: { type: 'string' },
    salt: { type: 'string' },
    split: { type: 'string' },
    chain: { type: 'string' },
    marker: { type: 'string' },
    program: { type: 'string' },
    proof: { type: 'string' },
    inputs: { type: 'string' },
    calls: { type: 'string' },
    block: { type: 'string' },
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
// starknet.js polls a receipt every 5 s: a local devnet answers at once (the e2e's minutes).
const LOCAL = /\/\/(127\.0\.0\.1|localhost)[:/]/.test(opt.rpc!);
const waitOptions = { retryInterval: LOCAL ? 100 : 5000 };
// No tip on a devnet (starknet.js would scan recent blocks for one).
const txDetails = LOCAL ? { tip: 0n } : {};

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

/** An `Account` whose transactions carry `txDetails` (no tip scan on a devnet). */
class CliAccount extends Account {
  override execute(calls: Parameters<Account['execute']>[0], details: Parameters<Account['execute']>[1] = {}) {
    return super.execute(calls, { ...txDetails, ...details });
  }

  override declare(payload: Parameters<Account['declare']>[0], details: Parameters<Account['declare']>[1] = {}) {
    return super.declare(payload, { ...txDetails, ...details });
  }

  override deployContract(payload: Parameters<Account['deployContract']>[0], details: Parameters<Account['deployContract']>[1] = {}) {
    return super.deployContract(payload, { ...txDetails, ...details });
  }
}

/** The account's address and key: `--devnet`'s predeployed account, else the environment. */
async function accountKeys(): Promise<{ address: string; key: string }> {
  let address = process.env.SLINGFALL_ACCOUNT_ADDRESS;
  let key = process.env.SLINGFALL_PRIVATE_KEY;
  if (opt.devnet) ({ address, private_key: key } = await devnetAccount());
  if (!address || !key) throw new Error('no account: pass --devnet or set SLINGFALL_ACCOUNT_ADDRESS and SLINGFALL_PRIVATE_KEY');
  return { address, key };
}

async function account(): Promise<Account> {
  const { address, key } = await accountKeys();
  return new CliAccount({ provider: rpc, address, signer: key });
}

/** The contract: `--address`, else `--config`'s `address`. */
function contractAddress(): string {
  return feltHex(opt.address ?? (readJson(need('config')) as { address: string }).address);
}

const contract = () => new SlingfallContract(contractAddress(), rpc);

async function receipt(transactionHash: string): Promise<Receipt> {
  const r = (await rpc.waitForTransaction(transactionHash, waitOptions)) as unknown as Receipt;
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
  const path = (suffix: string) => (artifacts.startsWith('/') ? `${artifacts}${suffix}` : root(`${artifacts}${suffix}`));
  try {
    return { contract: readJson(path('.contract_class.json')), casm: readJson(path('.compiled_contract_class.json')) };
  } catch {
    throw new Error(`no class artifacts at ${artifacts}: scarb --manifest-path deploy/contract/Scarb.toml build (scarb build -p slingfall_split for the chain)`);
  }
}

/** The registry class to deploy: `--artifacts`, else this tree's build. */
const registryArtifacts = () => opt.artifacts ?? ARTIFACTS;

/** 3 when the class has v3's `submit_chunk`, else 2. */
function contractVersion(sierra: unknown): number {
  const selector = BigInt(hash.getSelectorFromName('submit_chunk'));
  const eps = (sierra as { entry_points_by_type: { EXTERNAL: { selector: string }[] } }).entry_points_by_type.EXTERNAL;
  return eps.some((e) => BigInt(e.selector) === selector) ? 3 : 2;
}

/** Declares a class if needed; records the gas and the transaction hash. `classHash`, when known
 * (the split crate's pins), spares hashing the Sierra here: a wrong one fails the declare. */
async function declare(
  admin: Account,
  artifacts: string,
  label: string,
  gas: Record<string, TxGas>,
  txs: Record<string, string>,
  pinnedHash?: string,
): Promise<string> {
  const { contract: sierra, casm } = classFiles(artifacts);
  const known = pinnedHash ? { classHash: pinnedHash, compiledClassHash: hash.computeCompiledClassHash(casm as never) } : {};
  const declared = await admin.declareIfNot({ contract: sierra as never, casm: casm as never, ...known });
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

  const { classHash, address } = await declareAndDeploy(admin, registryArtifacts(), [admin.address], 'Slingfall', gas, txs);
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
    contract_version: contractVersion(classFiles(registryArtifacts()).contract),
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
  const gas: Record<string, TxGas> = {};
  if (opt.declare) classHash = await declare(await account(), registryArtifacts(), 'Slingfall', gas, {});
  if (classHash === null) throw new Error('upgrade: --class-hash HEX or --declare');
  const declared = gas['declare Slingfall'] ? { declare_gas: gas['declare Slingfall'] } : {};
  await adminTx('upgrade', adminCalls.upgrade(address, classHash), { class_hash: classHash, ...declared }, async () => ({
    class_hash_at: feltHex(await rpc.getClassHashAt(address)),
  }));
}

/** Every value a deployment holds (`snapshot`): compared across `upgrade` by `deploy/e2e.sh`. */
async function cmdSnapshot(): Promise<void> {
  const c = contract();
  const players = (opt.players ?? '').split(',').filter(Boolean).map(feltHex);
  const current = await c.currentProgram();
  const [admin, pendingAdmin, verifier, attestationKey, attestationEpoch, expireDelay, validUntil, satellite] = await Promise.all([
    c.admin(),
    c.pendingAdmin(),
    c.verifier(),
    c.attestationKey(),
    c.attestationEpoch(),
    c.expireDelay(),
    c.programValidUntil(current),
    c.satelliteConfig(),
  ]);
  const levelsOut: Record<string, unknown> = {};
  for (const level of levels()) {
    const [meta, data, boards] = await Promise.all([c.level(level.levelHash), c.levelData(level.levelHash), readBoards(c, level.levelHash)]);
    const records: Record<string, unknown> = {};
    for (const player of players) {
      const [best, bestSettled] = await Promise.all([c.best(player, level.levelHash), c.bestSettled(player, level.levelHash)]);
      const attempt = best.inputsHash === '0x0' ? ATTEMPT.none : await c.attempt(level.levelHash, player, best.inputsHash);
      records[player] = { best, best_settled: bestSettled, attempt };
    }
    levelsOut[level.name] = { meta, data_hash: feltHex(hash.computePoseidonHashOnElements(data.map(BigInt))), boards, records };
  }
  print({
    class_hash: feltHex(await rpc.getClassHashAt(contractAddress())),
    admin,
    pending_admin: pendingAdmin,
    verifier,
    attestation_key: attestationKey,
    attestation_epoch: attestationEpoch,
    expire_delay: expireDelay,
    program: { current, valid_until: validUntil },
    satellite,
    levels: levelsOut,
  });
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
  const r = (await rpc.waitForTransaction(transactionHash, waitOptions)) as unknown as Receipt;
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

// --------------------------------------------------------------------------- the proven tier (v3)

/** Declares layout (e)'s classes, deploys `SplitChain` over them, writes the chain and its bundle. */
async function cmdDeploySplit(): Promise<void> {
  const out = need('out');
  const pins = pinnedHashes();
  const chainClass = classFiles(`${SPLIT_ARTIFACTS}SplitChain`).contract;
  checkChainEntryPoints(chainClass as never);
  const { order } = bundleOf(pins);
  const admin = await account();
  const gas: Record<string, TxGas> = {};
  const txs: Record<string, string> = {};
  const classes: Record<string, string> = {};
  // The stage and rules classes first: the world class calls them (their order is not checked on
  // declaration, only when a transaction runs).
  for (const name of [...order.slice(1).reverse(), 'SplitChain']) {
    classes[name] = await declare(admin, `${SPLIT_ARTIFACTS}${name}`, name, gas, txs, pins[name]);
  }
  const constructor = [classes.BuildClass, classes.SettleClass, classes.WorldEditClass, classes.WorldClass, classes.OutputsClass, '0x1'];
  const salt = feltHex(opt.salt ?? '0x0');
  let chain = feltHex(hash.calculateContractAddressFromHash(salt, classes.SplitChain, constructor, 0));
  const existing = await rpc.getClassHashAt(chain).catch(() => null);
  if (existing !== null) {
    log(`SplitChain ${chain} already deployed (salt ${salt})`);
  } else {
    const deployed = await admin.deployContract({ classHash: classes.SplitChain, constructorCalldata: constructor, unique: false, salt });
    chain = feltHex(deployed.contract_address);
    gas['deploy SplitChain'] = receiptGas(await receipt(deployed.transaction_hash));
    txs['deploy SplitChain'] = deployed.transaction_hash;
    log(gasLine(`deployed SplitChain ${chain}`, gas['deploy SplitChain']));
  }
  const bundle = await verifyChain(rpc, chain, classes);
  const doc = { chain, layout: 'e', raw: true, classes, bundle_order: bundle.order, bundle_hash: bundle.bundleHash, transactions: txs, gas };
  writeFileSync(out, `${JSON.stringify(doc, null, 2)}\n`);
  log(`bundle ${bundle.bundleHash}; wrote ${out}`);
  print({ chain, bundle_hash: bundle.bundleHash });
}

/** `pin_chain(chain, bundle, grace)` for the chain of `--split`, its bundle recomputed from the chain itself. */
async function cmdPinChain(): Promise<void> {
  const split = readJson(need('split')) as { chain: string; classes: Record<string, string> };
  const address = contractAddress();
  const graceS = graceSeconds();
  const { bundleHash, classHashes, order } = await verifyChain(rpc, split.chain, split.classes);
  log(`chain ${split.chain}: bundle ${bundleHash} = poseidon(${order.join(', ')})`);
  const admin = await account();
  const tx = await admin.execute(adminCalls.pinChain(address, split.chain, bundleHash, graceS));
  const r = await receipt(tx.transaction_hash);
  const event = (r.events ?? []).find((e) => BigInt(e.keys[0]) === BigInt(CHAIN_PINNED));
  const gas = receiptGas(r);
  log(gasLine(`pin_chain ${split.chain} (grace ${graceS} s)`, gas));
  print({
    transaction_hash: tx.transaction_hash,
    chain: feltHex(split.chain),
    bundle_hash: bundleHash,
    class_hashes: classHashes,
    grace_s: graceS,
    previous: event ? feltHex(event.data[1]) : null,
    previous_valid_until: event ? BigInt(event.data[2]).toString() : null,
    gas,
  });
}

async function cmdPinVirtualOs(): Promise<void> {
  const program = feltHex(need('program'));
  const graceS = graceSeconds();
  const admin = await account();
  const tx = await admin.execute(adminCalls.pinVirtualOs(contractAddress(), program, graceS));
  const r = await receipt(tx.transaction_hash);
  const event = (r.events ?? []).find((e) => BigInt(e.keys[0]) === BigInt(VIRTUAL_OS_PINNED));
  const gas = receiptGas(r);
  log(gasLine(`pin_virtual_os ${program} (grace ${graceS} s)`, gas));
  print({ transaction_hash: tx.transaction_hash, program_hash: program, grace_s: graceS, previous: event ? feltHex(event.data[0]) : null, gas });
}

/** The chain set: the current chain (or `--chain`), its validity, bundle; the marker and the virtual OS. */
async function cmdChain(): Promise<void> {
  const c = contract();
  const current = await c.currentChain();
  const chain = opt.chain ? feltHex(opt.chain) : current;
  const [validUntil, bundle, marker, virtualOs, block] = await Promise.all([
    c.chainValidUntil(chain),
    c.chainBundle(chain),
    c.chunkMarker(),
    c.currentVirtualOs(),
    rpc.getBlock('latest'),
  ]);
  print({ current, chain, valid_until: validUntil, bundle_hash: bundle, now: block.timestamp, valid: validUntil > BigInt(block.timestamp), chunk_marker: marker, virtual_os: virtualOs });
}

interface ProofDoc {
  chain: string;
  messages: { kind: number; payload: string[] }[];
  proof_facts: string[];
  proof: string;
}

/** One real Invoke per proof: `submit_chunk` for each of its messages, the proof and its facts attached. */
async function cmdSubmitProof(): Promise<void> {
  const address = contractAddress();
  const doc = readJson(need('proof')) as ProofDoc;
  const calls = doc.messages.map((m) => submitChunkCall(address, doc.chain, m.kind, m.payload));
  const sender = await account();
  const details = { proofFacts: doc.proof_facts.map(feltHex), proof: doc.proof };
  await sendChecked(`submit_chunk x${calls.length}`, async () => (await sender.execute(calls, details as never)).transaction_hash, address, 0);
}

async function cmdFinalize(): Promise<void> {
  const address = contractAddress();
  const inputsDoc = readJson(need('inputs'));
  const inputs = (Array.isArray(inputsDoc) ? inputsDoc : inputsDoc.inputs).map(feltHex);
  const sender = await account();
  const call = finalizeCall(address, need('chain'), need('level'), inputs, readOutputs());
  await sendChecked('finalize', async () => (await sender.execute(call)).transaction_hash, address);
}

/** The signed virtual Invoke of `--calls` at base block `--block` (nonce at that block, zero prices). */
async function cmdSignVirtual(): Promise<void> {
  const calls = readJson(need('calls')) as Call[];
  const block = Number(need('block'));
  const { address, key } = await accountKeys();
  const nonce = BigInt(await rpc.getNonceForAddress(address, block));
  print(virtualInvoke(address, key, calls, nonce, await rpc.getChainId()));
}

async function main(): Promise<void> {
  switch (positionals[0]) {
    case 'class-hash': {
      const { contract: sierra } = classFiles(registryArtifacts());
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
    case 'attempt': {
      const attempt = await contract().attempt(need('level'), need('player'), need('inputs-hash'));
      const tier = Object.entries(ATTEMPT).find(([, v]) => v === attempt)?.[0] ?? 'unknown';
      print({ attempt, tier });
      return;
    }
    case 'program':
      return cmdProgram();
    case 'snapshot':
      return cmdSnapshot();
    case 'devnet-time': {
      const seconds = Number(need('advance'));
      print(await devnetCall('devnet_increaseTime', { time: seconds }));
      return;
    }
    case 'devnet-blocks': {
      const count = Number(need('count'));
      for (let i = 0; i < count; i++) await devnetCall('devnet_createBlock', {});
      print({ created: count, block_number: (await rpc.getBlock('latest')).block_number });
      return;
    }
    case 'deploy-split':
      return cmdDeploySplit();
    case 'set-chunk-marker': {
      const marker = feltHex(opt.marker ?? CHUNK_MARKER);
      await adminTx('set_chunk_marker', adminCalls.setChunkMarker(contractAddress(), marker), { chunk_marker: marker });
      return;
    }
    case 'pin-virtual-os':
      return cmdPinVirtualOs();
    case 'revoke-virtual-os': {
      const program = feltHex(need('program'));
      await adminTx('revoke_virtual_os', adminCalls.revokeVirtualOs(contractAddress(), program), { program_hash: program });
      return;
    }
    case 'pin-chain':
      return cmdPinChain();
    case 'revoke-chain': {
      const chain = feltHex(need('chain'));
      await adminTx('revoke_chain', adminCalls.revokeChain(contractAddress(), chain), { chain });
      return;
    }
    case 'chain':
      return cmdChain();
    case 'submit-proof':
      return cmdSubmitProof();
    case 'finalize':
      return cmdFinalize();
    case 'sign-virtual':
      return cmdSignVirtual();
    default:
      throw new Error(
        'usage: node deploy/slingfall.ts class-hash | account | deploy | pin-program | revoke-program | set-attestation-key | set-satellite | ' +
          'set-admin | accept-admin | upgrade | set-expire-delay | submit | submit-settled | expire | fake-fact | translate | best | ' +
          'leaderboard | boards | attempt | program | snapshot | devnet-time | devnet-blocks | deploy-split | set-chunk-marker | ' +
          'pin-virtual-os | revoke-virtual-os | pin-chain | revoke-chain | chain | submit-proof | finalize | sign-virtual (see the header)',
      );
  }
}

main().catch((e) => {
  console.error(`slingfall: ${e instanceof Error ? e.message : e}`);
  process.exit(1);
});
