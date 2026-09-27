// The attested "Submit" step after a level (lots G9, W1), without DOM: the outputs for the connected
// wallet, the attestation of the service (it re-executes the replay), `submit(outputs, [program_hash,
// expiry, r, s])` through the wallet, the receipt (gas, `LevelValidated`), then both records and both
// boards. The attempt is then *provisional*; the settled tier follows (prove.ts, panel.ts).
import type { Attestation } from './attest.ts';
import {
  levelValidatedEvents,
  readBoards,
  receiptGas,
  type BestRecord,
  type Boards,
  type ChainWriter,
  type LevelValidated,
  type SlingfallContract,
  type TxGas,
} from './slingfall.ts';

/** A receipt as the RPC gives it (the fields read here). */
export interface Receipt {
  execution_status?: string;
  revert_reason?: string;
  events?: { from_address?: string; keys: string[]; data: string[] }[];
  execution_resources?: { l1_gas?: number; l1_data_gas?: number; l2_gas?: number };
  actual_fee?: { amount: string; unit: string };
}

export interface SubmissionDeps {
  contract: SlingfallContract;
  account: ChainWriter;
  /** The outputs felts of the finished level with `player` = the account. */
  outputsFor(player: string): Promise<string[]>;
  attest(outputs: string[]): Promise<Attestation>;
  waitForReceipt(transactionHash: string): Promise<Receipt>;
}

export type SubmissionStep =
  | { kind: 'outputs'; outputs: string[] }
  | { kind: 'attested'; attestation: Attestation }
  | { kind: 'sent'; transactionHash: string }
  | { kind: 'accepted'; gas: TxGas; validated: LevelValidated };

export interface SubmissionResult {
  transactionHash: string;
  outputs: string[];
  gas: TxGas;
  validated: LevelValidated;
  /** The player's best of either tier (now the provisional record, unless a better one stands). */
  best: BestRecord;
  bestSettled: BestRecord;
  boards: Boards;
}

export async function submitLevel(deps: SubmissionDeps, onStep: (step: SubmissionStep) => void = () => {}): Promise<SubmissionResult> {
  const { contract, account } = deps;
  const outputs = await deps.outputsFor(account.address);
  onStep({ kind: 'outputs', outputs });
  const attestation = await deps.attest(outputs);
  onStep({ kind: 'attested', attestation });
  const transactionHash = await contract.submit(account, outputs, attestation.evidence);
  onStep({ kind: 'sent', transactionHash });
  const receipt = await deps.waitForReceipt(transactionHash);
  if (receipt.execution_status === 'REVERTED') throw new Error(`submit reverted: ${receipt.revert_reason ?? 'no reason'}`);
  const [validated] = levelValidatedEvents(receipt, contract.address);
  if (validated === undefined) throw new Error(`submit ${transactionHash}: no LevelValidated event`);
  const gas = receiptGas(receipt);
  onStep({ kind: 'accepted', gas, validated });
  const levelHash = outputs[1];
  const [best, bestSettled, boards] = await Promise.all([
    contract.best(account.address, levelHash),
    contract.bestSettled(account.address, levelHash),
    readBoards(contract, levelHash),
  ]);
  return { transactionHash, outputs, gas, validated, best, bestSettled, boards };
}
