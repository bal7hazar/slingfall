# E3c — Poseidon settlement path: translate the SHARP fact on the Satellite ourselves when Atlantic's translation stalls

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D9; E3b's report notes in `docs/PLAN.md` (E3b row: translated path 0.79x the attested
submit vs keccak 2.12x; Atlantic's `PROOF_VERIFICATION_ON_L2_WITH_TRANSLATION` stalled in E3a and E3b); on `main`:
`services/prove/prove_service.py` (`/status`, `settleable`), `tools/atlantic/{atlantic,encoding}.py` (`check-fact`,
the Satellite address and ABI calls `isKeccakVerifiedFactHashValid`, `isCairoFactValid`), `deploy/sepolia.sh` (`settle`),
`deploy/slingfall.ts` (starknet.js account calls), `fixtures/proofs/atlantic/pile10-reference-sepolia.json`
(the settled run: its keccak fact is on the Satellite, its Poseidon fact is not), HerodotusDev/satellite on GitHub
(the `translateFactHash` entry point: name, arguments, events; read the Cairo source of the Satellite's Starknet
module, `deployed` address on Sepolia as in `encoding.py`).

## 2. Credentials
`STARKNET_*` in your environment (Braavos dev account). This lot MAY send `translateFactHash` transactions (one per
fact) and one `submit_settled` upgrade test if a fresh attested record exists; report hashes and fees. Never print values.

## 3. Scope (allowlist)
`services/prove/**`, `tools/atlantic/**`, `deploy/sepolia.sh`, `deploy/slingfall.ts` (a `translate` command),
`docs/proving.md` section, `fixtures/proofs/atlantic/**` (small), `client/src/chain/**` only if the status wording changes.

## 4. Work
1. `atlantic.py translate <sharp_fact>` and `deploy/slingfall.ts translate`: call the Satellite's permissionless
   `translateFactHash` for a fact whose keccak verification exists; then `check-fact` shows `isCairoFactValid = true`.
   Run it on Sepolia for the E3b fact (`0xced287ce…3fb5d6`); record the tx hash and fee.
2. Prover service: when Atlantic's status is DONE (keccak fact on the Satellite) and the translated fact is absent
   after `TRANSLATE_GRACE` (default 10 min), the service translates it itself (account from env, optional: without
   an account it just reports `settleable_keccak`); `/status` exposes `settleable_poseidon` and `settleable_keccak`.
3. Client: prefer the Poseidon path when available (cheaper), else keccak; wording "Settle (cheap)" / "Settle".
4. Measure on Sepolia if a fresh attempt is available (else on the devnet `FakeSatellite`): `submit_settled` gas on the
   Poseidon path vs the E3b keccak figure (18.8M L2 gas).

## 5. Tests
Service unit tests (translation decision), `tools/atlantic` tests, `deploy/e2e.sh` still green.

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/e3c-translate-fact`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`.

## 7. Work autonomously, do not ask questions, do not widen the scope.
