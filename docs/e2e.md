# End to end: play, attest, submit, settle (lots G9, E3b)

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

Lot E3b adds the **settled tier** (D9, two tiers): the same attempt proven by Herodotus Atlantic,
its fact bridged to the Satellite on Starknet, then `submit_settled(outputs, args)` checked by
`SatelliteVerifier` (`docs/proving.md` "Atlantic + Integrity", "Settled submit"):

```
POST /prove {level, inputs} (services/prove) ──> cairo1-run c1main ──> PIE ──> Atlantic (≈ 1.5 h)
GET /status/<id> ──> the fact on the Satellite ──> "Settle on Starknet"
wallet: submit_settled(outputs, args) ──> SatelliteVerifier ──> record settled, LevelValidated{settled}
```

An attempt is *provisional* after `submit` (attested) and *settled* after `submit_settled`; the
second submission of an attempt is allowed exactly once, from attested to settled. With
`verifier = Satellite` (Sepolia), `submit(outputs, args)` is the settled submission itself.
## Pieces

| path | role |
|---|---|
| `deploy/contract/` | a package of its own that builds the registry class `Slingfall` with its CASM (the crate builds Sierra only), and the devnet's `FakeSatellite` (true for the facts its deployer registers); `SlingfallSim` is never declared (over the CASM limit, D11) |
| `deploy/slingfall.ts` | starknet.js tool (Node 24 runs it as is): `deploy`, `submit`, `submit-settled`, `fake-fact`, `best`, `leaderboard`, `account`, `class-hash` |
| `deploy/devnet.sh` | installs and starts `starknet-devnet --seed 0`, deploys, writes `deploy/devnet.json` and `deploy/devnet.env` |
| `deploy/outputs.py` | a golden case replayed with `scarb execute` (`main`) for another player; its `c1main` argument and (`--child-hash`) its Atlantic facts |
| `deploy/e2e.sh` | the scripted check below |
| `deploy/sepolia.sh` | the Sepolia deployment (`deploy`) and the first settled submit (`settle JOB`); keys from the environment |
| `deploy/sepolia.json` | the Sepolia deployment: addresses, class hash, level hashes, transaction hashes, gas, the settled submit |
| `services/prove/prove_service.py` | the prover service of the settled tier (`serve`, `prove`, `status`), Python standard library on `tools/atlantic` |
| `deploy/snfoundry.toml` | `sncast` profiles for manual calls |
| `services/attest/attest.py` | the attestation service (`serve`, `sign`, `pubkey`, `request`), Python standard library, signing with `crates/slingfall_contract/tools/vectors.py` |
| `client/src/chain/` | the client's Submit step: wallet, attestation client, `submit`, reads; the prover-service client and "Settle on Starknet" (`prove.ts`, `panel.ts`) |

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
`'submit: nullifier'`. It prints the gas of `submit`. Then the settled tier, mocked: the devnet's
`FakeSatellite` stands for Herodotus's; `submit_settled(outputs, args)` is refused (`'submit:
proof'`) until the run's fact (`deploy/outputs.py --child-hash`, the formula of
`tools/atlantic/encoding.py`) is registered on it; then it upgrades the attempt
(`LevelValidated.settled`, `best(...).settled`) and a second `submit_settled` fails with `'submit:
nullifier'`. `E2E_SETTLE=keccak` registers the bridged keccak fact instead of the translated one
(the path Sepolia takes today). Files: `deploy/out/e2e/`. CI runs it in the optional `e2e` job.

Gas on starknet-devnet (2026-09-26): attested `submit` 5,649,600 L2 gas; `submit_settled` upgrade
4,453,840 (0.79x) with the translated fact, 11,973,840 (2.12x) with the keccak fact only (42
Keccak rounds over the 172-word bootloader output).

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
and the leaderboard, and the tier: **Provisional (attested)**. With `VITE_PROVE_URL` (a
`prove_service.py serve`), the page then asks `POST /prove` for the attempt, polls `GET
/status/<id>` (every minute; Atlantic takes about 1.5 h) and, once the fact is on the Satellite,
offers **Settle on Starknet**: `submit_settled(outputs, args)` (the level felts read back with
`level_data`), then shows **Settled**. Wallets:

* **Devnet account (dev only)**: the prefunded account of `deploy/devnet.env`, signing in the page;
  offered only when `VITE_DEVNET_PRIVATE_KEY` is set.
* **Cartridge Controller** (`@cartridge/controller`, D9's first choice): on the networks Cartridge
  serves (Sepolia, mainnet); not on a local devnet.
* **Browser wallet** (get-starknet: Argent X, Braavos): any network the wallet is set to,
  including the devnet as a custom network.

A second submission of the same attempt is refused by the contract (`'submit: nullifier'`).

## Sepolia

The deployment of lot E3b (`deploy/sepolia.json`, addresses and transaction hashes; the transcript is
in `docs/proving.md` "Settled submit"): `verifier = Satellite` (no attestation service is public),
the Satellite constants of `docs/proving.md`, the six fixture levels. From the owner's environment
(`STARKNET_RPC_URL`, `STARKNET_ACCOUNT_ADDRESS`, `STARKNET_PRIVATE_KEY`; never on a command line):

```sh
deploy/sepolia.sh deploy                    # deploy/sepolia.json, deploy/sepolia.env
# the attempt, proven for the account (≈ 1.5 h on Atlantic; resumable, idempotent):
python3 services/prove/prove_service.py prove --level pile10 --player "$STARKNET_ACCOUNT_ADDRESS" \
  --shot=-604,-392 --watch --interval 300
deploy/sepolia.sh settle <job-id>           # submit_settled, best, leaderboard -> deploy/sepolia.json
```

`SLINGFALL_VERIFIER=stub SLINGFALL_ATTESTATION_KEY=<public key>` deploys the attested tier instead
(the attestation service runs on the proving machine with `--verify-cmd`, never `--no-verify`,
behind TLS). The client: set `VITE_RPC_URL`, `VITE_PROVE_URL` (and `VITE_ATTEST_URL`) in
`deploy/sepolia.env`, then build it with those variables. `sncast --profile sepolia --url
"$STARKNET_RPC_URL" call --contract-address <address> --function best --calldata <player>
<level_hash>` reads a record by hand (`deploy/snfoundry.toml`).
