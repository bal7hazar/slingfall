# D2 — deploy contract v2 on Starknet Sepolia, both tiers proven end to end

## 1. Read first
`AGENTS.md`; `docs/contract-v2.md` (incl. "Wiring (lot W1)"); `docs/e2e.md`; `docs/proving.md`; `docs/testers.md`;
`deploy/sepolia.sh` (header), `deploy/slingfall.ts`; `deploy/sepolia.json` (the v1 deployment, lot E3b / B4);
`docs/PLAN.md` rows E3b, E3c, B4.

## 2. Credentials and transactions
In your environment: `STARKNET_*` (admin account, Sepolia), `ATLANTIC_API_KEY`, `SLINGFALL_ATTEST_KEY` (the attestation
service's private key). Never print, log or commit a value. The attestation PUBLIC key is
`0x66ca673bb9a69e143f1072eda143886e2349baf4c996f200b06f7e3d4ddbf4` (check it with `attest.py pubkey`).
Transactions this lot MAY send on Sepolia, and no other:
1. the fresh v2 deployment of `deploy/sepolia.sh deploy`: declare + deploy `Slingfall` v2, its configuration
   (`set_attestation_key`, `pin_program` of c1main alpha.6 `0x580ef5d1896ce36ddc0309eed11218303ed39d1c30ad8ccea4d194be3edf75a`,
   `set_satellite_config` with the v1 deployment's Satellite constants, verifier `stub` = both tiers), the six levels;
2. one attested `submit` (pile10 reference shot, player = the admin account) with an attestation made by a local
   `attest.py serve --execute` bound to 127.0.0.1;
3. one settled upgrade of the same attempt: one Atlantic job (pile10 reference, alpha.6 program) through
   `services/prove` bound to 127.0.0.1, then `submit_settled` relayed by the service (`--relay`, relayer = the admin
   account) on the keccak fact (no translation transaction);
4. on the OLD v1 contract: `set_level_active(hash, false)` for its six levels (it stays readable).
Budget: 60 STRK in total; stop and report if an estimate exceeds it. Simulate or estimate every transaction first.

## 3. Scope (allowlist)
`deploy/sepolia.json` (v2 record; keep the v1 record under a `"v1"` key), `deploy/sepolia.env`, `client/.env.sepolia`
(public values only: address, deploy block), `client/src/chain/config.test.ts` expectations, `docs/proving.md`,
`docs/testers.md`, `docs/e2e.md` (deployment tables, measured gas and latencies), `fixtures/proofs/**` (the new run's
public records). A defect found in `deploy/**`, `services/**` or `client/src/chain/**` may be fixed by the smallest
change, listed in the report. Nothing else.

## 4. Work
1. Dry run on the devnet first (`deploy/e2e.sh`), then Sepolia step 1; read everything back (`program`, `boards`,
   `satellite_config`, levels, epoch).
2. Provisional tier: measure "request attestation -> provisional record on chain" (seconds, gas, fee).
3. Settled tier: measure each stage (PIE, Atlantic, SHARP, bridge, relay) as the QA report did; the turn may wait
   up to 3 hours for the fact, in the foreground, polling every 2 minutes; if the fact has not landed by then, stop
   the services cleanly, record the job id and what remains (`deploy/sepolia.sh settle JOB`), and finish the rest.
4. Client: `npm run build:sepolia` and `smoke:sepolia` against v2; `boards` shows the record in its tier(s).
5. Stop every service you started. Leave no key on disk outside the environment.

## 5. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push
`feat/d2-sepolia-v2`; `gh pr create`; `gh pr checks --watch` in the foreground until green; never merge; `REPORT.md`
(addresses, every transaction hash with gas and fee, latencies, total STRK spent, what is left to do). Foreground
only: never end your turn on a background command or a scheduled wakeup. Work autonomously, do not ask questions, do
not widen the scope. At most 2 parallel jobs.
