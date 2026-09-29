# L1 — play the whole game locally with one command (macOS and Linux)

## 1. Read first
`AGENTS.md`; `docs/testers.md`, `docs/e2e.md`, `docs/proving.md` ("Client / service flow", "SNIP-36");
`deploy/devnet.sh`, `deploy/e2e.sh`, `deploy/devnet.env` (generated), `services/attest/attest.py`,
`services/prove/prove_service.py` (`--snip36 fake`), `client/package.json`, `client/src/chain/config.ts`,
`client/vm/scripts/` (the wasm runner build).

## 2. Goal
The owner wants to play on their own machine (a Mac, Apple silicon) before any hosting. One command brings up
everything and prints the URL to open; the three validation tiers work with no credential, no testnet, no wallet
extension:
`scripts/play.sh` (or `up`), `scripts/play.sh down`, `scripts/play.sh status`, `scripts/play.sh doctor`.

## 3. Scope (allowlist)
`scripts/play.sh` (new), `scripts/play/**` (helpers), `docs/play-local.md` (new), `README.md` (a "Play locally"
section of at most 15 lines), `docs/testers.md` (a pointer), `client/src/chain/**` and `client/src/main.ts` only if the
local mode needs a fix (devnet account as the player, service URLs from the generated env), `services/**` only for
bind address / CORS / port options and the defect of §4.6, `deploy/devnet.sh` only for options the script needs,
`.github/workflows/ci.yml` (one job `play-local` on ubuntu, under 10 minutes). No Sepolia transaction, no credentials.

## 4. Work
1. `doctor`: checks the prerequisites and says how to install what is missing, without installing anything itself
   except through the documented project tools: Node (version of `.tool-versions`), scarb and snforge (asdf), Rust
   (only if the wasm runner must be built), python3, free ports; macOS (arm64) and Linux (x86_64).
2. `up`: the local devnet (contract v3, proven tier opened), the attestation service in `--execute` mode with the
   public devnet test key, the prove service with the fake SNIP-36 prover and the fake Satellite for the settled
   tier, the client dev server in devnet mode; everything bound to 127.0.0.1; logs under `target/play/`; PIDs
   tracked so `down` stops exactly what `up` started; idempotent (a second `up` reuses what runs).
3. The page in that mode: the player is a devnet account (no extension); after a shot the player gets the provisional
   record in seconds, then can ask for the proven tier (fake prover) and for the settled tier (fake Satellite), and
   sees both boards. A banner says "local devnet: proofs are simulated".
4. Build caching: the wasm runner and the Cairo executables are fetched or built once; a second `up` starts in under
   30 seconds (measure and report first and second start on this machine).
5. `docs/play-local.md`: prerequisites, the one command, what each tier means locally versus on Sepolia, how to reset
   the devnet, troubleshooting (ports, Node version, Safari and local network access), how to play from another
   device of the same network by IP (`PLAY_HOST=0.0.0.0`, with the warning that the services then listen on the
   network and must never be exposed to the internet in this mode).
6. Fix the defect reported by lot B6: `atlantic.account_env` prefers `STARKNET_RPC` over `STARKNET_RPC_URL`, so a
   devnet job can read another network when both are set: the local mode must ignore the user's `STARKNET_*`
   variables and say so.
7. CI job `play-local`: `up`, a headless shot through the page or the same calls the page makes (provisional, proven,
   settled), `status`, `down`.

## 5. Definition of done
`AGENTS.md` §6; conventional commits with the trailer of the model you are; push `feat/l1-play-local`;
`gh pr create`; `gh pr checks --watch` in the foreground until green; never merge; `REPORT.md` (what was run on this
Linux machine, what could not be verified on macOS and why). Foreground only. Work autonomously, do not ask
questions, do not widen the scope. At most 2 parallel jobs.
