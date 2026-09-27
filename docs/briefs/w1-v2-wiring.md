# W1 — wire the client, the services and the deploy scripts to contract v2 (same branch as V2, no deployment)

## 1. Read first
`AGENTS.md`; `docs/contract-v2.md` and `REPORT.md` at the worktree root (lot V2: API, escalation 2 lists every
interface change to follow); `docs/research/06-fast-validation.md` §2.1-2.2; `docs/qa/2026-09-26-mac.md` S10, m11;
`docs/proving.md` ("Program match", lot Q3); `deploy/**`, `services/attest/**`, `services/prove/**`,
`client/src/chain/**`, `client/src/main.ts`.

## 2. Scope (allowlist)
`deploy/**` except `deploy/sepolia.json` (lot B4 is writing it; a v2 deployment is a later lot), `services/**`,
`client/src/chain/**`, `client/src/main.ts` (outputs table and chain wiring only), `client/package.json` (one
devDependency for DOM tests, allowed here), `docs/proving.md`, `docs/e2e.md`, `docs/testers.md`, `docs/contract-v2.md`.
Forbidden: `crates/**` (escalate contract defects instead), `client/src/vm/**` (lot Q2), `client/src/game/**`,
`client/src/render/**`, `client/src/aim/**`, fixtures, goldens. No Sepolia transaction, no credentials: everything is
proven on the local devnet (`deploy/devnet.sh`, `deploy/e2e.sh`).

## 3. Work
1. **Deploy scripts**: 3-field `SatelliteConfig`, `pin_program(hash, grace_s)` (default grace 86 400 s for a
   bit-compatible re-pin, 0 otherwise, explicit flag), `revoke-program`, `set_attestation_key`, two-step admin,
   `upgrade`; a fresh deployment does key + pin + config + levels; Q3's unsettled-jobs warning now guards `pin`.
2. **Attest service**: `--execute` mode (re-executes the replay natively and signs when the outputs match; keep
   `--verify-cmd`), v2 message (`chain_id, contract, program_hash, epoch, expiry, outputs`), evidence
   `[program_hash, expiry, r, s]`, epoch read from the contract, rate limit per player.
3. **Prove service**: program check through `program_valid_until(hash) > now`; `child_program_hash` passed to
   `submit_settled`; optional relay (`--relay`, account from the environment, off by default): when the fact lands
   and a simulation of `submit_settled` succeeds, the service sends it for `claim.player`; `/status` reports
   `relayed` with the transaction hash; the player can still settle themselves.
4. **Client**: flow "play -> provisional record in seconds (attested submit) -> proof requested in the background ->
   settled by the relay or by the player"; `Best` with 7 fields, `best_settled`, `leaderboard` (settled) and
   `leaderboard_provisional` shown as two tiers with the engine release (`program_hash`) of each row; the main outputs
   table recomputed for the connected account (m11); the page no longer asks the player to keep it open.
5. **e2e**: `deploy/e2e.sh` runs both tiers on the devnet, including a relayed settle by a third account, a re-pin
   with grace (old proof settles inside the window, refused after), an expired provisional record. The `e2e` CI job
   is green.
6. Tests for every service change (fakes), DOM tests for the chain panel.

## 4. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push
to `feat/v2-contract` (pull request #33 already exists: update its description); `gh pr checks 33 --watch` in the
foreground until green, `e2e` included; never merge; append a "W1" part to `REPORT.md`. Foreground only: never end
your turn on a background command or a scheduled wakeup. Work autonomously, do not ask questions, do not widen the
scope. At most 2 parallel jobs.
