// The Submit section of the end-of-level panel: wallet choice and connection, an optional proof
// path (made by the local prover, P1's `tools/prove/prove.py`), then `submitLevel` step by step:
// transaction hash, gas, the player's best and the leaderboard.
import type { RpcProvider } from 'starknet';
import { requestAttestation } from './attest.ts';
import type { ChainConfig } from './config.ts';
import { SlingfallContract, feltHex, type ChainWriter } from './slingfall.ts';
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
  private readonly board = make('ol', { className: 'submit-board' });
  private readonly config: ChainConfig;
  private readonly rpc: RpcProvider;
  private readonly contract: SlingfallContract;
  private account: ChainWriter | null = null;
  private outputsFor: ((player: string) => Promise<string[]>) | null = null;
  private busy = false;

  constructor(parent: HTMLElement, config: ChainConfig) {
    this.config = config;
    this.rpc = provider(config);
    this.contract = new SlingfallContract(config.address, this.rpc);
    for (const kind of walletKinds(config)) this.wallet.add(new Option(WALLET_LABELS[kind], kind));
    const row = make('div', { className: 'submit-row' });
    row.append(this.wallet, this.connect);
    this.root.append(make('h3', { textContent: 'Submit on Starknet' }), row, this.proof, this.send, this.status, this.board);
    this.root.hidden = true;
    parent.append(this.root);
    this.connect.addEventListener('click', () => void this.doConnect());
    this.send.addEventListener('click', () => void this.doSubmit());
  }

  /** The level is over: offer to submit its outputs (recomputed for the connected account). */
  offer(outputsFor: (player: string) => Promise<string[]>): void {
    this.outputsFor = outputsFor;
    this.board.replaceChildren();
    this.say(this.account ? `Connected ${short(this.account.address)}` : 'Connect a wallet to submit this attempt');
    this.refresh();
    this.root.hidden = false;
  }

  hide(): void {
    this.outputsFor = null;
    this.root.hidden = true;
  }

  private refresh(): void {
    this.send.disabled = this.busy || this.account === null || this.outputsFor === null;
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
    const onStep = (step: SubmissionStep) => {
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
      this.board.replaceChildren(
        ...result.leaderboard.map((row) => {
          const mine = BigInt(row.player) === BigInt(account.address);
          return make('li', { textContent: `${short(row.player)} ${row.score}`, className: mine ? 'mine' : '' });
        }),
      );
      this.outputsFor = null; // one submission per attempt (the nullifier refuses a second)
    } catch (e) {
      console.error(e);
      this.say(`Submit failed: ${e instanceof Error ? e.message : e}`);
    }
    this.busy = false;
    this.refresh();
  }
}
