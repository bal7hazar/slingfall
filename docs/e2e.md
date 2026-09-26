# End to end: play, attest, submit (lot G9)

The interim submission path of `docs/DESIGN.md` D9 (research 01 §4 rank 2): the contract runs
`StubVerifier`, which accepts a claim of `Outputs` when `evidence = [r, s]` is a Stark-curve
ECDSA signature, by the attestation key the admin set, of `poseidon_hash_span(outputs felts)`.
The attestation service signs only after the local prover's `verify` (lot P1) accepts a proof
whose public output is those outputs. The SNIP-36 path (`Snip36Verifier`) replaces the service
later; the client and `submit` do not change.

```
play (client, Cairo VM in the browser) ──> 10 output felts (player = the wallet)
prove (P1, tools/prove/prove.py) ──> proof ──> POST /attest {outputs, proof_path}
attest.py: verify.py <proof> <outputs.json> ──> sign poseidon(outputs) ──> [r, s]
wallet: submit(outputs, [r, s]) ──> nullifier, StubVerifier, best, leaderboard, LevelValidated
```

## Pieces

| path | role |
|---|---|
| `deploy/contract/` | a package of its own that builds the registry class `Slingfall` with its CASM (the crate builds Sierra only); `SlingfallSim` is never declared (over the CASM limit, D11) |
| `deploy/slingfall.ts` | starknet.js tool (Node 24 runs it as is): `deploy`, `submit`, `best`, `leaderboard`, `account`, `class-hash` |
| `deploy/devnet.sh` | installs and starts `starknet-devnet --seed 0`, deploys, writes `deploy/devnet.json` and `deploy/devnet.env` |
| `deploy/outputs.py` | a golden case replayed with `scarb execute` (`main`) for another player |
| `deploy/e2e.sh` | the scripted check below |
| `deploy/sepolia.sh` | the Sepolia deployment (owner's keys from the environment; not run by the lots) |
| `deploy/snfoundry.toml` | `sncast` profiles for manual calls |
| `services/attest/attest.py` | the attestation service (`serve`, `sign`, `pubkey`, `request`), Python standard library, signing with `crates/slingfall_contract/tools/vectors.py` |
| `client/src/chain/` | the client's Submit step: wallet, attestation client, `submit`, reads |

## Setup

Node 24, Python 3, scarb 2.19.4 (`.tool-versions`). Then:

```sh
npm --prefix client ci
scarb --manifest-path crates/slingfall_replay/Scarb.toml build   # the replay executables (outputs.py)
```

`deploy/devnet.sh` installs `starknet-devnet` when it is not on `PATH`: the release binary of
`0xSpaceShard/starknet-devnet` for Linux x86-64 (`DEVNET_VERSION=x.y.z` pins one, else the
latest) into `deploy/.devnet/bin/`, else `cargo install -j 2 --locked starknet-devnet`. The
devnet must speak RPC 0.10 (starknet.js 10) and accept Sierra 1.9 (Cairo 2.19); the version used is
printed at start (`devnet: starknet-devnet x.y.z on ...`).

## The scripted check

```sh
deploy/e2e.sh            # add --keep to leave the devnet up
```

It starts a fresh devnet on port 5055, deploys (`verifier = Stub`, attestation key of the public
test secret `'slingfall-devnet'`, the six fixture levels), replays `fixtures/golden/pile10-reference`
(one shot `(-604, -392)`, score 5200, won) with `inputs.player` = the devnet account #0, runs
`attest.py serve --no-verify` (or `--verify-cmd tools/prove/verify.py` when `E2E_PROOF` names a
proof of these outputs), gets `[r, s]` through `POST /attest`, sends `submit` from the account,
and asserts: one `LevelValidated` with the player, level and score; `best(player, pile10)` =
`{score 5200, won}`; the leaderboard is `[(player, 5200)]`; the same `submit` again fails with
`'submit: nullifier'`. It prints the gas of `submit`. Files: `deploy/out/e2e/`. CI runs it in the
optional `e2e` job.

## By hand on the devnet

```sh
deploy/devnet.sh                          # devnet on :5050, deploy/devnet.json, deploy/devnet.env
PLAYER=$(node deploy/slingfall.ts account)
LEVEL=$(python3 -c 'import json; print(json.load(open("deploy/devnet.json"))["levels"]["pile10"])')

# Outputs of a play for PLAYER: from the client ("Copy inputs"), or a golden case:
python3 deploy/outputs.py --case pile10-reference --player "$PLAYER" --out deploy/out/outputs.json

# Attestation service (devnet key; --no-verify only without a prover):
SLINGFALL_ATTEST_KEY=0x736c696e6766616c6c2d6465766e6574 \
  python3 services/attest/attest.py serve --verify-cmd "python3 tools/prove/verify.py" &
python3 services/attest/attest.py request --outputs deploy/out/outputs.json \
  --proof-path tools/prove/out/<case>/proof.json > deploy/out/attestation.json

SIG=$(python3 -c 'import json; print(",".join(json.load(open("deploy/out/attestation.json"))["signature"]))')
node deploy/slingfall.ts submit --devnet --config deploy/devnet.json --outputs deploy/out/outputs.json --signature "$SIG"
node deploy/slingfall.ts best --config deploy/devnet.json --player "$PLAYER" --level "$LEVEL"
node deploy/slingfall.ts leaderboard --config deploy/devnet.json --level "$LEVEL"
deploy/devnet.sh down
```

`attest.py sign --outputs FILE` attests offline (same key, same signature: the nonce is derived
from the key and the hash).

## In the browser

```sh
deploy/devnet.sh
SLINGFALL_ATTEST_KEY=0x736c696e6766616c6c2d6465766e6574 python3 services/attest/attest.py serve --no-verify &
set -a; . deploy/devnet.env; set +a
npm --prefix client run dev
```

The `VITE_*` variables are read when Vite starts (and inlined by `npm run build`). With
`VITE_SLINGFALL_ADDRESS` set, the end-of-level panel has a **Submit on Starknet** section: pick
a wallet and **Connect**, optionally give the path of a proof made by the prover on the service's
machine, **Submit**. The page recomputes the outputs with `player` = the connected account (the
simulation never reads the player: only `player` and `inputs_hash` change), asks `/attest`,
sends `submit` through the wallet, then shows the transaction hash, its L2 gas, the player's best
and the leaderboard. Wallets:

* **Devnet account (dev only)**: the prefunded account of `deploy/devnet.env`, signing in the page;
  offered only when `VITE_DEVNET_PRIVATE_KEY` is set.
* **Cartridge Controller** (`@cartridge/controller`, D9's first choice): on the networks Cartridge
  serves (Sepolia, mainnet); not on a local devnet.
* **Browser wallet** (get-starknet: Argent X, Braavos): any network the wallet is set to,
  including the devnet as a custom network.

A second submission of the same attempt is refused by the contract (`'submit: nullifier'`).

## Sepolia

The owner deploys with their own account (never committed, never on a command line):

```sh
export STARKNET_RPC=<a Sepolia RPC 0.10 URL>
export SLINGFALL_ACCOUNT_ADDRESS=0x...   SLINGFALL_PRIVATE_KEY=0x...
export SLINGFALL_ATTESTATION_KEY=$(ssh <service host> python3 services/attest/attest.py pubkey)
deploy/sepolia.sh                        # deploy/sepolia.json, deploy/sepolia.env
```

The attestation service runs on the proving machine with `--verify-cmd` (never `--no-verify`),
behind TLS; set `VITE_ATTEST_URL` in `deploy/sepolia.env` to its public URL, then build the client
with those variables. Players connect with the Cartridge Controller or a browser wallet.
`sncast --profile sepolia --url "$STARKNET_RPC" call --contract-address <address> --function best
--calldata <player> <level_hash>` reads a record by hand (`deploy/snfoundry.toml`).
