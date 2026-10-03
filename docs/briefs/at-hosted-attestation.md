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
  `https://attest.bal7hazar.com`, by the admin account, of **one golden case the admin account has never submitted on
  this contract**.
  - **Not `pile10-reference`:** D2 submitted it, so its nullifier is spent and `submit` would panic
    (`SUBMIT_NULLIFIER`).
  - Take `tower-reference` (or another `*-reference` case in `fixtures/golden/` on a registered level). Before anything
    else, read its attempt with `node deploy/slingfall.ts attempt …` and check that it is unused.
  - The owner's shot is out: `deploy/outputs.py` takes only golden cases.
- A fee estimation that fails sends no transaction. If the `submit` itself is sent and reverts, it counts as the one
  transaction: report the revert and stop.

Nothing else: no key rotation, no pin, no deployment, no other submit. If the first `submit` fails, report the error
text and stop; do not retry without my line.

## 3. Scope (allowlist)

- `client/.env.sepolia`: `VITE_ATTEST_URL=https://attest.bal7hazar.com`, with its comment updated (the hosted service,
  the allowed origin).
- `client/src/chain/config.test.ts`: only if a test pins the attest URL.
- `deploy/sepolia.json`: no script writes a record for `submit`, so add one by hand, under a **new** key
  (`submit (attested, hosted) <case>`), with its hash and gas in the file's format. Never overwrite D2's
  `submit (attested) pile10`.
- `docs/e2e.md`: a short "Provisional tier, hosted service (AT)" table next to D2's: the stages and their seconds, the
  tx hash, the gas and the fee.
- `docs/testers.md`:
  - the provisional tier now uses `https://attest.bal7hazar.com`;
  - the service allows only the origin `https://slingfall.bal7hazar.com`, so `npm run dev:sepolia` on localhost gets a
    CORS refusal for the provisional step: say how a tester points `VITE_ATTEST_URL` at a local service instead;
  - and (from the review of #83) line 21 still gives the old key `0x66ca673b…bf4` at epoch 1: update it to the current
    key and epoch 2.
- `docs/e2e.md` line 259: the same old key, updated to the current one (deferred from #83's review).
- `REPORT.md` (not committed).
- Not the contract, not the services' code, not the hosting files.

## 4. Work

1. Update `client/.env.sepolia` and run `npm run build:sepolia` to check that the build picks the URL up (no
   deployment of the build).
2. `GET https://attest.bal7hazar.com/health`: record the answer. Its public key must equal the contract's
   `attestation_key()`: read it with `node deploy/slingfall.ts snapshot --config deploy/sepolia.json` (read-only), and
   compare the two **as numbers** (padding and case may differ). If they differ, stop before any transaction.
3. Read the chosen case's attempt and the admin's current `best` on its level (`attempt` and `best`, read-only).
4. Produce the outputs: `python3 deploy/outputs.py --case <case>`. This builds and runs the replay, a heavy Cairo run:
   run it under `flock -w <s> ~/orchestrator/heavy-build.lock env HEAVY_BUILD_LOCK_HELD=1 …`, wrapped in
   `/usr/bin/time -v`, and report its peak RSS, its wall time and `free -m` at the start.
   Then request the attestation:
   `python3 services/attest/attest.py request --url https://attest.bal7hazar.com --level <level> --inputs <outputs.json>`.
   Measure the latency of `POST /attest` from the VPS (wall time, real output).
5. Send the one `submit`: `node deploy/slingfall.ts submit --config deploy/sepolia.json --outputs <outputs.json>
   --attestation <the answer's evidence>`. Measure: sign and send, and inclusion (to the receipt).
6. Read the record back: `best` on that level for the admin account, and the `LevelValidated` event of the
   transaction.
7. Report:
   - the attestation latency;
   - the tx hash and block;
   - L2 gas, L1 data gas and the fee;
   - the read-back.
   Compare them with D2's figures.

## 5. Machine

The VPS. The replay run of §4.4 goes under the heavy lock. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer. Run `scripts/prepush.sh` before pushing.
- Push `feat/at-hosted-attestation` once, then `gh pr create`. At most one `gh` call every 5 minutes.
- Never merge; launch no agent and no review.
- `REPORT.md`: the measurements of §4.7, and the transaction with its voyager link.

Work autonomously, do not ask questions, do not widen the scope.
