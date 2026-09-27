// The `Slingfall` contract (v2, docs/contract-v2.md) as the client and `deploy/slingfall.ts` use it:
// calldata of `submit` / `submit_settled` / `expire` and of the admin entry points, reads of the two
// tiers (`best` / `best_settled`, `leaderboard` / `leaderboard_provisional`) and of the program set,
// the `LevelValidated` event and the gas of a receipt. Felts by hand (the ABI is small and its
// layout is API): no ABI file to keep in sync.
// No DOM; Node runs this file as is (type stripping), so imports carry their `.ts` extension.
import { hash, num, type Call } from 'starknet';

/** Felts of `Outputs` (D4). */
export const N_OUTPUTS = 10;
/** Index of `player` in the outputs felts. */
export const OUTPUT_PLAYER = 3;
/** `VerifierKind` variants (their `Serde` index). */
export const VERIFIER = { snip36: 0, stub: 1, satellite: 2 } as const;
/** `nullifier::*`: the tier of an attempt (`attempt`). */
export const ATTEMPT = { none: 0, attested: 1, settled: 2 } as const;
/** `programs[hash]` of the current program (`u64::MAX`). */
export const FOREVER = 2n ** 64n - 1n;

/** What reads need: `RpcProvider` / `Account` in the app, a fake in the tests. */
export interface ChainReader {
  callContract(call: Call): Promise<string[]>;
}

/** What writes need: an `Account` / `WalletAccount`. */
export interface ChainWriter {
  address: string;
  execute(calls: Call | Call[]): Promise<{ transaction_hash: string }>;
}

/** `registry::Best`: a player's best validated attempt of a tier (all zero when none). */
export interface BestRecord {
  score: number;
  won: boolean;
  inputsHash: string;
  block: number;
  /** Block timestamp of the submission (`expire` counts from it). */
  timestamp: number;
  /** Validated by the Satellite fact (else provisional: an attestation). */
  settled: boolean;
  /** The engine release the attempt was validated with (`c1main`'s program hash). */
  programHash: string;
}

export interface LeaderboardRow {
  player: string;
  score: number;
}

/** The `LevelValidated` event of an accepted `submit` / `submit_settled`. */
export interface LevelValidated {
  player: string;
  levelHash: string;
  inputsHash: string;
  score: number;
  won: boolean;
  settled: boolean;
  programHash: string;
}

/** `SatelliteConfig` (v2: three fields). */
export interface SatelliteConfig {
  atlantic_bootloader_hash: string;
  sharp_bootloader_hash: string;
  satellite_address: string;
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

/** `submit(outputs, evidence)`; the attested tier's evidence is `[program_hash, expiry, r, s]`. */
export function submitCall(contract: string, outputs: readonly string[], evidence: readonly string[]): Call {
  return { contractAddress: contract, entrypoint: 'submit', calldata: submitCalldata(outputs, evidence) };
}

/** `submit_settled(outputs, args, child_program_hash)`: the layout of `submit`, `c1main`'s argument in
 * place of the evidence, then the program the run was proven with. */
export function submitSettledCall(contract: string, outputs: readonly string[], args: readonly string[], childProgramHash: string): Call {
  return { contractAddress: contract, entrypoint: 'submit_settled', calldata: [...submitCalldata(outputs, args), feltHex(childProgramHash)] };
}

/** `expire(level_hash, player)`: anyone may demote an unsettled provisional record older than `expire_delay`. */
export function expireCall(contract: string, levelHash: string, player: string): Call {
  return { contractAddress: contract, entrypoint: 'expire', calldata: [feltHex(levelHash), feltHex(player)] };
}

/** Admin calls of v2 (`ISlingfallAdmin`, `ISlingfallSatellite`, `ISlingfallGovernance`). */
export const adminCalls = {
  setVerifier: (contract: string, kind: number): Call => ({ contractAddress: contract, entrypoint: 'set_verifier', calldata: [hex(kind)] }),
  setAttestationKey: (contract: string, key: string): Call => ({ contractAddress: contract, entrypoint: 'set_attestation_key', calldata: [feltHex(key)] }),
  setSatelliteConfig: (contract: string, c: SatelliteConfig): Call => ({
    contractAddress: contract,
    entrypoint: 'set_satellite_config',
    calldata: [feltHex(c.atlantic_bootloader_hash), feltHex(c.sharp_bootloader_hash), feltHex(c.satellite_address)],
  }),
  pinProgram: (contract: string, programHash: string, graceS: number | bigint): Call => ({
    contractAddress: contract,
    entrypoint: 'pin_program',
    calldata: [feltHex(programHash), hex(BigInt(graceS))],
  }),
  revokeProgram: (contract: string, programHash: string): Call => ({ contractAddress: contract, entrypoint: 'revoke_program', calldata: [feltHex(programHash)] }),
  setAdmin: (contract: string, admin: string): Call => ({ contractAddress: contract, entrypoint: 'set_admin', calldata: [feltHex(admin)] }),
  acceptAdmin: (contract: string): Call => ({ contractAddress: contract, entrypoint: 'accept_admin', calldata: [] }),
  upgrade: (contract: string, classHash: string): Call => ({ contractAddress: contract, entrypoint: 'upgrade', calldata: [feltHex(classHash)] }),
  setExpireDelay: (contract: string, seconds: number): Call => ({ contractAddress: contract, entrypoint: 'set_expire_delay', calldata: [hex(seconds)] }),
};

/** A shot as the replay takes it (D3). */
export interface ShotFelts {
  pull_x: number;
  pull_y: number;
  delay?: number;
}

/** `Serde` felts of `Inputs { player, shots }` (`ability_tick = 0`; negative = P - x). */
export function inputsFelts(player: string, shots: readonly ShotFelts[]): string[] {
  const P = 2n ** 251n + 17n * 2n ** 192n + 1n;
  const felt = (v: number) => hex(((BigInt(v) % P) + P) % P);
  return [feltHex(player), hex(shots.length), ...shots.flatMap((s) => [felt(s.pull_x), felt(s.pull_y), hex(s.delay ?? 0), '0x0'])];
}

/** `c1main`'s argument, the evidence of `submit_settled`: `[len(level), level..., len(inputs), inputs...]`. */
export function runArgs(level: readonly string[], inputs: readonly string[]): string[] {
  return [hex(level.length), ...level.map(feltHex), hex(inputs.length), ...inputs.map(feltHex)];
}

/** `register_level(level: Array<felt252>)` of a level's `Serde` felts. */
export function registerLevelCall(contract: string, felts: readonly string[]): Call {
  return { contractAddress: contract, entrypoint: 'register_level', calldata: [hex(felts.length), ...felts.map(feltHex)] };
}

/** `Best` from its 7 felts: `score, won, inputs_hash, block, timestamp, settled, program_hash`. */
export function decodeRecord(felts: readonly string[]): BestRecord {
  if (felts.length !== 7) throw new Error(`best: ${felts.length} felts, expected 7`);
  return {
    score: Number(BigInt(felts[0])),
    won: BigInt(felts[1]) === 1n,
    inputsHash: hex(felts[2]),
    block: Number(BigInt(felts[3])),
    timestamp: Number(BigInt(felts[4])),
    settled: BigInt(felts[5]) === 1n,
    programHash: hex(felts[6]),
  };
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

/** The `LevelValidated` events of `contract` in a receipt (keys: selector, player, level_hash; data:
 * inputs_hash, score, won, settled, program_hash). */
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
      settled: BigInt(e.data[3] ?? 0) === 1n,
      programHash: hex(e.data[4] ?? 0),
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

/** The contract's panic messages (`submit/errors.cairo`), in plain words for the panel. */
const PANIC_SENTENCES: readonly [string, string][] = [
  ['submit: program', 'the contract no longer accepts the engine release this attempt was made with (re-pinned past its grace period, or revoked)'],
  ['submit: proof', 'the contract refuses this proof or attestation (no such fact on the Satellite, or an expired or stale attestation)'],
  ['submit: nullifier', 'this exact attempt was already submitted at this tier (perhaps by the relay)'],
  ['submit: player', 'the outputs are not for the connected account'],
  ['submit: level', 'this level is not registered on this deployment'],
  ['submit: inactive', 'this level was deactivated on this deployment'],
  ['expire: early', 'this provisional record is not old enough to expire yet'],
  ['expire: none', 'there is no unsettled provisional record to expire'],
];

/**
 * A wallet or node error (m14) in plain words: a known contract panic (`PANIC_SENTENCES`) reads as
 * a sentence, a user cancellation reads as "cancelled in the wallet", anything else keeps its raw
 * message so nothing is hidden.
 */
export function explainWalletError(error: unknown): string {
  for (const [panic, sentence] of PANIC_SENTENCES) {
    if (mentionsPanic(error, panic)) return sentence;
  }
  const message = error instanceof Error ? error.message : String(error);
  if (/user (abort|reject|cancel)/i.test(message)) return 'cancelled in the wallet';
  return message;
}

/** Reads and the player's submissions on one deployed `Slingfall` (v2). */
export class SlingfallContract {
  readonly address: string;
  private readonly reader: ChainReader;

  constructor(address: string, reader: ChainReader) {
    this.address = address;
    this.reader = reader;
  }

  private call(entrypoint: string, calldata: string[] = []): Promise<string[]> {
    return this.reader.callContract({ contractAddress: this.address, entrypoint, calldata });
  }

  private async one(entrypoint: string, calldata: string[] = []): Promise<bigint> {
    const [value] = await this.call(entrypoint, calldata);
    return BigInt(value);
  }

  /** The deployed verifier (`VERIFIER`): `satellite` closes the attested tier (settled proofs only). */
  async verifier(): Promise<number> {
    return Number(await this.one('verifier'));
  }

  /** The best attempt of either tier. */
  async best(player: string, levelHash: string): Promise<BestRecord> {
    return decodeRecord(await this.call('best', [feltHex(player), feltHex(levelHash)]));
  }

  /** The best settled attempt. */
  async bestSettled(player: string, levelHash: string): Promise<BestRecord> {
    return decodeRecord(await this.call('best_settled', [feltHex(player), feltHex(levelHash)]));
  }

  /** The tier of an attempt (`ATTEMPT`). */
  async attempt(levelHash: string, player: string, inputsHash: string): Promise<number> {
    return Number(await this.one('attempt', [feltHex(levelHash), feltHex(player), feltHex(inputsHash)]));
  }

  /** The registered level's `Serde` felts (empty when unknown). */
  async levelData(levelHash: string): Promise<string[]> {
    const felts = await this.call('level_data', [feltHex(levelHash)]);
    return felts.slice(1).map(feltHex);
  }

  /** The settled board: top 10 won `best_settled` records. */
  async leaderboard(levelHash: string): Promise<LeaderboardRow[]> {
    return decodeLeaderboard(await this.call('leaderboard', [feltHex(levelHash)]));
  }

  /** The live board: top 10 won `best` records, either tier. */
  async leaderboardProvisional(levelHash: string): Promise<LeaderboardRow[]> {
    return decodeLeaderboard(await this.call('leaderboard_provisional', [feltHex(levelHash)]));
  }

  /** The last pinned program (`0x0` when none or revoked). */
  async currentProgram(): Promise<string> {
    return hex(await this.one('current_program'));
  }

  /** Until when `programHash` is accepted (exclusive block timestamp; `FOREVER`, `0` never / revoked). */
  async programValidUntil(programHash: string): Promise<bigint> {
    return this.one('program_valid_until', [feltHex(programHash)]);
  }

  async attestationEpoch(): Promise<number> {
    return Number(await this.one('attestation_epoch'));
  }

  async expireDelay(): Promise<number> {
    return Number(await this.one('expire_delay'));
  }

  async admin(): Promise<string> {
    return hex(await this.one('admin'));
  }

  async pendingAdmin(): Promise<string> {
    return hex(await this.one('pending_admin'));
  }

  async satelliteConfig(): Promise<SatelliteConfig> {
    const [a, s, satellite] = await this.call('satellite_config');
    return { atlantic_bootloader_hash: hex(a), sharp_bootloader_hash: hex(s), satellite_address: hex(satellite) };
  }

  /** Sends the attested `submit(outputs, evidence)` from `account` (the outputs' `player` must be it). */
  async submit(account: ChainWriter, outputs: readonly string[], evidence: readonly string[]): Promise<string> {
    if (BigInt(outputs[OUTPUT_PLAYER]) !== BigInt(account.address)) {
      throw new Error(`outputs player ${feltHex(outputs[OUTPUT_PLAYER])} is not the account ${feltHex(account.address)}`);
    }
    const { transaction_hash } = await account.execute(submitCall(this.address, outputs, evidence));
    return transaction_hash;
  }

  /** Sends `submit_settled(outputs, args, child_program_hash)` from `account`: the record is the
   * outputs' `player`'s whoever sends it (a relay may), once the run's fact is on the Satellite. */
  async submitSettled(account: ChainWriter, outputs: readonly string[], args: readonly string[], childProgramHash: string): Promise<string> {
    const { transaction_hash } = await account.execute(submitSettledCall(this.address, outputs, args, childProgramHash));
    return transaction_hash;
  }

  /** Sends `expire(level_hash, player)` from `account`. */
  async expire(account: ChainWriter, levelHash: string, player: string): Promise<string> {
    const { transaction_hash } = await account.execute(expireCall(this.address, levelHash, player));
    return transaction_hash;
  }
}

/** A row of a tier's board with the record behind it: the engine release (`programHash`) and, on the
 * live board, whether the row is settled. */
export interface TierRow extends LeaderboardRow {
  programHash: string;
  settled: boolean;
}

export interface Boards {
  /** `leaderboard`: settled records only. */
  settled: TierRow[];
  /** `leaderboard_provisional`: each player's best of either tier. */
  provisional: TierRow[];
  /** `current_program()`: rows made with another release are marked. */
  currentProgram: string;
}

/** Both boards of a level, each row with the program of its record (`best_settled` for the settled
 * board, `best` for the live one). */
export async function readBoards(contract: SlingfallContract, levelHash: string): Promise<Boards> {
  const [settledRows, provisionalRows, currentProgram] = await Promise.all([
    contract.leaderboard(levelHash),
    contract.leaderboardProvisional(levelHash),
    contract.currentProgram().catch(() => '0x0'),
  ]);
  const withRecords = (rows: LeaderboardRow[], read: (player: string) => Promise<BestRecord>) =>
    Promise.all(
      rows.map(async (row) => {
        const record = await read(row.player);
        return { ...row, programHash: record.programHash, settled: record.settled };
      }),
    );
  const [settled, provisional] = await Promise.all([
    withRecords(settledRows, (p) => contract.bestSettled(p, levelHash)),
    withRecords(provisionalRows, (p) => contract.best(p, levelHash)),
  ]);
  return { settled, provisional, currentProgram };
}

/** A felt as a short `0xabcdef01…1234` for display (full felt when it is short). */
export function shortFelt(felt: string): string {
  const h = feltHex(felt);
  return h.length > 14 ? `${h.slice(0, 8)}…${h.slice(-4)}` : h;
}

/** What `playerValidations` needs of an `RpcProvider`. */
export interface EventReader {
  getEvents(filter: {
    address: string;
    keys: string[][];
    from_block: { block_number: number };
    to_block: 'latest';
    chunk_size: number;
    continuation_token?: string;
  }): Promise<{ events: { transaction_hash: string; block_number?: number }[]; continuation_token?: string }>;
}

/**
 * The transactions in which `contract` emitted `LevelValidated` for `player`, oldest first
 * (`pages` chunks at most). `fromBlock` (m10: the contract's deployment block, `ChainConfig.
 * deployBlock`) replaces the default genesis scan, which the public RPC answers slowly or not at
 * all over a long range; a page that fails is retried once (`retries`) before the call throws.
 */
export async function playerValidations(
  reader: EventReader,
  contract: string,
  player: string,
  { fromBlock = 0, pages = 4, retries = 1 }: { fromBlock?: number; pages?: number; retries?: number } = {},
): Promise<{ transactionHash: string; blockNumber: number | null }[]> {
  const found: { transactionHash: string; blockNumber: number | null }[] = [];
  let token: string | undefined;
  for (let page = 0; page < pages; page++) {
    let chunk;
    for (let attempt = 0; ; attempt++) {
      try {
        chunk = await reader.getEvents({
          address: contract,
          keys: [[LEVEL_VALIDATED], [feltHex(player)]],
          from_block: { block_number: fromBlock },
          to_block: 'latest',
          chunk_size: 50,
          ...(token ? { continuation_token: token } : {}),
        });
        break;
      } catch (e) {
        if (attempt >= retries) throw e;
      }
    }
    for (const e of chunk.events) found.push({ transactionHash: e.transaction_hash, blockNumber: e.block_number ?? null });
    token = chunk.continuation_token;
    if (!token) break;
  }
  return found;
}
