# Q3 — prover service and chain panel: refuse early, tell the truth (QA M6, m10, m11, m13, m14)

## 1. Read first
`AGENTS.md`; `docs/qa/2026-09-26-mac.md` phase 3, sections M6, M7, m10, m11, m13, m14, suggestions S4, S12;
`docs/proving.md`; `services/prove/`; `client/src/chain/**`; `deploy/sepolia.sh`, `deploy/sepolia.json` (read only).

## 2. Scope (allowlist)
`services/prove/**`, `client/src/chain/**`, `client/.env.sepolia` (public values only), `deploy/sepolia.sh` (the
warning of 3.4 only), `docs/proving.md`, `docs/testers.md` (the settled-tier section only). No contract change (M7's
grace period is a later contract lot), no transaction, no credentials: tests use fakes / recorded RPC answers; one
read-only check against Sepolia's public RPC is allowed.

## 3. Work
1. **M6**: `POST /prove` reads the contract's `satellite_config()` and answers 409 with both hashes when the
   service's `c1main` program hash differs; `/status` exposes `program_hash`, `contract_program_hash` and a
   `settleable` that is true only if the fact exists AND the contract would accept it (config match, or a
   `submit_settled` simulation); the page shows both hashes and blocks Prove on a mismatch with a clear sentence.
2. **m10**: `getEvents` from the deployment block (`VITE_DEPLOY_BLOCK`, value from `deploy/sepolia.json`'s deploy
   transaction; add the key to the config test), paged, with one retry; a visible "unavailable, retry" state.
3. **m11**: the outputs table is recomputed for the connected account. **m13**: translation reported `off` when
   disabled. **m14**: status lines replaced, not appended, after Settle and after a failure; wallet errors shown in
   the panel in plain words ('submit: proof' = the contract refuses this program or fact).
4. `deploy/sepolia.sh set-config` prints a warning listing unsettled jobs found under `services/prove/out` and
   asks for `--yes` to continue.

## 4. Definition of done
`AGENTS.md` §6 (client: `npm run lint`, `npm test`, `npm run build` in `client/`); conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push the branch; `gh pr create`; `gh pr checks --watch` until green (foreground); never merge; `REPORT.md` (Summary, per-defect status with the evidence, measurements, deviations, escalations, PR URL). Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs. Another lot (B4) is regenerating fixtures and goldens: do not touch `client/vm/fixtures/**`, `client/public/levels/**`, `fixtures/**`, `steps/**`, `deploy/sepolia.json`. Branch `feat/q3-chain-prover-checks`.
