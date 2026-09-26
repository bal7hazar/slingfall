# E3b — settled validation: `SatelliteVerifier`, prover service, Sepolia deployment, first settled submit (M5)

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D9 (two-class contract, verifiers, two-tier validation); **`docs/proving.md`
"Atlantic + Integrity"** and the E3a report's "Fact formula" / "E3b contract spec" (`tools/atlantic/{atlantic,encoding}.py`,
`test_atlantic.py`: `FactChain`, the constants `CHILD_PROGRAM_HASH`, `ATLANTIC_BOOTLOADER_PROGRAM_HASH`,
`SHARP_BOOTLOADER_PROGRAM_HASH`, the Satellite address on Sepolia, `isCairoFactValid` /
`get_all_verifications_for_fact_hash`, `tools/atlantic/c1main`); on `main`: `crates/slingfall_contract/`
(`Slingfall`, `verifier.cairo`: `Verifier` trait, `Snip36Verifier`, `StubVerifier`, `VerifierKind`; `submit`),
`services/attest/`, `deploy/` (`slingfall.ts`, `sepolia.sh`, `devnet.sh`, `e2e.sh`), `client/src/chain/`,
`fixtures/proofs/atlantic/*.json` (the two on-chain facts of E3a: use them as goldens).

## 2. Credentials
`ATLANTIC_API_KEY`, `STARKNET_RPC_URL` (send a `User-Agent`), `STARKNET_ACCOUNT_ADDRESS` / `_PRIVATE_KEY` / `_ACCOUNT_TYPE=braavos`
are in your environment. **This lot may send transactions from the Sepolia account** (declare + deploy `Slingfall`,
admin setters, `register_level` x 6, one `submit`); never print the values; report every transaction hash and fee.

## 3. Scope (allowlist)
`crates/slingfall_contract/**`, `steps/slingfall_contract/*.snap`, `services/prove/**` (new) or an extension of
`services/attest/`, `deploy/**`, `client/src/chain/**` + `client/src/**` only for the status display,
`docs/e2e.md`, `docs/proving.md` (sections), `fixtures/proofs/**` (small), `.github/workflows/ci.yml` ONLY to add the
`tools/atlantic` unit tests to an existing job.

## 4. Work
1. **`SatelliteVerifier`** (`verifier.cairo`, new `VerifierKind::Satellite`, default on Sepolia): from `submit`'s
   calldata (`level` felts, `inputs` felts, `outputs`), recompute `args`, `task`, `out` and `integrity_fact` exactly
   as `encoding.py` (constants in storage, admin-settable: `child_program_hash`, `atlantic_bootloader_hash`,
   `sharp_bootloader_hash`, `satellite_address`), call the Satellite's `isCairoFactValid(fact, false)` (or read the
   verifications and require `security_bits >= 96`), and accept. `submit(level, inputs, outputs, evidence)` may need
   the level and inputs felts as calldata for this verifier (the attested path passes `[r, s]`): keep one entry point
   with `evidence` typed by the active verifier, or add `submit_settled(level_hash, inputs, outputs)` reading the level
   felts from storage (cheaper calldata; the registry already holds them). Two tiers: records carry `settled: bool`;
   an attested record may later be upgraded to settled by a second `submit` with the same nullifier (allow exactly
   this upgrade path). snforge tests with the E3a facts as vectors (the Satellite call mocked / cheated).
2. **Prover service** (`services/prove/prove_service.py`, stdlib): `POST /prove {level, inputs}` → builds the PIE
   (`c1main` through the patched fork, as `atlantic.py c1-input` does), submits to Atlantic with
   `PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION`, declared size by steps, `dedupId` = hash of the inputs; `GET
   /status/<id>` → Atlantic status + `check-fact` result; a job store on disk. Reuse `tools/atlantic`.
3. **Client**: after the attested submit, show "provisional"; poll `/status`; when the fact is on the Satellite,
   offer "Settle on Starknet" (`submit` settled) and show "settled". `deploy/e2e.sh` extended with a mocked settled
   path on the devnet (a fake Satellite contract in `deploy/contract/` returning true for the golden fact).
4. **Sepolia**: `deploy/sepolia.sh` for real: declare + deploy `Slingfall`, set verifiers and constants, register
   the six levels; then the settled `submit` of `pile10-reference` for the owner's account: the E3a fact was proven
   for a different `player` felt, so first re-run the whole pipeline once for the deployed account (`/prove` with
   `player` = the account; ~1.5 h of Atlantic latency: poll in the foreground with generous sleeps, your turn must
   not end), then `submit`; read `best` / `leaderboard`; write `deploy/sepolia.json` (addresses, class hash, level
   hashes, tx hashes). If the Atlantic latency exceeds your session, write the job id in `fixtures/proofs/atlantic/`
   and the exact resume command in REPORT.md.

## 5. Budget
`submit` settled ≤ 2x the attested `submit` (5.5M L2 gas on devnet); report Sepolia fees.

## 6. Tests
Contract tests (E3a vectors, upgrade path, wrong constants rejected); `tools/atlantic` tests in CI; e2e mocked path
green; Sepolia transcript in the report.

## 7. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
push `feat/e3b-satellite-sepolia`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · Contract API · Sepolia transcript (addresses, tx hashes, fees) · Deviations · Escalations · PR URL).
Work autonomously, do not ask questions, do not widen the scope.
