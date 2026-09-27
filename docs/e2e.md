# End to end: play, attest, submit, settle (lots G9, E3b, W1)

Contract v2 (`docs/contract-v2.md`) has two tiers, and the client, the services and `deploy/**` speak
it since lot W1:

* **Provisional, in seconds.** The attestation service re-executes the replay natively and signs
  `verifier::attestation_message(chain_id, contract, program_hash, epoch, expiry, outputs)`; the
  player sends `submit(outputs, [program_hash, expiry, r, s])` (`caller == player`). The record goes to
  `best` and the live board `leaderboard_provisional`.
* **Settled, about 1.5 h later.** The same attempt proven by Herodotus Atlantic, its fact bridged to
  the Satellite on Starknet; `submit_settled(outputs, args, child_program_hash)` is checked by
  `SatelliteVerifier` (`docs/proving.md` "Atlantic + Integrity") and recorded for `claim.player`
  whoever sends it, so the prover service's relay may send it: the player need not come back.

```
play (client, Cairo VM in the browser) ──> 10 output felts (player = the wallet)
POST /attest {level, inputs, outputs} (attest.py --execute) ──> scarb execute ──> same outputs?
  ──> sign attestation_message ──> evidence [program_hash, expiry, r, s]
wallet: submit(outputs, evidence) ──> best, leaderboard_provisional, LevelValidated{provisional}
POST /prove {level, inputs} (services/prove, in the background) ──> c1main ──> Atlantic (≈ 1.5 h)
  ──> the fact on the Satellite ──> relay (serve --relay): submit_settled for claim.player
                                 └─> or the player: "Settle" ──> submit_settled
  ──> best_settled, leaderboard, LevelValidated{settled}
```

An attempt is *provisional* after `submit` and *settled* after `submit_settled`; each tier accepts an
attempt once (`'submit: nullifier'`), and settling the attested attempt upgrades it. An unsettled
provisional record may be `expire`d by anyone after `expire_delay` (24 h). With `verifier =
Satellite` the attested tier is closed and only `submit_settled` records.

## Pieces

| path | role |
|---|---|
| `deploy/contract/` | a package of its own that builds the registry class `Slingfall` with its CASM (the crate builds Sierra only), and the devnet's `FakeSatellite` (true for the facts its deployer registers); `SlingfallSim` is never declared (over the CASM limit, D11) |
| `deploy/slingfall.ts` | starknet.js tool (Node 24 runs it as is): `deploy` (fresh v2: key, `pin_program`, Satellite, levels), `pin-program`, `revoke-program`, `set-attestation-key`, `set-satellite`, `set-admin` / `accept-admin`, `upgrade`, `submit`, `submit-settled [--simulate]`, `expire`, `fake-fact`, `best [--settled]`, `leaderboard [--provisional]`, `boards`, `attempt`, `program`, `devnet-time`, `account`, `class-hash` |
| `deploy/devnet.sh` | installs and starts `starknet-devnet --seed 0` (three accounts), deploys, writes `deploy/devnet.json` and `deploy/devnet.env` |
| `deploy/outputs.py` | a golden case replayed with `scarb execute` (`main`) for another player; its inputs, its `c1main` argument and (`--child-hash`) its Atlantic facts |
| `deploy/e2e.sh` | the scripted check below |
| `deploy/sepolia.sh` | Sepolia: `deploy`, `pin` (explicit grace), `revoke`, `set-attestation-key`, `set-admin` / `accept-admin`, `upgrade`, `settle JOB`, `translate JOB`; keys from the environment |
| `deploy/sepolia.json` | the v1 Sepolia deployment (lot E3b; a v2 deployment is a later lot) |
| `services/attest/attest.py` | the attestation service (`serve --execute | --verify-cmd | --no-verify`, `sign`, `pubkey`, `request`), Python standard library, signing with `crates/slingfall_contract/tools/vectors.py` |
| `services/prove/prove_service.py`, `relay.py` | the prover service of the settled tier (`serve [--relay]`, `prove`, `status`, `translate`, `relay`), Python standard library on `tools/atlantic` |
| `deploy/snfoundry.toml` | `sncast` profiles for manual calls |
| `client/src/chain/` | the client's Submit step: wallet, attestation client, `submit`, both tiers' reads and boards, the prover-service client, the relay's status and "Settle" (`prove.ts`, `panel.ts`) |

## Setup

Node 24, Python 3, scarb 2.19.4 (`.tool-versions`). Then:

```sh
npm --prefix client ci
scarb --manifest-path crates/slingfall_replay/Scarb.toml build   # the replay executables (outputs.py, attest.py --execute)
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

A fresh devnet on port 5055; account #0 is the admin, #1 the player, #2 a third party. It deploys v2
(attestation key of the public test secret `'slingfall-devnet'`, `pin_program(c1main, 0)`, the
`FakeSatellite`, the six fixture levels), replays four golden shots with `deploy/outputs.py`
(`pile10-reference` and two `one_block` shots for the player, `pile10-reference` for the admin), and
checks:

1. **Provisional.** `attest.py serve --execute` re-executes the player's pile10 shot and signs (epoch
   1, the pinned program, this contract); the player's `submit` emits one provisional
   `LevelValidated` with its `program_hash`; `best` is provisional, `best_settled` empty, the settled
   board empty and the live board `[(player, 5200)]`; the same `submit` again fails with `'submit:
   nullifier'`. The admin's attested pile10 record is submitted too, and `expire` on it fails with
   `'expire: early'`.
2. **Relayed settle.** A prover-service job of the player's attempt is written to a store; `prove_service.py
   relay` with account #2 in the environment waits while the fact is absent (`relay.state = waiting`,
   nothing sent), then, the run's fact registered on the `FakeSatellite`, simulates and sends
   `submit_settled`: the transaction's sender is account #2, the record (`best`, `best_settled`, the
   settled board) is the player's. The player's own settle after it fails with `'submit: nullifier'`.
3. **Re-pin with grace.** `pin-program` pins another hash with a 3 600 s grace: a proof of the old
   program (a `one_block` shot, simulated first) settles inside the window; after `devnet-time
   --advance 3601` another fails with `'submit: program'` (simulation and transaction).
4. **Expiry.** 24 h later (`devnet-time --advance 86400`) account #2 expires the admin's provisional
   record: its `best` falls back to the empty settled one and its row leaves the live board (the
   player's stays); a second `expire` fails with `'expire: none'`.

`E2E_SETTLE=keccak` registers the bridged keccak facts instead of the translated ones (the path
Sepolia takes today). Files: `deploy/out/e2e/`. CI runs it in the optional `e2e` job.

Gas on starknet-devnet (v1, 2026-09-26): attested `submit` 5,649,600 L2 gas; `submit_settled` upgrade
4,453,840 (0.79x) with the translated fact, 11,973,840 (2.12x) with the keccak fact only. The v2
figures are printed by each run (`e2e: provisional ok; submit l2_gas …`, `e2e: relayed settle …`).

## By hand on the devnet

```sh
deploy/devnet.sh                          # devnet on :5050, deploy/devnet.json, deploy/devnet.env
ADDRESS=$(python3 -c 'import json; print(json.load(open("deploy/devnet.json"))["address"])')
PLAYER=$(node deploy/slingfall.ts account --index 1)
LEVEL=$(python3 -c 'import json; print(json.load(open("deploy/devnet.json"))["levels"]["pile10"])')

# Outputs of a play for PLAYER: from the client ("Copy inputs"), or a golden case:
python3 deploy/outputs.py --case pile10-reference --player "$PLAYER" --out deploy/out/outputs.json

# Attestation service (devnet key), re-executing each replay:
SLINGFALL_ATTEST_KEY=0x736c696e6766616c6c2d6465766e6574 python3 services/attest/attest.py serve \
  --execute --contract "$ADDRESS" --rpc http://127.0.0.1:5050/rpc &
python3 services/attest/attest.py request --level pile10 --inputs deploy/out/outputs.json \
  --outputs deploy/out/outputs.json > deploy/out/attestation.json

node deploy/slingfall.ts submit --devnet --index 1 --config deploy/devnet.json \
  --outputs deploy/out/outputs.json --attestation deploy/out/attestation.json
node deploy/slingfall.ts best --config deploy/devnet.json --player "$PLAYER" --level "$LEVEL"
node deploy/slingfall.ts boards --config deploy/devnet.json --level "$LEVEL"
deploy/devnet.sh down
```

`attest.py sign --chain-id … --contract … --program-hash … --epoch … --expiry … --outputs FILE`
attests offline (same key, same signature: the nonce is derived from the key and the message).

## In the browser

```sh
deploy/devnet.sh
SLINGFALL_ATTEST_KEY=0x736c696e6766616c6c2d6465766e6574 python3 services/attest/attest.py serve \
  --execute --contract "$(python3 -c 'import json; print(json.load(open("deploy/devnet.json"))["address"])')" \
  --rpc http://127.0.0.1:5050/rpc &
set -a; . deploy/devnet.env; set +a
npm --prefix client run dev
```

The `VITE_*` variables are read when Vite starts (and inlined by `npm run build`). With
`VITE_SLINGFALL_ADDRESS` set, the end-of-level panel has a **Submit on Starknet** section and shows
both boards of the level: **Settled (proven)** and **Live (provisional and settled)**, each row with
the engine release (`program_hash`) of its record. Pick a wallet and **Connect**: the outputs table
above is recomputed for the connected account (m11: only `player` and `inputs_hash` change).
**Submit**: the page asks `/attest` with the level, the inputs and its outputs, sends `submit` through
the wallet and shows the provisional record. With `VITE_PROVE_URL` (a `prove_service.py serve`), the
page then requests the proof on its own and follows `GET /status/<id>`. With a relay (`serve
--relay`, shown by `/health`) it says the page may be closed and later shows **Settled by the relay
in 0x…**; without one, or meanwhile, **Settle** sends `submit_settled(outputs, args, the proof's
program)` (the level felts read back with `level_data`). Wallets:

* **Devnet account (dev only)**: the prefunded account of `deploy/devnet.env`, signing in the page;
  offered only when `VITE_DEVNET_PRIVATE_KEY` is set.
* **Cartridge Controller** (`@cartridge/controller`, D9's first choice): on the networks Cartridge
  serves (Sepolia, mainnet); not on a local devnet.
* **Browser wallet** (get-starknet: Argent X, Braavos): any network the wallet is set to,
  including the devnet as a custom network.

## Sepolia

The deployment of lot E3b (`deploy/sepolia.json`, addresses and transaction hashes; the transcript is
in `docs/proving.md` "Settled submit") is **contract v1**: `verifier = Satellite`, the four-field
`SatelliteConfig`, no program set. The client and scripts of this branch speak v2 and are meant for
the v2 deployment of a later lot. From the owner's environment (`STARKNET_RPC_URL`,
`STARKNET_ACCOUNT_ADDRESS`, `STARKNET_PRIVATE_KEY`; never on a command line), a v2 deployment is:

```sh
SLINGFALL_ATTESTATION_KEY=<public key> deploy/sepolia.sh deploy   # key + pin + Satellite + levels
# the attempt, proven for the account (≈ 1.5 h on Atlantic; resumable, idempotent):
python3 services/prove/prove_service.py prove --level pile10 --player "$STARKNET_ACCOUNT_ADDRESS" \
  --shot=-604,-392 --watch --interval 300
deploy/sepolia.sh settle <job-id>           # submit_settled, best, boards -> the deployment record
deploy/sepolia.sh pin <hash> --bit-compatible   # a re-pin, the previous program valid 24 h more
```

`SLINGFALL_VERIFIER=satellite` closes the attested tier. The attestation service runs `--execute`
(or `--verify-cmd`), never `--no-verify`, behind TLS. `sncast --profile sepolia --url
"$STARKNET_RPC_URL" call --contract-address <address> --function best --calldata <player>
<level_hash>` reads a record by hand (`deploy/snfoundry.toml`).

### The client on Sepolia (lot C1)

`client/.env.sepolia` holds the client's public Sepolia values (`VITE_NETWORK=sepolia`,
`VITE_SLINGFALL_ADDRESS` of `deploy/sepolia.json`, `VITE_STARKNET_RPC_URL` the public RPC,
`VITE_PROVE_URL` and `VITE_ATTEST_URL` empty); `deploy/sepolia.env.example` lists them for your own
build (`VITE_RPC_URL`, the name `deploy/devnet.sh` writes, still works; `VITE_STARKNET_RPC_URL` wins).

```sh
cd client
npm run dev:sepolia      # Vite dev server, mode sepolia
npm run build:sepolia    # dist/ for Sepolia; node scripts/smoke-sepolia.mjs checks its entry script
```

On Sepolia the wallet list is Cartridge Controller and get-starknet (the devnet account is hidden), the
page links the contract and the player's `LevelValidated` transactions on Voyager Sepolia and shows the
on-chain hash of the level. Until the v2 deployment, the v1 contract's reads (`best` with 5 felts, no
`leaderboard_provisional`) do not match this client: point it at a v2 deployment. Playing, the two
tiers, the statuses and the known limits: [`testers.md`](testers.md).
