# W3 — wire the deploy scripts, the services and the client to contract v3 (proven tier), devnet only

## 1. Read first
`AGENTS.md`; `docs/contract-v3.md` and lot V3's escalations 2 and 3 (in `docs/PLAN.md` row V3 and the pull request
#40 description); `docs/research/07-split-game-step.md` §4; `docs/contract-v2.md` "Wiring (lot W1)";
`/home/claude/projects/pm/research/SN1-snip36-library-call.md` §5 and §7 (the prover, the toy experiment);
`crates/slingfall_split/**` (read only except §2); `deploy/**`, `services/prove/**`, `client/src/chain/**`.

## 2. Scope (allowlist)
`deploy/**` except `deploy/sepolia.json`, `services/prove/**`, `client/src/chain/**`, `client/src/main.ts` (chain wiring
only), `docs/proving.md`, `docs/e2e.md`, `docs/testers.md`, `docs/contract-v3.md`; in `crates/slingfall_split/**` only
what escalation 2 of V3 requires (a test that `SplitChain` has no setter of its class hashes and that its marker
equals the contract's default, payload layouts documented as API). No Sepolia transaction, no credentials; everything
proven on the local devnet. No real SNIP-36 proof can be made today (PROOF2 is not confirmed on Sepolia, and the
prover needs a large machine): the proving step sits behind an interface with two implementations, `fake` (devnet:
builds the proof facts the contract expects and sends them through the devnet's cheat or a test account class) and
`snip36` (calls `starknet_proveTransaction` of a configured prover URL; written, unit-tested against recorded
answers, not run).

## 3. Work
1. **Deploy scripts**: `upgrade` of a v2 deployment to the v3 class (devnet: deploy v2 from the v2 class hash recorded
   in `deploy/sepolia.json`'s build, upgrade, read every v2 value back); declare the split classes and deploy
   `SplitChain`; `set-chunk-marker`, `pin-virtual-os`, `pin-chain` (bundle hash = hash of the ordered class hashes,
   computed by the script and printed), `revoke-*`; `boards` and `attempt` understand `PROVEN`.
2. **Prove service**: a SNIP-36 path beside Atlantic's: run the chain locally (scheduler picking `k` so each
   transaction stays under 9M steps, from the split crate's executables or through the devnet), prove every
   transaction in parallel through the prover interface, send one real Invoke per proof calling `submit_chunk` per
   message, then `finalize` (relay allowed); `/status` reports the tier being produced and each proof's state; the
   program check uses `chain_valid_until` / `chain_bundle`.
3. **Client**: `attempt` = 3 (proven); rows of the settled board say which proof (settled by SHARP or proven by
   SNIP-36) and the release (bundle hash or program hash); `LevelValidated.proven` exposed; the panel offers the proven
   path when the service says it is available, the settled path otherwise.
4. **e2e on the devnet**: provisional -> proven through the fake prover (whole chain of the pile10 reference shot,
   layout e), then a second account's provisional -> settled through the existing path; a retired chain refused after
   its grace; v2 -> v3 upgrade keeping a v2 record. The `e2e` CI job stays under 10 minutes.
5. **Cost sheet** in `docs/proving.md`: per shot, number of proofs, L2 gas of `submit_chunk` and `finalize` (measured
   on the devnet), plus the protocol's 75M L2 gas per proof, in STRK at Sepolia's current gas price read from the
   public RPC (read-only call allowed).

## 4. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push
`feat/w3-v3-wiring`; `gh pr create`; `gh pr checks --watch` in the foreground until green, `e2e` included; never
merge; `REPORT.md`. Foreground only. Heavy runs one at a time under the heavy-run lock. Work autonomously, do not ask
questions, do not widen the scope. At most 2 parallel jobs.
