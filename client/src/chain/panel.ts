// The Submit section of the end-of-level panel (contract v3, docs/contract-v3.md; v2 alike): wallet
// choice and connection, then the tiers. "Submit" asks the attestation service (it re-executes the
// replay) and sends the attested `submit`: a *provisional* record in seconds. With a prover service
// (`VITE_PROVE_URL`) the panel then requests a proof in the background: the *proven* path (SNIP-36)
// when the service's `/health` says it is available (its bundle is the contract's current chain):
// the service proves the chain, sends the proofs and `finalize` for the player, nothing to sign;
// else the *settled* path (Atlantic): when its fact lands, the service's relay settles the attempt
// for the player (`submit_settled` is recorded for `claim.player`, whoever sends it), or the player
// does with "Settle". The page need not stay open while the proof runs. Both boards are shown:
// settled (`leaderboard`: SHARP or SNIP-36) and live (`leaderboard_provisional`), each row with the
// proof and the release of its record (a program hash, or a SNIP-36 bundle hash). On a
// Satellite-only deployment (`verifier = Satellite`, the attested tier closed) "Submit" becomes
// "Prove (settled)". In the local mode of `scripts/play.sh` (`config.local`: the proofs are
// simulated) the devnet account connects by itself, and after the provisional record the player picks
// the tier of the proof: proven (the fake SNIP-36 prover) or settled (the devnet's FakeSatellite).
import type { RpcProvider } from 'starknet';
import { requestAttestation } from './attest.ts';
import { explorerLink, type ChainConfig } from './config.ts';
import {
  ChainMismatchError,
  ProgramMismatchError,
  describeJob,
  fetchHealth,
  requestProof,
  settleLabel,
  waitCheap,
  waitRelayed,
  waitSettleable,
  type ProofJob,
  type Tier,
} from './prove.ts';
import {
  SlingfallContract,
  VERIFIER,
  describeProof,
  explainWalletError,
  levelValidatedEvents,
  playerValidations,
  readBoards,
  receiptGas,
  runArgs,
  shortFelt as short,
  type Boards,
  type ChainWriter,
  type EventReader,
  type TierRow,
} from './slingfall.ts';
import { submitLevel, type Receipt, type SubmissionStep } from './submission.ts';
import { WALLET_LABELS, connectWallet, provider, walletKinds, type WalletKind } from './wallet.ts';

/** `config.local`: the simulated proofs land in seconds, the panel polls the prover service this often. */
const LOCAL_POLL_MS = 3_000;

function make<K extends keyof HTMLElementTagNameMap>(tag: K, props: Partial<HTMLElementTagNameMap[K]> = {}): HTMLElementTagNameMap[K] {
  return Object.assign(document.createElement(tag), props);
}

/** What the panel talks to: the chain, the wallet, the two services (fakes in the DOM tests). */
export interface PanelDeps {
  contract: SlingfallContract;
  waitForReceipt(transactionHash: string): Promise<Receipt>;
  connect(kind: WalletKind): Promise<ChainWriter>;
  events: EventReader;
  fetchFn: typeof fetch;
  sleep: (ms: number) => Promise<void>;
}

export function panelDeps(config: ChainConfig): PanelDeps {
  const rpc: RpcProvider = provider(config);
  return {
    contract: new SlingfallContract(config.address, rpc),
    waitForReceipt: async (hash) => (await rpc.waitForTransaction(hash)) as unknown as Receipt,
    connect: (kind) => connectWallet(kind, config, rpc),
    events: rpc as unknown as EventReader,
    fetchFn: (...args) => fetch(...args),
    sleep: (ms) => new Promise<void>((r) => setTimeout(r, ms)),
  };
}

/** The attempt whose settlement is pending: its outputs and inputs felts, and the proof's program. */
interface Pending {
  outputs: string[];
  inputs: string[];
  programHash: string | null;
}

export class SubmitPanel {
  private readonly root = make('div', { className: 'submit' });
  private readonly wallet = make('select', { ariaLabel: 'Wallet' });
  private readonly connect = make('button', { type: 'button', textContent: 'Connect' });
  private readonly proof = make('input', { type: 'text', placeholder: 'proof path (optional; the attest service verifies it)', ariaLabel: 'Proof path' });
  private readonly send = make('button', { type: 'button', textContent: 'Submit', disabled: true });
  private readonly status = make('p', { className: 'submit-status' });
  /** m11: the outputs this attempt will actually carry, recomputed for the connected account. */
  private readonly outputsInfo = make('p', { className: 'submit-outputs' });
  private readonly tier = make('p', { className: 'submit-tier' });
  private readonly settle = make('button', { type: 'button', textContent: 'Settle', hidden: true });
  /** `config.local`: the tier of the proof, picked by the player after the provisional record. */
  private readonly tiers = make('div', { className: 'submit-row submit-tiers', hidden: true });
  private readonly askProven = make('button', { type: 'button', textContent: 'Prove (SNIP-36, simulated)' });
  private readonly askSettled = make('button', { type: 'button', textContent: 'Settle (Atlantic, simulated)' });
  private choice: { levelHash: string; outputs: string[]; inputs: string[] } | null = null;
  private readonly boards = make('div', { className: 'submit-boards' });
  private readonly links = make('p', { className: 'submit-links' });
  private readonly config: ChainConfig;
  private readonly deps: PanelDeps;
  private readonly contract: SlingfallContract;
  /** `VERIFIER` of the deployment, once read: `satellite` accepts no attestation, only a settled proof. */
  private verifier: number | null = null;
  private account: ChainWriter | null = null;
  private levelHash: string | null = null;
  private outputsFor: ((player: string) => Promise<string[]>) | null = null;
  private inputsFor: ((player: string) => string[]) | null = null;
  private pending: Pending | null = null;
  /** Bumped by `offer` / `hide`: a stale poll stops updating the panel. */
  private round = 0;
  private busy = false;
  /** M6: the prover service's program is not valid on the contract; Prove is disabled up front. */
  private proveBlocked = false;
  /** The prover service's relay account (it settles for the player), once its `/health` is read. */
  private relay: string | null = null;
  /** The prover service offers the proven path (SNIP-36) for this contract, once its `/health` is read. */
  private provenPath = false;
  /** m11: called with the connected account, so the page redraws its outputs table for it. */
  onAccount: ((player: string) => void) | null = null;

  constructor(parent: HTMLElement, config: ChainConfig, deps: PanelDeps = panelDeps(config)) {
    this.config = config;
    this.deps = deps;
    this.contract = deps.contract;
    for (const kind of walletKinds(config)) this.wallet.append(make('option', { value: kind, textContent: WALLET_LABELS[kind] }));
    const row = make('div', { className: 'submit-row' });
    row.append(this.wallet, this.connect);
    this.tiers.append(this.askProven, this.askSettled);
    this.root.append(
      make('h3', { textContent: config.local ? 'Submit on the local devnet (proofs are simulated)' : 'Submit on Starknet' }),
      row,
      this.proof,
      this.send,
      this.status,
      this.outputsInfo,
      this.tier,
      this.settle,
      this.tiers,
      this.boards,
      this.links,
    );
    this.showContractLink();
    void this.contract.verifier().then(
      (kind) => {
        this.verifier = kind;
        this.labelSend();
        this.refresh();
      },
      () => {}, // an unreachable RPC shows at the first read of the flow
    );
    if (config.proveUrl) void this.checkProveHealth();
    this.root.hidden = true;
    parent.append(this.root);
    this.connect.addEventListener('click', () => void this.doConnect());
    this.send.addEventListener('click', () => void this.doSubmit());
    this.settle.addEventListener('click', () => void this.doSettle());
    this.askProven.addEventListener('click', () => this.choose('proven'));
    this.askSettled.addEventListener('click', () => this.choose('settled'));
    // The local mode's player is the devnet account: no wallet, no Connect.
    if (config.local && config.devnetAccount) {
      this.wallet.value = 'devnet';
      void this.doConnect();
    }
  }

  /** The connected account (`null` before Connect). */
  get player(): string | null {
    return this.account?.address ?? null;
  }

  /** On a Satellite deployment the attested `submit` is refused: the one path is proof, then `submit_settled`. */
  private get settledOnly(): boolean {
    return this.verifier === VERIFIER.satellite;
  }

  private labelSend(): void {
    this.send.textContent = this.settledOnly ? 'Prove (settled)' : 'Submit';
    this.proof.hidden = this.settledOnly;
  }

  /** M6 and the relay: the prover service's `/health` says whether its program is valid on the
   * contract and whether it settles for the player. Best-effort: an unreachable service changes
   * nothing here, `POST /prove` still refuses a real mismatch. */
  private async checkProveHealth(): Promise<void> {
    const url = this.config.proveUrl;
    if (!url) return;
    try {
      const health = await fetchHealth(url, this.deps.fetchFn);
      this.relay = health.relay;
      this.provenPath = health.proven?.available === true;
      this.askProven.disabled = !this.provenPath;
      if (!this.provenPath) this.askProven.title = 'the prover service has no SNIP-36 path for this contract';
      if (health.programMatch === false) {
        this.proveBlocked = true;
        this.tier.textContent =
          `Proofs blocked: this prover service proves engine release ${health.programHash}, which the contract no longer ` +
          `accepts (current ${health.contractProgramHash}). Ask the operator to update the prover service.`;
        this.refresh();
      }
    } catch {
      // unreachable or old service: no proactive warning, POST /prove is still checked (M6).
    }
  }

  /** A link element, or plain text without an explorer. */
  private link(text: string, url: string | null): Node {
    return url ? make('a', { href: url, target: '_blank', rel: 'noopener', textContent: text }) : document.createTextNode(text);
  }

  private txLink(hash: string): Node {
    return this.link(short(hash), explorerLink(this.config, 'tx', hash));
  }

  private showContractLink(transactions: { transactionHash: string; blockNumber: number | null }[] = []): void {
    const parts: Node[] = [document.createTextNode('Contract '), this.link(short(this.config.address), explorerLink(this.config, 'contract', this.config.address))];
    if (transactions.length > 0) {
      parts.push(document.createTextNode(' · your LevelValidated: '));
      transactions.forEach((tx, i) => {
        if (i > 0) parts.push(document.createTextNode(', '));
        parts.push(this.txLink(tx.transactionHash));
      });
    }
    this.links.replaceChildren(...parts);
  }

  /** The player's `LevelValidated` transactions from the RPC's event index (m10: paged from the
   * contract's deployment block, one retry); a visible "unavailable, retry" state when it still fails. */
  private async showValidations(player: string): Promise<void> {
    try {
      this.showContractLink(await playerValidations(this.deps.events, this.config.address, player, { fromBlock: this.config.deployBlock }));
    } catch (e) {
      console.warn('LevelValidated events unavailable', e);
      const retry = make('button', { type: 'button', textContent: 'Retry' });
      retry.addEventListener('click', () => void this.showValidations(player));
      this.links.replaceChildren(
        document.createTextNode('Contract '),
        this.link(short(this.config.address), explorerLink(this.config, 'contract', this.config.address)),
        document.createTextNode(' · your LevelValidated: unavailable ('),
        retry,
        document.createTextNode(')'),
      );
    }
  }

  /**
   * The level (`levelHash`) is over: offer to submit its outputs (recomputed for the connected
   * account); `inputsFor` gives the `Inputs` felts of the attempt for a player (the attestation's
   * replay and the settled tier's calldata).
   */
  offer(levelHash: string, outputsFor: (player: string) => Promise<string[]>, inputsFor?: (player: string) => string[]): void {
    this.round += 1;
    this.levelHash = levelHash;
    this.outputsFor = outputsFor;
    this.inputsFor = inputsFor ?? null;
    this.pending = null;
    this.choice = null;
    this.tiers.hidden = true;
    this.tier.textContent = this.proveBlocked ? this.tier.textContent : '';
    this.outputsInfo.textContent = '';
    this.settle.hidden = true;
    this.say(this.account ? `Connected ${short(this.account.address)}` : 'Connect a wallet to submit this attempt');
    if (this.account) void this.showOutputsFor(this.account.address);
    void this.refreshBoards();
    this.refresh();
    this.root.hidden = false;
  }

  hide(): void {
    this.round += 1;
    this.outputsFor = null;
    this.pending = null;
    this.choice = null;
    this.tiers.hidden = true;
    this.outputsInfo.textContent = '';
    this.root.hidden = true;
  }

  /** m11: the outputs a proof will actually carry, recomputed for the connected account. */
  private async showOutputsFor(player: string): Promise<void> {
    const outputsFor = this.outputsFor;
    if (outputsFor === null) return;
    const round = this.round;
    try {
      const outputs = await outputsFor(player);
      if (round !== this.round) return;
      this.outputsInfo.textContent = `Outputs for ${short(player)}: inputs_hash ${short(outputs[4])}, final_state_hash ${short(outputs[9])}`;
    } catch (e) {
      if (round !== this.round) return;
      this.outputsInfo.textContent = `Outputs for ${short(player)}: failed to recompute (${e instanceof Error ? e.message : e})`;
    }
  }

  private refresh(): void {
    this.send.disabled = this.busy || this.account === null || this.outputsFor === null || (this.settledOnly && this.proveBlocked);
    this.settle.disabled = this.busy || this.account === null || this.pending === null;
    this.connect.disabled = this.busy;
    this.askSettled.disabled = this.busy || this.proveBlocked;
  }

  private say(text: string): void {
    this.status.textContent = text;
  }

  /** Both boards of the level: settled first, then the live one (provisional rows marked). */
  private async refreshBoards(boards?: Boards): Promise<void> {
    const levelHash = this.levelHash;
    if (levelHash === null) return;
    try {
      this.showBoards(boards ?? (await readBoards(this.contract, levelHash)));
    } catch (e) {
      console.warn('boards unavailable', e);
    }
  }

  private showBoards(boards: Boards): void {
    const player = this.account?.address;
    const rows = (list: TierRow[], live: boolean) => {
      const ol = make('ol', { className: live ? 'submit-board provisional' : 'submit-board settled' });
      if (list.length === 0) ol.append(make('li', { className: 'empty', textContent: 'no record yet' }));
      for (const row of list) {
        // A SNIP-36 row's release is its chain's bundle hash, never `current_program()`.
        const older = row.proof !== 'snip36' && BigInt(row.programHash) !== BigInt(boards.currentProgram) ? ' (older release)' : '';
        const li = make('li', { textContent: `${short(row.player)} ${row.score} · ${describeProof(row)}${older}` });
        if (player !== undefined && BigInt(row.player) === BigInt(player)) li.className = 'mine';
        ol.append(li);
      }
      return ol;
    };
    this.boards.replaceChildren(
      make('h4', { textContent: 'Settled (proven: SHARP or SNIP-36)' }),
      rows(boards.settled, false),
      make('h4', { textContent: 'Live (provisional and settled)' }),
      rows(boards.provisional, true),
    );
  }

  private async doConnect(): Promise<void> {
    this.busy = true;
    this.refresh();
    try {
      this.account = await this.deps.connect(this.wallet.value as WalletKind);
      this.say(`Connected ${short(this.account.address)}`);
      void this.showValidations(this.account.address);
      void this.showOutputsFor(this.account.address);
      this.onAccount?.(this.account.address); // m11: the page's outputs table follows the account
    } catch (e) {
      this.say(`Wallet: ${explainWalletError(e)}`);
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
    const inputs = this.inputsFor?.(account.address);
    const onStep = (step: SubmissionStep) => {
      if (step.kind === 'outputs') this.say(`Outputs for ${short(account.address)}; the service replays and attests them…`);
      if (step.kind === 'attested') this.say(`Attested (${step.attestation.verified ? step.attestation.mode : 'WITHOUT a replay: --no-verify service'}); confirm in the wallet…`);
      if (step.kind === 'sent') this.say(`Sent ${step.transactionHash}; waiting for the receipt…`);
    };
    try {
      const result = await submitLevel(
        {
          contract: this.contract,
          account,
          outputsFor,
          attest: (outputs) =>
            requestAttestation(
              this.config.attestUrl,
              this.config.address,
              { outputs, level: outputs[1], inputs, proof: proofPath ? { path: proofPath } : undefined },
              this.deps.fetchFn,
            ),
          waitForReceipt: this.deps.waitForReceipt,
        },
        onStep,
      );
      const { best, gas } = result;
      console.log(`submit ${result.transactionHash}: l2_gas ${gas.l2Gas}, l1_data_gas ${gas.l1DataGas}, fee ${gas.fee} ${gas.unit}`);
      this.say(`Provisional record in ${result.transactionHash} (L2 gas ${gas.l2Gas.toLocaleString()}): your best ${best.score} (${best.won ? 'won' : 'lost'}).`);
      this.showBoards(result.boards);
      void this.showValidations(account.address);
      this.outputsFor = null; // one attested submission per attempt (the nullifier refuses a second)
      this.tier.textContent = 'Provisional (attested)';
      if (this.config.proveUrl && inputs) {
        if (this.config.local) {
          // One proof per attempt: the contract records it proven or settled, not both.
          this.choice = { levelHash: result.validated.levelHash, outputs: result.outputs, inputs };
          this.tier.textContent = 'Provisional (attested) · ask for a proof: proven (SNIP-36) or settled (Atlantic), both simulated here';
          this.tiers.hidden = false;
        } else {
          void this.settleInBackground(result.validated.levelHash, result.outputs, inputs);
        }
      }
    } catch (e) {
      console.error(e);
      this.say(`Submit failed: ${explainWalletError(e)}`);
    }
    this.busy = false;
    this.refresh();
  }

  /** Satellite-only deployment: no attestation; the prover service proves the attempt, then it settles. */
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
      this.say(`Proof requested for ${short(account.address)}.`);
      void this.settleInBackground(outputs[1], outputs, inputs);
    } catch (e) {
      console.error(e);
      this.say(`Prove failed: ${explainWalletError(e)}`);
    }
    this.busy = false;
    this.refresh();
  }

  /** `config.local`: the player asked for the proof of the provisional record at `tier`. */
  private choose(tier: Tier): void {
    const choice = this.choice;
    if (choice === null) return;
    this.choice = null;
    this.tiers.hidden = true;
    void this.settleInBackground(choice.levelHash, choice.outputs, choice.inputs, tier);
  }

  /** What the player may do while the proof runs: nothing with a relay (or on the proven path, where
   * the service records the attempt itself), come back without one. */
  private waitNote(tier: Tier = 'settled'): string {
    if (this.config.local) {
      return tier === 'proven'
        ? 'simulated: the fake prover proves the chain on the devnet, the service records it (about a minute)'
        : "simulated: no Atlantic, the fact goes straight to the devnet's FakeSatellite and the relay settles it (seconds)";
    }
    if (tier === 'proven') return 'you may close this page: the prover service proves the chain and records it for you (SNIP-36)';
    return this.relay
      ? 'you may close this page: the prover service settles it for you when the proof lands (about 1.5 h)'
      : 'the proof takes about 1.5 h; come back to this level to settle it';
  }

  /** `POST /prove` at the proven tier when the service offers it, else (or when the contract's chain
   * turns out not to be the service's) at the settled one; at `tier` when the player picked it. */
  private async request(url: string, levelHash: string, inputs: string[], tier?: Tier): Promise<ProofJob> {
    if (tier) return requestProof(url, levelHash, inputs, this.deps.fetchFn, tier);
    if (this.provenPath) {
      try {
        return await requestProof(url, levelHash, inputs, this.deps.fetchFn, 'proven');
      } catch (e) {
        if (!(e instanceof ChainMismatchError)) throw e;
        this.provenPath = false;
      }
    }
    return requestProof(url, levelHash, inputs, this.deps.fetchFn);
  }

  /** Requests the attempt's proof and follows it until it is proven (SNIP-36: the service records it)
   * or settled: by the relay (nothing to do), or by the player ("Settle", offered as soon as the fact
   * is on the Satellite). */
  private async settleInBackground(levelHash: string, outputs: string[], inputs: string[], tier?: Tier): Promise<void> {
    const url = this.config.proveUrl;
    if (!url) return;
    const round = this.round;
    const stale = () => round !== this.round;
    const prefix = () => (this.settledOnly ? 'Proving' : 'Provisional (attested)');
    const show = (text: string) => {
      if (!stale()) this.tier.textContent = `${prefix()} · ${text}`;
    };
    const opts = { fetchFn: this.deps.fetchFn, sleep: this.deps.sleep, stop: stale, intervalMs: this.config.local ? LOCAL_POLL_MS : undefined };
    try {
      const job = await this.request(url, levelHash, inputs, tier);
      const note = this.waitNote(job.tier);
      show(`${describeJob(job)}; ${note}`);
      const ready = await waitSettleable(url, job.id, (j) => show(`${describeJob(j)}; ${note}`), opts);
      if (ready === null || stale()) return;
      if (ready.proven || ready.relayed || ready.relayState === 'settled') return this.markSettled(levelHash, ready);
      this.pending = { outputs, inputs, programHash: ready.programHash };
      this.settle.textContent = settleLabel(ready);
      this.settle.hidden = false;
      show(describeJob(ready) + (ready.relayState === 'waiting' ? '; the relay is settling it, or settle it yourself' : ''));
      this.refresh();
      const stopped = () => stale() || this.pending === null;
      if (ready.relayState === 'waiting') {
        const relayed = await waitRelayed(url, job.id, () => {}, { ...opts, stop: stopped }).catch(() => null);
        if (relayed && !stopped() && (relayed.relayed || relayed.relayState === 'settled')) await this.markSettled(levelHash, relayed);
      } else if (!ready.settleablePoseidon) {
        // The keccak path settles now; while the service translates the fact, the cheap one may come.
        const relabel = (j: ProofJob) => {
          if (!stopped()) this.settle.textContent = settleLabel(j);
        };
        const upgrade = await waitCheap(url, job.id, relabel, { ...opts, stop: stopped }).catch(() => null);
        if (upgrade && !stopped()) this.settle.textContent = settleLabel(upgrade);
      }
    } catch (e) {
      if (e instanceof ProgramMismatchError) {
        this.proveBlocked = true;
        this.refresh();
      }
      show(e instanceof ProgramMismatchError ? e.message : explainWalletError(e));
    }
  }

  /** The attempt is settled or proven (by the relay, the prover service, someone else, or the
   * player): the settled record and boards. */
  private async markSettled(levelHash: string, job: ProofJob | null, transactionHash?: string): Promise<void> {
    this.pending = null;
    this.settle.hidden = true;
    const player = this.account?.address;
    const proven = job?.proven === true;
    const by = proven
      ? `by SNIP-36${job?.finalizeTransactionHash ? ` (the prover service finalized it in ${job.finalizeTransactionHash})` : ''}`
      : job?.relayed
        ? `by the relay in ${job.relayTransactionHash}`
        : transactionHash
          ? `in ${transactionHash}`
          : 'on Starknet';
    const verb = proven ? 'Proven' : 'Settled';
    this.tier.textContent = `${verb} ${by}`;
    if (player) {
      try {
        const best = await this.contract.bestSettled(player, levelHash);
        const release = proven ? `bundle ${short(best.programHash)}` : `engine ${short(best.programHash)}`;
        this.tier.textContent = `${verb} ${by}: your settled best ${best.score} (${best.won ? 'won' : 'lost'}, ${release})`;
      } catch {
        // the line above already says settled
      }
      void this.showValidations(player);
    }
    await this.refreshBoards();
    this.refresh();
  }

  private async doSettle(): Promise<void> {
    const account = this.account;
    const pending = this.pending;
    if (account === null || pending === null) return;
    this.busy = true;
    this.refresh();
    try {
      const level = await this.contract.levelData(pending.outputs[1]);
      const program = pending.programHash ?? (await this.contract.currentProgram());
      const hash = await this.contract.submitSettled(account, pending.outputs, runArgs(level, pending.inputs), program);
      this.tier.textContent = `Settling in ${hash}…`;
      const receipt = await this.deps.waitForReceipt(hash);
      if (receipt.execution_status === 'REVERTED') throw new Error(`submit_settled reverted: ${receipt.revert_reason ?? 'no reason'}`);
      const [validated] = levelValidatedEvents(receipt, this.contract.address);
      if (!validated?.settled) throw new Error(`submit_settled ${hash}: no settled LevelValidated event`);
      console.log(`submit_settled ${hash}: l2_gas ${receiptGas(receipt).l2Gas}`);
      await this.markSettled(validated.levelHash, null, hash);
    } catch (e) {
      console.error(e);
      // m14: replaces the stale "ready to settle" line with the failure, in plain words.
      this.tier.textContent = `Settle failed: ${explainWalletError(e)}`;
    }
    this.busy = false;
    this.refresh();
  }
}
