// The Submit section of the end-of-level panel: wallet choice and connection, an optional proof
// path (made by the local prover, P1's `tools/prove/prove.py`), then `submitLevel` step by step:
// transaction hash, gas, the player's best and the leaderboard. The attempt is then *provisional*
// (attested); with a prover service (`VITE_PROVE_URL`) the panel asks for its Atlantic proof,
// polls until the fact is on the Satellite, offers "Settle on Starknet" (`submit_settled`) and
// shows *settled* (docs/DESIGN.md D9, two tiers).
import type { RpcProvider } from 'starknet';
import { requestAttestation } from './attest.ts';
import type { ChainConfig } from './config.ts';
import { describeJob, requestProof, waitSettleable } from './prove.ts';
import { SlingfallContract, feltHex, levelValidatedEvents, receiptGas, runArgs, type ChainWriter } from './slingfall.ts';
import { submitLevel, type Receipt, type SubmissionStep } from './submission.ts';
import { WALLET_LABELS, connectWallet, provider, walletKinds, type WalletKind } from './wallet.ts';

const short = (felt: string) => {
  const h = feltHex(felt);
  return h.length > 14 ? `${h.slice(0, 8)}…${h.slice(-4)}` : h;
};

function make<K extends keyof HTMLElementTagNameMap>(tag: K, props: Partial<HTMLElementTagNameMap[K]> = {}): HTMLElementTagNameMap[K] {
  return Object.assign(document.createElement(tag), props);
}

export class SubmitPanel {
  private readonly root = make('div', { className: 'submit' });
  private readonly wallet = make('select', { ariaLabel: 'Wallet' });
  private readonly connect = make('button', { type: 'button', textContent: 'Connect' });
  private readonly proof = make('input', { type: 'text', placeholder: 'proof path (optional; the attest service verifies it)', ariaLabel: 'Proof path' });
  private readonly send = make('button', { type: 'button', textContent: 'Submit', disabled: true });
  private readonly status = make('p', { className: 'submit-status' });
  private readonly tier = make('p', { className: 'submit-tier' });
  private readonly settle = make('button', { type: 'button', textContent: 'Settle on Starknet', hidden: true });
  private readonly board = make('ol', { className: 'submit-board' });
  private readonly config: ChainConfig;
  private readonly rpc: RpcProvider;
  private readonly contract: SlingfallContract;
  private account: ChainWriter | null = null;
  private outputsFor: ((player: string) => Promise<string[]>) | null = null;
  private inputsFor: ((player: string) => string[]) | null = null;
  /** The accepted attempt awaiting its settlement: its outputs and inputs felts. */
  private pending: { outputs: string[]; inputs: string[] } | null = null;
  /** Bumped by `offer` / `hide`: a stale poll stops updating the panel. */
  private round = 0;
  private busy = false;

  constructor(parent: HTMLElement, config: ChainConfig) {
    this.config = config;
    this.rpc = provider(config);
    this.contract = new SlingfallContract(config.address, this.rpc);
    for (const kind of walletKinds(config)) this.wallet.add(new Option(WALLET_LABELS[kind], kind));
    const row = make('div', { className: 'submit-row' });
    row.append(this.wallet, this.connect);
    this.root.append(make('h3', { textContent: 'Submit on Starknet' }), row, this.proof, this.send, this.status, this.tier, this.settle, this.board);
    this.root.hidden = true;
    parent.append(this.root);
    this.connect.addEventListener('click', () => void this.doConnect());
    this.send.addEventListener('click', () => void this.doSubmit());
    this.settle.addEventListener('click', () => void this.doSettle());
  }

  /**
   * The level is over: offer to submit its outputs (recomputed for the connected account);
   * `inputsFor` gives the `Inputs` felts of the attempt for a player (the settled tier's calldata).
   */
  offer(outputsFor: (player: string) => Promise<string[]>, inputsFor?: (player: string) => string[]): void {
    this.round += 1;
    this.outputsFor = outputsFor;
    this.inputsFor = inputsFor ?? null;
    this.pending = null;
    this.tier.textContent = '';
    this.settle.hidden = true;
    this.board.replaceChildren();
    this.say(this.account ? `Connected ${short(this.account.address)}` : 'Connect a wallet to submit this attempt');
    this.refresh();
    this.root.hidden = false;
  }

  hide(): void {
    this.round += 1;
    this.outputsFor = null;
    this.pending = null;
    this.root.hidden = true;
  }

  private refresh(): void {
    this.send.disabled = this.busy || this.account === null || this.outputsFor === null;
    this.settle.disabled = this.busy || this.account === null || this.pending === null;
    this.connect.disabled = this.busy;
  }

  private say(text: string): void {
    this.status.textContent = text;
  }

  private async doConnect(): Promise<void> {
    this.busy = true;
    this.refresh();
    try {
      this.account = await connectWallet(this.wallet.value as WalletKind, this.config, this.rpc);
      this.say(`Connected ${short(this.account.address)}`);
    } catch (e) {
      this.say(`Wallet: ${e instanceof Error ? e.message : e}`);
    }
    this.busy = false;
    this.refresh();
  }

  private async doSubmit(): Promise<void> {
    const account = this.account;
    const outputsFor = this.outputsFor;
    if (account === null || outputsFor === null) return;
    this.busy = true;
    this.refresh();
    const proofPath = this.proof.value.trim();
    let submitted: string[] = [];
    const onStep = (step: SubmissionStep) => {
      if (step.kind === 'outputs') submitted = step.outputs;
      if (step.kind === 'outputs') this.say(`Outputs for ${short(account.address)}; attesting…`);
      if (step.kind === 'attested') this.say(`Attested${step.attestation.verified ? ' (proof verified)' : ' WITHOUT a proof (--no-verify service)'}; confirm in the wallet…`);
      if (step.kind === 'sent') this.say(`Sent ${step.transactionHash}; waiting for the receipt…`);
    };
    try {
      const result = await submitLevel(
        {
          contract: this.contract,
          account,
          outputsFor,
          attest: (outputs) => requestAttestation(this.config.attestUrl, outputs, proofPath ? { path: proofPath } : undefined),
          waitForReceipt: async (hash) => (await this.rpc.waitForTransaction(hash)) as unknown as Receipt,
        },
        onStep,
      );
      const { best, gas } = result;
      console.log(`submit ${result.transactionHash}: l2_gas ${gas.l2Gas}, l1_data_gas ${gas.l1DataGas}, fee ${gas.fee} ${gas.unit}`);
      this.say(
        `Validated in ${result.transactionHash} (L2 gas ${gas.l2Gas.toLocaleString()}). ` +
          `Your best: ${best.score} (${best.won ? 'won' : 'lost'}, block ${best.block}).`,
      );
      this.showBoard(result.leaderboard, account.address);
      this.outputsFor = null; // one attested submission per attempt (the nullifier refuses a second)
      if (result.validated.settled) {
        this.tier.textContent = 'Settled';
      } else {
        this.tier.textContent = 'Provisional (attested)';
        const inputs = this.inputsFor?.(account.address);
        if (this.config.proveUrl && inputs) void this.proveAndOffer(result.validated.levelHash, submitted, inputs);
      }
    } catch (e) {
      console.error(e);
      this.say(`Submit failed: ${e instanceof Error ? e.message : e}`);
    }
    this.busy = false;
    this.refresh();
  }

  private showBoard(rows: { player: string; score: number }[], player: string): void {
    this.board.replaceChildren(
      ...rows.map((row) => {
        const mine = BigInt(row.player) === BigInt(player);
        return make('li', { textContent: `${short(row.player)} ${row.score}`, className: mine ? 'mine' : '' });
      }),
    );
  }

  /** Asks the prover service for the attempt's proof and polls until it can be settled. */
  private async proveAndOffer(levelHash: string, outputs: string[], inputs: string[]): Promise<void> {
    const url = this.config.proveUrl;
    if (!url) return;
    const round = this.round;
    const show = (text: string) => {
      if (round === this.round) this.tier.textContent = `Provisional (attested) · ${text}`;
    };
    try {
      const job = await requestProof(url, levelHash, inputs);
      show(describeJob(job));
      await waitSettleable(url, job.id, (j) => show(describeJob(j)));
      if (round !== this.round) return;
      this.pending = { outputs, inputs };
      this.settle.hidden = false;
      this.refresh();
    } catch (e) {
      show(e instanceof Error ? e.message : String(e));
    }
  }

  private async doSettle(): Promise<void> {
    const account = this.account;
    const pending = this.pending;
    if (account === null || pending === null) return;
    this.busy = true;
    this.refresh();
    try {
      const level = await this.contract.levelData(pending.outputs[1]);
      const hash = await this.contract.submitSettled(account, pending.outputs, runArgs(level, pending.inputs));
      this.tier.textContent = `Settling in ${hash}…`;
      const receipt = (await this.rpc.waitForTransaction(hash)) as unknown as Receipt;
      if (receipt.execution_status === 'REVERTED') throw new Error(`submit_settled reverted: ${receipt.revert_reason ?? 'no reason'}`);
      const [validated] = levelValidatedEvents(receipt, this.contract.address);
      if (!validated?.settled) throw new Error(`submit_settled ${hash}: no settled LevelValidated event`);
      const gas = receiptGas(receipt);
      this.tier.textContent = `Settled in ${hash} (L2 gas ${gas.l2Gas.toLocaleString()})`;
      this.pending = null;
      this.settle.hidden = true;
      this.showBoard(await this.contract.leaderboard(validated.levelHash), account.address);
    } catch (e) {
      console.error(e);
      this.tier.textContent = `Settle failed: ${e instanceof Error ? e.message : e}`;
    }
    this.busy = false;
    this.refresh();
  }
}
