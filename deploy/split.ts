// The SNIP-36 chain of layout (e) (`crates/slingfall_split`, docs/contract-v3.md "Wiring") as the
// deploy scripts see it: the classes and their pinned hashes, the check that `SplitChain` has no
// entry point but its three transactions, the on-chain check that a deployed chain is the bundle it
// claims, and the virtual transaction a SNIP-36 prover proves. `deploy/slingfall.ts` drives it.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { ec, hash, num, transaction, type Call } from '../client/node_modules/starknet/dist/index.mjs';
import { SPLIT_BUNDLE_CLASSES, bundleHash, feltHex } from '../client/src/chain/slingfall.ts';

const root = (path: string) => fileURLToPath(new URL(`../${path}`, import.meta.url));
/** The split crate's build (`scarb build -p slingfall_split`, root workspace). */
export const SPLIT_ARTIFACTS = 'target/dev/slingfall_split_';
const HASHES = 'crates/slingfall_split/src/hashes.cairo';
/** `SplitChain`'s constructor classes, in constructor order (its storage variables of the same names). */
export const CHAIN_STORAGE = ['build', 'settle', 'edit', 'world', 'outputs'] as const;
/** `SplitChain`'s only external entry points: the three proven transactions. */
export const CHAIN_ENTRY_POINTS = ['init', 'step_chunk', 'outputs'] as const;
/** The L2 gas cap of a virtual transaction (SN1 §3: `execute_max_sierra_gas`, 1.1B). */
export const VIRTUAL_L2_GAS = 1_100_000_000n;

/**
 * The declared hashes of the split crate's classes, by contract name, from `slingfall_split::hashes`
 * (`pinned()`): the crate's test `test_pinned_class_hashes` keeps them equal to the build, and a
 * declare with a stale one fails (the transaction hash, hence the signature, is wrong).
 */
export function pinnedHashes(text = readFileSync(root(HASHES), 'utf8')): Record<string, string> {
  const constants = new Map<string, string>();
  for (const m of text.matchAll(/pub const (\w+): felt252 =\s*(0x[0-9a-fA-F]+);/g)) constants.set(m[1], feltHex(m[2]));
  const pinned = text.slice(text.indexOf('pub fn pinned()'));
  const out: Record<string, string> = {};
  for (const m of pinned.matchAll(/\("(\w+)", (\w+)\)/g)) {
    const value = constants.get(m[2]);
    if (value === undefined) throw new Error(`${HASHES}: no constant ${m[2]} for ${m[1]}`);
    out[m[1]] = value;
  }
  for (const name of SPLIT_BUNDLE_CLASSES) if (!(name in out)) throw new Error(`${HASHES}: no pinned hash for ${name}`);
  return out;
}

/** The bundle of a chain from its classes by name (`SPLIT_BUNDLE_CLASSES` order). */
export function bundleOf(classes: Record<string, string>): { order: string[]; classHashes: string[]; bundleHash: string } {
  const classHashes = SPLIT_BUNDLE_CLASSES.map((name) => {
    if (!classes[name]) throw new Error(`bundle: no class hash for ${name}`);
    return feltHex(classes[name]);
  });
  return { order: [...SPLIT_BUNDLE_CLASSES], classHashes, bundleHash: bundleHash(classHashes) };
}

interface SierraEntryPoints {
  entry_points_by_type: Record<'EXTERNAL' | 'L1_HANDLER' | 'CONSTRUCTOR', { selector: string }[]>;
}

/**
 * Contract v3's "one chain, one bundle" (V3 escalation 2) on the class that will be deployed:
 * `SplitChain`'s external entry points are exactly `init`, `step_chunk`, `outputs` (no setter of its
 * class hashes, no upgrade), with one constructor and no L1 handler. Throws otherwise.
 */
export function checkChainEntryPoints(sierra: SierraEntryPoints): void {
  const eps = sierra.entry_points_by_type;
  const got = new Set(eps.EXTERNAL.map((e) => BigInt(e.selector)));
  const want = new Set(CHAIN_ENTRY_POINTS.map((n) => BigInt(hash.getSelectorFromName(n))));
  const same = got.size === want.size && [...got].every((s) => want.has(s));
  if (!same || eps.L1_HANDLER.length !== 0 || eps.CONSTRUCTOR.length !== 1) {
    throw new Error(
      `SplitChain: external entry points must be exactly ${CHAIN_ENTRY_POINTS.join(', ')} with one constructor and no L1 handler ` +
        `(got ${eps.EXTERNAL.length} external, ${eps.L1_HANDLER.length} L1 handler, ${eps.CONSTRUCTOR.length} constructor)`,
    );
  }
}

/** What the on-chain check reads: an `RpcProvider` (a storage read is `{value}` on RPC 0.10 nodes, a felt on older ones). */
export interface ChainStateReader {
  getClassHashAt(address: string): Promise<string>;
  getStorageAt(address: string, key: string): Promise<string | { value: string }>;
}

/**
 * The bundle a deployed chain really is: its class (`getClassHashAt`) and its five constructor classes
 * (storage), then the classes compiled into the world class (the pins: the world class's own hash fixes
 * them). Throws when the deployment differs from `classes` (a wrong address, another release).
 */
export async function verifyChain(reader: ChainStateReader, chain: string, classes: Record<string, string>): Promise<ReturnType<typeof bundleOf>> {
  const onChain: Record<string, string> = { ...classes, SplitChain: feltHex(await reader.getClassHashAt(chain)) };
  const names = ['BuildClass', 'SettleClass', 'EditClass', 'WorldClass', 'OutputsClass'];
  for (const [i, variable] of CHAIN_STORAGE.entries()) {
    const stored = await reader.getStorageAt(chain, hash.getSelectorFromName(variable));
    onChain[names[i]] = feltHex(typeof stored === 'string' ? stored : stored.value);
  }
  for (const name of ['SplitChain', ...names]) {
    if (BigInt(onChain[name]) !== BigInt(classes[name])) throw new Error(`chain ${chain}: ${name} is ${onChain[name]}, the bundle says ${classes[name]}`);
  }
  return bundleOf(onChain);
}

/** A signed Invoke V3 in the RPC's `BROADCASTED_INVOKE_TXN` shape. */
export interface BroadcastInvoke {
  type: 'INVOKE';
  version: '0x3';
  sender_address: string;
  calldata: string[];
  signature: string[];
  nonce: string;
  resource_bounds: Record<'l1_gas' | 'l2_gas' | 'l1_data_gas', { max_amount: string; max_price_per_unit: string }>;
  tip: '0x0';
  paymaster_data: string[];
  account_deployment_data: string[];
  nonce_data_availability_mode: 'L1';
  fee_data_availability_mode: 'L1';
}

/**
 * The virtual transaction of a SNIP-36 proof (SN1 §7 step 2): the account's `__execute__` of `calls`,
 * nonce = the account's nonce at the base block, every price zero, tip zero, `l2_gas.max_amount` near
 * the protocol's cap, no proof facts; signed by `privateKey` (a Cairo 1 account's `[r, s]`).
 */
export function virtualInvoke(sender: string, privateKey: string, calls: Call[], nonce: bigint, chainId: string): BroadcastInvoke {
  const calldata = transaction.getExecuteCalldata(calls, '1').map((x: unknown) => num.toHex(x as bigint));
  const zero = { max_amount: 0n, max_price_per_unit: 0n };
  const resourceBounds = { l1_gas: zero, l2_gas: { max_amount: VIRTUAL_L2_GAS, max_price_per_unit: 0n }, l1_data_gas: zero };
  const txHash = hash.calculateInvokeTransactionHash({
    senderAddress: sender,
    version: '0x3',
    compiledCalldata: calldata,
    chainId,
    nonce,
    accountDeploymentData: [],
    nonceDataAvailabilityMode: 0,
    feeDataAvailabilityMode: 0,
    resourceBounds,
    tip: 0n,
    paymasterData: [],
  } as never);
  const signature = ec.starkCurve.sign(txHash, privateKey);
  const bound = (b: { max_amount: bigint; max_price_per_unit: bigint }) => ({ max_amount: num.toHex(b.max_amount), max_price_per_unit: num.toHex(b.max_price_per_unit) });
  return {
    type: 'INVOKE',
    version: '0x3',
    sender_address: feltHex(sender),
    calldata,
    signature: [num.toHex(signature.r), num.toHex(signature.s)],
    nonce: num.toHex(nonce),
    resource_bounds: { l1_gas: bound(zero), l2_gas: bound(resourceBounds.l2_gas), l1_data_gas: bound(zero) },
    tip: '0x0',
    paymaster_data: [],
    account_deployment_data: [],
    nonce_data_availability_mode: 'L1',
    fee_data_availability_mode: 'L1',
  };
}
