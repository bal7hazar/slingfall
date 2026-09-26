# C1 — the client on Sepolia: configuration, hosted build, README for testers

## 1. Read first
`AGENTS.md`; on `main`: `client/README.md`, `client/src/chain/config.ts` (`VITE_*` variables), `client/src/chain/wallet.ts`,
`deploy/sepolia.json` (contract address, class hash, level hashes), `deploy/sepolia.env`, `services/prove/prove_service.py`
(`serve`, `/prove`, `/status`), `services/attest/attest.py`, `docs/e2e.md` (Sepolia variant), `docs/proving.md`.

## 2. Scope (allowlist)
`client/**` (no dependency version bumps), `deploy/sepolia.env.example` (new), `docs/e2e.md`, `docs/testers.md` (new),
`.github/workflows/ci.yml` ONLY to add a `client-build-sepolia` step (build with the Sepolia env) or a Pages deploy
job **disabled by default** (`workflow_dispatch`), `README.md` root "Try it" section.

## 3. Work
1. `client/.env.sepolia` (committed, public values only: `VITE_SLINGFALL_ADDRESS` from `deploy/sepolia.json`,
   `VITE_STARKNET_RPC_URL` = `https://starknet-sepolia-rpc.publicnode.com`, `VITE_NETWORK=sepolia`,
   `VITE_PROVE_URL` empty by default, `VITE_ATTEST_URL` empty) and `npm run build:sepolia` / `npm run dev:sepolia`.
   The wallet list on Sepolia: get-starknet (Braavos / Argent) and Cartridge; the devnet account option hidden.
2. Level list: served from `client/public/levels/` as today; show the on-chain level hash and a link to Voyager
   Sepolia for the contract and for the player's `LevelValidated` transactions.
3. `docs/testers.md`: how to play on Sepolia end to end: open the hosted client (or `npm run dev:sepolia`), connect
   a wallet, play, "Copy inputs", provisional submit (needs an attestation service URL: document how to run
   `attest.py serve` and `prove_service.py serve` locally with the env variables; no keys in the docs), settled
   submit (needs the prover service + ~1.5 h), what each status means, known limits (no browser test has been run
   by the executors: list what to look at, fps, memory, first frame).
4. Hosted build: a GitHub Pages workflow (`workflow_dispatch` only, not on push) that builds `client` with the Sepolia
   env and deploys to Pages (the owner enables Pages in the repository settings; document it). Do not enable
   automatically.
5. A smoke test in CI: `npm run build:sepolia` succeeds and the built `index.html` references the contract address.

## 4. Budget
None.

## 5. Tests
`npm run lint`, `npm test`, `npm run build:sepolia`; CI green.

## 6. Definition of done
`AGENTS.md` §6 client part; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`;
push `feat/c1-client-sepolia`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`.

## 7. Work autonomously, do not ask questions, do not widen the scope.
