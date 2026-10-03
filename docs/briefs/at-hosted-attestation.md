# AT — the client uses the hosted attestation service; one provisional submission through it on Sepolia

Profile `impl-sonnet` (a known path, D2's, against a new endpoint). Lot id `at-hosted-attestation`, branch
`feat/at-hosted-attestation`.

## 1. Goal and context

The owner has installed the attestation service (HS, #71) on the VPS, at revision 3efb4ef. It answers at
`https://attest.bal7hazar.com` (`/health`), and the allowed browser origin is `https://slingfall.bal7hazar.com`. The
owner then rotated contract v2's attestation key:
- `set_attestation_key`, tx `0x702c0989…7efe2e`, block 16007385;
- `attestation_key()` = `0x1d569abb…120a1d`, `attestation_epoch()` = 2;
- the record is PR #83.

So attestations from any other key no longer verify.

This lot:
1. points the client's Sepolia build at the hosted service;
2. proves the whole provisional path once, end to end, on Sepolia, through the hosted service.

It follows D2's method, measured in `docs/e2e.md` ("Provisional tier": the admin account's pile10 shot,
`deploy/outputs.py`, `POST /attest`, then `submit(outputs, [program_hash, expiry, r, s])`; 18.0 s from the request to
the provisional record on chain, then on a local service).

Read first: `docs/e2e.md` (the D2 tables and the "Provisional tier" section), `docs/contract-v2.md` ("Attestations"),
`services/attest/attest.py` (`request`), `deploy/slingfall.ts` (`submit`, `best`, `attempt`), `deploy/outputs.py`,
`client/.env.sepolia`, `client/src/chain/config.test.ts`, and `docs/testers.md`.

## 2. Credentials and transactions

`STARKNET_*` (the admin account, which is also the relayer by the owner's decision) are in your environment: never
print them or commit them. Transactions this lot MAY send on Sepolia, and no other:
- **exactly one** `submit` (the provisional tier) of contract v2 at
  `0x292f4b7dcbdb3ee7e5c3d1873e36ac03c71f3d4d5146ff009bcdf6e8bca4a02`, with an attestation from
  `https://attest.bal7hazar.com`, by the admin account, of one pile10 shot.
  - Choose a shot whose score beats the account's current `best` on pile10 (read it first, `node deploy/slingfall.ts
    best`), so the record visibly changes. The owner's shot (-1022, -63, 5,300) is a candidate.
  - If no shot beats it, submit the reference shot anyway, and say what was read back.

Nothing else: no key rotation, no pin, no deployment, no other submit. If the first `submit` fails, report the error
text and stop; do not retry without my line.

## 3. Scope (allowlist)

- `client/.env.sepolia`: `VITE_ATTEST_URL=https://attest.bal7hazar.com`, with its comment updated (the hosted service,
  the allowed origin).
- `client/src/chain/config.test.ts`: only if a test pins the attest URL.
- `deploy/sepolia.json`: the record the scripts write for the submit (its hash and gas).
- `docs/e2e.md`: a short "Provisional tier, hosted service (AT)" table next to D2's: the stages and their seconds, the
  tx hash, the gas and the fee.
- `docs/testers.md`: one line, if it names the attestation URL.
- `REPORT.md` (not committed).
- Not the contract, not the services' code, not the hosting files.

## 4. Work

1. Update `client/.env.sepolia` and run `npm run build:sepolia` to check that the build picks the URL up (no
   deployment of the build).
2. `GET https://attest.bal7hazar.com/health`: record the answer. Its public key must equal `attestation_key()` read
   from the contract (`node deploy/slingfall.ts …`, read-only). If they differ, stop before any transaction.
3. Read the admin's current `best` on pile10, and choose the shot (§2).
4. Request the attestation from the hosted service (`attest.py request --url https://attest.bal7hazar.com …`, or the
   client's code path). Measure the latency of `POST /attest` from the VPS (wall time, real output).
5. Send the one `submit`. Measure: sign and send, and inclusion (to the receipt).
6. Read the record back: `best` on pile10 for the admin account, and the `LevelValidated` event of the transaction.
7. Report:
   - the attestation latency;
   - the tx hash and block;
   - L2 gas, L1 data gas and the fee;
   - the read-back.
   Compare them with D2's figures.

## 5. Machine

The VPS. No Cairo build. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer. Run `scripts/prepush.sh` before pushing.
- Push `feat/at-hosted-attestation` once, then `gh pr create`. At most one `gh` call every 5 minutes.
- Never merge; launch no agent and no review.
- `REPORT.md`: the measurements of §4.7, and the transaction with its voyager link.

Work autonomously, do not ask questions, do not widen the scope.
