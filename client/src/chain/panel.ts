// The Submit section of the end-of-level panel: wallet choice and connection, an optional proof
// path (made by the local prover, P1's `tools/prove/prove.py`), then `submitLevel` step by step:
// transaction hash, gas, the player's best and the leaderboard. The attempt is then *provisional*
// (attested); with a prover service (`VITE_PROVE_URL`) the panel asks for its Atlantic proof,
// polls until the fact is on the Satellite, offers "Settle on Starknet" (`submit_settled`) and
// shows *settled* (docs/DESIGN.md D9, two tiers).
import type { RpcProvider } from 'starknet';
import { requestAttestation } from './attest.ts';
import { explorerLink, type ChainConfig } from './config.ts';
import { describeJob, requestProof, settleLabel, waitCheap, waitSettleable } from './prove.ts';
import {
  SlingfallContract,
  VERIFIER,
  levelValidatedEvents,
  playerValidations,
  receiptGas,
  runArgs,
  shortFelt as short,
  type ChainWriter,
} from './slingfall.ts';
import { submitLevel, type Receipt, type SubmissionStep } from './submission.ts';
import { WALLET_LABELS, connectWallet, provider, walletKinds, type WalletKind } from './wallet.ts';

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
  private readonly settle = make('button', { type: 'button', textContent: 'Settle', hidden: true });
  private readonly board = make('ol', { className: 'submit-board' });
  private readonly links = make('p', { className: 'submit-links' });
  private readonly config: ChainConfig;
  private readonly rpc: RpcProvider;
  private readonly contract: SlingfallContract;
  /** `VERIFIER` of the deployment, once read: `satellite` accepts no attestation, only a settled proof. */
  private verifier: number | null = null;
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
    this.root.append(make('h3', { textContent: 'Submit on Starknet' }), row, this.proof, this.send, this.status, this.tier, this.settle, this.board, this.links);
    this.showContractLink();
    void this.contract.verifier().then(
      (kind) => {
        this.verifier = kind;
        this.labelSend();
      },
      () => {}, // an unreachable RPC shows at the first read of the flow
    );
    this.root.hidden = true;
    parent.append(this.root);
    this.connect.addEventListener('click', () => void this.doConnect());
    this.send.addEventListener('click', () => void this.doSubmit());
    this.settle.addEventListener('click', () => void this.doSettle());
  }

  /** On a Satellite deployment the attested `submit` is refused: the one path is proof, then `submit_settled`. */
  private get settledOnly(): boolean {
    return this.verifier === VERIFIER.satellite;
  }

  private labelSend(): void {
    this.send.textContent = this.settledOnly ? 'Prove (settled)' : 'Submit';
    this.proof.hidden = this.settledOnly;
  }

  /** A link element, or plain text without an explorer. */
  private link(text: string, url: string | null): Node {
    return url ? make('a', { href: url, target: '_blank', rel: 'noopener', textContent: text }) : document.createTextNode(text);
  }

  private showContractLink(transactions: { transactionHash: string; blockNumber: number | null }[] = []): void {
    const parts: Node[] = [document.createTextNode('Contract '), this.link(short(this.config.address), explorerLink(this.config, 'contract', this.config.address))];
    if (transactions.length > 0) {
      parts.push(document.createTextNode(' · your LevelValidated: '));
      transactions.forEach((tx, i) => {
        if (i > 0) parts.push(document.createTextNode(', '));
        parts.push(this.link(short(tx.transactionHash), explorerLink(this.config, 'tx', tx.transactionHash)));
      });
    }
    this.links.replaceChildren(...parts);
  }

  /** The player's `LevelValidated` transactions from the RPC's event index; silent when the node refuses. */
  private async showValidations(player: string): Promise<void> {
    try {
      this.showContractLink(await playerValidations(this.rpc, this.config.address, player));
    } catch (e) {
      console.warn('LevelValidated events unavailable', e);
    }
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
      void this.showValidations(this.account.address);
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
    if (this.settledOnly) return this.doProve(account, outputsFor);
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
      void this.showValidations(account.address);
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

  /** Satellite deployment: no attestation; the prover service proves the attempt, then `Settle`. */
  private async doProve(account: ChainWriter, outputsFor: (player: string) => Promise<string[]>): Promise<void> {
    if (!this.config.proveUrl) {
      this.say('This deployment accepts settled proofs only: run a prover service and set VITE_PROVE_URL (docs/testers.md)');
      return;
    }
    this.busy = true;
    this.refresh();
    try {
      const outputs = await outputsFor(account.address);
      const inputs = this.inputsFor?.(account.address);
      if (!inputs) throw new Error('no inputs for this attempt');
      this.outputsFor = null; // one proof request per attempt (the job id makes a repeat idempotent anyway)
      this.say(`Proof requested for ${short(account.address)}; this takes about 1.5 h, keep this page open`);
      void this.proveAndOffer(outputs[1], outputs, inputs);
    } catch (e) {
      console.error(e);
      this.say(`Prove failed: ${e instanceof Error ? e.message : e}`);
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
      if (round === this.round) this.tier.textContent = `${this.settledOnly ? 'Proving' : 'Provisional (attested)'} · ${text}`;
    };
    try {
      const job = await requestProof(url, levelHash, inputs);
      show(describeJob(job));
      const ready = await waitSettleable(url, job.id, (j) => show(describeJob(j)));
      if (round !== this.round) return;
      this.pending = { outputs, inputs };
      this.settle.textContent = settleLabel(ready);
      this.settle.hidden = false;
      this.refresh();
      if (!ready.settleablePoseidon) {
        // The keccak path settles now; while the service translates the fact, the cheap one may come.
        const stale = () => round !== this.round || this.pending === null;
        const upgrade = await waitCheap(
          url,
          job.id,
          (j) => {
            if (!stale()) this.settle.textContent = settleLabel(j);
            show(describeJob(j));
          },
          { stop: stale },
        ).catch(() => null); // the button already works on the keccak path
        if (upgrade && !stale()) this.settle.textContent = settleLabel(upgrade);
      }
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
      void this.showValidations(account.address);
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
