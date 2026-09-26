// The `Slingfall` contract as the client and `deploy/slingfall.ts` use it (docs/DESIGN.md D9):
// calldata of `submit`, reads of `best` / `leaderboard`, the `LevelValidated` event and the gas of
// a receipt. Felts by hand (the ABI is small and its layout is API): no ABI file to keep in sync.
// No DOM; Node runs this file as is (type stripping), so imports carry their `.ts` extension.
import { hash, num, type Call } from 'starknet';

/** Felts of `Outputs` (D4). */
export const N_OUTPUTS = 10;
/** Index of `player` in the outputs felts. */
export const OUTPUT_PLAYER = 3;
/** `VerifierKind` variants (their `Serde` index). */
export const VERIFIER = { snip36: 0, stub: 1 } as const;

/** What reads need: `RpcProvider` / `Account` in the app, a fake in the tests. */
export interface ChainReader {
  callContract(call: Call): Promise<string[]>;
}

/** What writes need: an `Account` / `WalletAccount`. */
export interface ChainWriter {
  address: string;
  execute(calls: Call | Call[]): Promise<{ transaction_hash: string }>;
}

/** `registry::Record`: a player's best validated attempt (all zero when none). */
export interface BestRecord {
  score: number;
  won: boolean;
  inputsHash: string;
  block: number;
}

export interface LeaderboardRow {
  player: string;
  score: number;
}

/** The `LevelValidated` event of an accepted `submit`. */
export interface LevelValidated {
  player: string;
  levelHash: string;
  inputsHash: string;
  score: number;
  won: boolean;
}

/** Gas of a transaction (RPC 0.8+ `execution_resources`) and its fee. */
export interface TxGas {
  l1Gas: number;
  l1DataGas: number;
  l2Gas: number;
  fee: string;
  unit: string;
}

const hex = (value: string | number | bigint) => num.toHex(value);

/** A felt given as decimal or `0x` hex, normalised to `0x` hex; throws outside `[0, P)`. */
export function feltHex(value: string | number | bigint): string {
  const n = BigInt(value);
  if (n < 0n || n >= 2n ** 251n + 17n * 2n ** 192n + 1n) throw new Error(`not a felt: ${value}`);
  return hex(n);
}

/** Calldata of `submit(outputs: Array<felt252>, evidence: Array<felt252>)`. */
export function submitCalldata(outputs: readonly string[], evidence: readonly string[]): string[] {
  if (outputs.length !== N_OUTPUTS) throw new Error(`outputs: ${outputs.length} felts, expected ${N_OUTPUTS}`);
  return [hex(outputs.length), ...outputs.map(feltHex), hex(evidence.length), ...evidence.map(feltHex)];
}

export function submitCall(contract: string, outputs: readonly string[], evidence: readonly string[]): Call {
  return { contractAddress: contract, entrypoint: 'submit', calldata: submitCalldata(outputs, evidence) };
}

/** `register_level(level: Array<felt252>)` of a level's `Serde` felts. */
export function registerLevelCall(contract: string, felts: readonly string[]): Call {
  return { contractAddress: contract, entrypoint: 'register_level', calldata: [hex(felts.length), ...felts.map(feltHex)] };
}

export function decodeRecord(felts: readonly string[]): BestRecord {
  if (felts.length !== 4) throw new Error(`best: ${felts.length} felts, expected 4`);
  return { score: Number(BigInt(felts[0])), won: BigInt(felts[1]) === 1n, inputsHash: hex(felts[2]), block: Number(BigInt(felts[3])) };
}

/** `Array<(ContractAddress, u32)>`: a length, then `(player, score)` pairs. */
export function decodeLeaderboard(felts: readonly string[]): LeaderboardRow[] {
  const n = Number(BigInt(felts[0] ?? '0'));
  if (felts.length !== 1 + 2 * n) throw new Error(`leaderboard: ${felts.length} felts for ${n} rows`);
  return Array.from({ length: n }, (_, i) => ({ player: hex(felts[1 + 2 * i]), score: Number(BigInt(felts[2 + 2 * i])) }));
}

export const LEVEL_VALIDATED = hash.getSelectorFromName('LevelValidated');

interface RawEvent {
  from_address?: string;
  keys: readonly string[];
  data: readonly string[];
}

/** The `LevelValidated` events of `contract` in a receipt (keys: selector, player, level_hash). */
export function levelValidatedEvents(receipt: { events?: readonly RawEvent[] }, contract: string): LevelValidated[] {
  const from = BigInt(contract);
  return (receipt.events ?? [])
    .filter((e) => (e.from_address === undefined || BigInt(e.from_address) === from) && e.keys.length === 3 && BigInt(e.keys[0]) === BigInt(LEVEL_VALIDATED))
    .map((e) => ({
      player: hex(e.keys[1]),
      levelHash: hex(e.keys[2]),
      inputsHash: hex(e.data[0]),
      score: Number(BigInt(e.data[1])),
      won: BigInt(e.data[2]) === 1n,
    }));
}

/** Gas of a receipt; zeros for the fields the node does not report. */
export function receiptGas(receipt: {
  execution_resources?: { l1_gas?: number | string; l1_data_gas?: number | string; l2_gas?: number | string };
  actual_fee?: { amount: string; unit: string };
}): TxGas {
  const r = receipt.execution_resources ?? {};
  return {
    l1Gas: Number(r.l1_gas ?? 0),
    l1DataGas: Number(r.l1_data_gas ?? 0),
    l2Gas: Number(r.l2_gas ?? 0),
    fee: receipt.actual_fee ? BigInt(receipt.actual_fee.amount).toString() : '0',
    unit: receipt.actual_fee?.unit ?? '',
  };
}

/** A panic message (`'submit: nullifier'`) as it appears in a node's error: text or its hex. */
export function mentionsPanic(error: unknown, message: string): boolean {
  const text = error instanceof Error ? `${error.message} ${String((error as { data?: unknown }).data ?? '')}` : String(error);
  const encoded = [...message].map((c) => c.charCodeAt(0).toString(16).padStart(2, '0')).join('');
  return text.includes(message) || text.toLowerCase().includes(encoded);
}

/** Reads and the player's `submit` on one deployed `Slingfall`. */
export class SlingfallContract {
  readonly address: string;
  private readonly reader: ChainReader;

  constructor(address: string, reader: ChainReader) {
    this.address = address;
    this.reader = reader;
  }

  async best(player: string, levelHash: string): Promise<BestRecord> {
    return decodeRecord(await this.reader.callContract({ contractAddress: this.address, entrypoint: 'best', calldata: [feltHex(player), feltHex(levelHash)] }));
  }

  async leaderboard(levelHash: string): Promise<LeaderboardRow[]> {
    return decodeLeaderboard(await this.reader.callContract({ contractAddress: this.address, entrypoint: 'leaderboard', calldata: [feltHex(levelHash)] }));
  }

  /** Sends `submit(outputs, evidence)` from `account` (the outputs' `player` must be it). */
  async submit(account: ChainWriter, outputs: readonly string[], evidence: readonly string[]): Promise<string> {
    if (BigInt(outputs[OUTPUT_PLAYER]) !== BigInt(account.address)) {
      throw new Error(`outputs player ${feltHex(outputs[OUTPUT_PLAYER])} is not the account ${feltHex(account.address)}`);
    }
    const { transaction_hash } = await account.execute(submitCall(this.address, outputs, evidence));
    return transaction_hash;
  }
}
