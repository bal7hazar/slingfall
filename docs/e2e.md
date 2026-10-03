# End to end: play, attest, submit, settle, prove (lots G9, E3b, W1, W3)

Contract v2 (`docs/contract-v2.md`) has two tiers, and the client, the services and `deploy/**` speak
it since lot W1; contract v3 (`docs/contract-v3.md`) adds a third, *proven* (SNIP-36), wired in lot W3
(on the devnet only: no SNIP-36 proof can be made on Sepolia today, `docs/proving.md` "SNIP-36 tier"):

* **Provisional, in seconds.** The attestation service re-executes the replay natively and signs
  `verifier::attestation_message(chain_id, contract, program_hash, epoch, expiry, outputs)`; the
  player sends `submit(outputs, [program_hash, expiry, r, s])` (`caller == player`). The record goes to
  `best` and the live board `leaderboard_provisional`.
* **Settled, about 1.5 h later.** The same attempt proven by Herodotus Atlantic, its fact bridged to
  the Satellite on Starknet; `submit_settled(outputs, args, child_program_hash)` is checked by
  `SatelliteVerifier` (`docs/proving.md` "Atlantic + Integrity") and recorded for `claim.player`
  whoever sends it, so the prover service's relay may send it: the player need not come back.
* **Proven (v3), SNIP-36.** The same attempt proven as the chain of the contract's current
  `SplitChain` (`init`, `step_chunk` x n, `outputs`), one proof per virtual transaction; the prover
  service sends each proof in one Invoke (`submit_chunk` per message) and `finalize`, for
  `inputs.player`. Ranked with the settled tier; `attempt()` is 3 and the record's `program_hash` is
  the chain's bundle hash.

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
| `deploy/slingfall.ts` | starknet.js tool (Node 24 runs it as is): `deploy` (fresh deployment: key, `pin_program`, Satellite, levels; `--artifacts` for another build, e.g. v2), `pin-program`, `revoke-program`, `set-attestation-key`, `set-satellite`, `set-admin` / `accept-admin`, `upgrade`, `snapshot`, `submit`, `submit-settled [--simulate]`, `expire`, `fake-fact`, `best [--settled]`, `leaderboard [--provisional]`, `boards` (each row's proof and release), `attempt` (`proven` = 3), `program`, `devnet-time`, `devnet-blocks`, `account`, `class-hash`; the proven tier: `deploy-split`, `set-chunk-marker`, `pin-virtual-os`, `revoke-virtual-os`, `pin-chain` (prints the bundle hash), `revoke-chain`, `chain`, `submit-proof`, `finalize`, `sign-virtual` |
| `deploy/split.ts` | layout (e)'s chain as the scripts see it: the pinned class hashes (`crates/slingfall_split/src/hashes.cairo`), the check that `SplitChain` has no entry point but its three transactions, the on-chain check that a chain is the bundle it claims, the virtual Invoke of a proof |
| `deploy/v2.sh` | contract v2's class as deployed on Sepolia: `git archive` of the D2 commit, built, its hash checked against `deploy/sepolia.json` (the e2e's upgrade) |
| `deploy/devnet.sh` | installs and starts `starknet-devnet 0.10.0 --seed 0 --accounts 4 --proof-mode none`, deploys (v3, or `DEVNET_CONTRACT=v2`), opens the proven tier (`proven`: the split classes, `SplitChain`, marker, virtual OS, `pin_chain`), writes `deploy/devnet.json`, `deploy/devnet-split.json` and `deploy/devnet.env` |
| `deploy/outputs.py` | a golden case replayed with `scarb execute` (`main`) for another player; its inputs, its `c1main` argument and (`--child-hash`) its Atlantic facts |
| `deploy/e2e.sh` | the scripted check below |
| `deploy/sepolia.sh` | Sepolia: `deploy`, `pin` (explicit grace), `revoke`, `set-attestation-key`, `set-admin` / `accept-admin`, `upgrade`, `settle JOB`, `translate JOB`; keys from the environment |
| `deploy/sepolia.json` | the v2 Sepolia deployment (lot D2) and its transactions; the v1 deployment (lot E3b) under `"v1"` |
| `services/attest/attest.py` | the attestation service (`serve --execute | --verify-cmd | --no-verify`, `sign`, `pubkey`, `request`), Python standard library, signing with `crates/slingfall_contract/tools/vectors.py` |
| `services/prove/prove_service.py`, `relay.py` | the prover service of the settled tier (`serve [--relay]`, `prove`, `status`, `translate`, `relay`), Python standard library on `tools/atlantic` |
| `services/prove/snip36.py` | its SNIP-36 path (`--snip36 fake|snip36`, `prove --tier proven`, `POST /prove {"tier": "proven"}`): the chain planned by simulation, the prover interface (`FakeProver` on the devnet, `Snip36Prover` for `starknet_proveTransaction`), one Invoke per proof, `finalize` |
| `deploy/snfoundry.toml` | `sncast` profiles for manual calls |
| `client/src/chain/` | the client's Submit step: wallet, attestation client, `submit`, both tiers' reads and boards, the prover-service client, the relay's status and "Settle" (`prove.ts`, `panel.ts`) |

## Setup

Node 24, Python 3, scarb 2.20.1 (`.tool-versions`). Then:

```sh
npm --prefix client ci
scarb --manifest-path crates/slingfall_replay/Scarb.toml build   # the replay executables (outputs.py, attest.py --execute)
```

`deploy/devnet.sh` installs `starknet-devnet` when it is not on `PATH`: the release binary of
`0xSpaceShard/starknet-devnet` for Linux x86-64 (`DEVNET_VERSION`, default **0.10.0**: the fake
prover's facts header is this version's) into `deploy/.devnet/bin/`, else `cargo install -j 2 --locked
starknet-devnet`; an asdf shim gets `ASDF_STARKNET_DEVNET_VERSION` set to it. The devnet must speak
RPC 0.10 (starknet.js 10), accept Sierra 1.9 (Cairo 2.19) and take `--proof-mode none` (0.10: an
Invoke's proof is ignored, its SNIP-36 facts' header checked); the version used is printed at start
(`devnet: starknet-devnet x.y.z on ...`). Node's `fetch` refuses some ports (5060, 5061, ...): keep
`DEVNET_PORT` off the WHATWG "bad ports" list. The proven tier needs the split crate's build
(`scarb build -p slingfall_split`, about a minute; `devnet.sh proven` runs it when missing).

## The scripted check

```sh
deploy/e2e.sh            # add --keep to leave the devnet up
```

A fresh devnet on port 5055; account #0 is the admin, #1 the player, #2 a third party (the relay and
the prover service's account), #3 a second player. It builds contract v3, contract v2's class of the
Sepolia deployment (`deploy/v2.sh`, hash-checked) and, in the background, layout (e)'s classes; deploys
**v2** (attestation key of the public test secret `'slingfall-devnet'`, `pin_program(c1main, 0)`, the
`FakeSatellite`, the six fixture levels), replays five golden shots with `deploy/outputs.py`
(`pile10-reference` and two `one_block` shots for the player, `pile10-reference` for the admin and the
second player), and checks:

1. **Provisional (v2).** `attest.py serve --execute` re-executes the player's pile10 shot and signs
   (epoch 1, the pinned program, this contract); the player's `submit` emits one provisional
   `LevelValidated` with its `program_hash`; `best` is provisional, `best_settled` empty, the settled
   board empty and the live board `[(player, 5200)]`; the same `submit` again fails with `'submit:
   nullifier'`. The admin's and the second player's attested pile10 records are submitted too, and
   `expire` on the admin's fails with `'expire: early'`.
2. **Upgrade v2 -> v3.** `snapshot` (admin, pending admin, verifier, attestation key and epoch, expiry
   delay, program and its validity, Satellite, each level's registration and data hash, both boards
   with each row's proof, both records and the attempt tier of the three players) before and after
   `upgrade --declare`: identical but the class hash. The three attested records survive (`attempt` 1).
3. **Proven tier opened.** `devnet.sh proven`: the split classes declared, `SplitChain` deployed and
   read back (its class, its five classes in storage), `set_chunk_marker('SLINGFALL')`,
   `pin_virtual_os` (the devnet's program), `pin_chain(chain, bundle, 0)` (the bundle printed).
4. **Provisional -> proven (SNIP-36).** `prove_service.py prove --tier proven --snip36 fake` with
   account #2 in the environment plans the whole chain of the player's pile10 shot (107 ticks, 8 calls,
   4 transactions at the 1.0e9 L2 gas budget), proves them with the fake prover, sends one Invoke per
   proof and `finalize`: the job is `proven`, `finalize` was sent by account #2, its `LevelValidated`
   says `proven` with the bundle hash as `program_hash`, `attempt()` is 3 and the player's
   `best_settled` carries the bundle hash. Gas goes to `deploy/out/e2e/cost.json` (`docs/proving.md`
   "Cost sheet").
5. **Provisional -> settled, relayed.** A prover-service job of the second player's attempt is written
   to a store; `prove_service.py relay` with account #2 waits while the fact is absent (`relay.state =
   waiting`, nothing sent), then, the run's fact registered on the `FakeSatellite`, simulates and sends
   `submit_settled`: the sender is account #2, the record is the second player's, `attempt()` is 2, and
   the settled board holds both rows, `proven by SNIP-36 · bundle …` and `settled by SHARP · program …`.
   The second player's own settle after it fails with `'submit: nullifier'`.
6. **Retired chain.** A second `SplitChain` is pinned with a 3 600 s grace: the first chain's first
   proof, sent again, is accepted inside the grace (idempotent); after `devnet-time --advance 3601`
   it fails with `'chunk: chain'` and a `finalize` on the first chain with `'finalize: chain'`.
7. **Re-pin with grace.** `pin-program` pins another hash with a 3 600 s grace: a proof of the old
   program (a `one_block` shot, simulated first) settles inside the window; after `devnet-time
   --advance 3601` another fails with `'submit: program'` (simulation and transaction).
8. **Expiry.** 24 h later (`devnet-time --advance 86400`) account #2 expires the admin's provisional
   record: its `best` falls back to the empty settled one and its row leaves the live board (the
   players' stay); a second `expire` fails with `'expire: none'`.

`E2E_SETTLE=keccak` registers the bridged keccak facts instead of the translated ones (the path
Sepolia takes today). Files: `deploy/out/e2e/`. CI runs it in the optional `e2e` job (under 10
minutes; 6 min 52 s on the 8-core development machine, of which 3.5 min are the five `scarb execute`
replays).

Gas on starknet-devnet (v1, 2026-09-26): attested `submit` 5,649,600 L2 gas; `submit_settled` upgrade
4,453,840 (0.79x) with the translated fact, 11,973,840 (2.12x) with the keccak fact only. The v2
figures are printed by each run (`e2e: provisional ok; submit l2_gas …`, `e2e: relayed settle …`).

## By hand on the devnet

```sh
deploy/devnet.sh                          # devnet on :5050, v3 with its proven tier open: deploy/devnet.json, deploy/devnet-split.json, deploy/devnet.env
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

# The proven tier (SNIP-36, fake prover): account #2 proves, submits and finalizes for the player.
RELAY=$(node deploy/slingfall.ts account --index 2 --with-key)
SLINGFALL_ADDRESS="$ADDRESS" STARKNET_RPC_URL=http://127.0.0.1:5050/rpc \
  STARKNET_ACCOUNT_ADDRESS=$(echo "$RELAY" | python3 -c 'import json, sys; print(json.load(sys.stdin)["address"])') \
  STARKNET_PRIVATE_KEY=$(echo "$RELAY" | python3 -c 'import json, sys; print(json.load(sys.stdin)["private_key"])') \
  python3 services/prove/prove_service.py prove --tier proven --snip36 fake --level pile10 \
  --inputs "$(python3 -c 'import json; print(",".join(json.load(open("deploy/out/outputs.json"))["inputs"]))')"
node deploy/slingfall.ts chain --config deploy/devnet.json          # the chain, its bundle, the marker
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
both boards of the level: **Settled (proven: SHARP or SNIP-36)** and **Live (provisional and
settled)**, each row with its proof and release: `provisional · program 0x…`, `settled by SHARP ·
program 0x…` or `proven by SNIP-36 · bundle 0x…` (`attempt()` of the record's inputs hash). With a
prover service that has the SNIP-36 path (`serve --snip36 fake` on the devnet, its account in the
environment; `/health` `proven.available`), the page requests the *proven* tier after the provisional
record: the service proves and records the attempt itself (**Proven by SNIP-36 (the prover service
finalized it in 0x…)**), nothing more to sign; else, or when the service answers that the contract's
chain is not its release (409), the settled one as below. Pick a wallet and **Connect**: the outputs table
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

`deploy/sepolia.json` is **contract v2** since lot D2 (below: addresses, every transaction, gas and
latencies of both tiers); the v1 deployment of lot E3b (`verifier = Satellite`, the four-field
`SatelliteConfig`; transcript in `docs/proving.md` "Settled submit") is kept under its `"v1"` key, its
levels deactivated. From the owner's environment (`STARKNET_RPC_URL`, `STARKNET_ACCOUNT_ADDRESS`,
`STARKNET_PRIVATE_KEY`; never on a command line), a v2 deployment is (`deploy` overwrites `$SEPOLIA_OUT`,
default `deploy/sepolia.json`: point it elsewhere to keep the previous record, then merge):

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
`VITE_PROVE_URL` empty, `VITE_ATTEST_URL` the hosted `https://attest.bal7hazar.com`); `deploy/sepolia.env.example` lists them for your own
build (`VITE_RPC_URL`, the name `deploy/devnet.sh` writes, still works; `VITE_STARKNET_RPC_URL` wins).

```sh
cd client
npm run dev:sepolia      # Vite dev server, mode sepolia
npm run build:sepolia    # dist/ for Sepolia; node scripts/smoke-sepolia.mjs checks its entry script
```

On Sepolia the wallet list is Cartridge Controller and get-starknet (the devnet account is hidden), the
page links the contract and the player's `LevelValidated` transactions on Voyager Sepolia and shows the
on-chain hash of the level. `client/.env.sepolia` points at the v2 deployment (lot D2) with its deploy
block; the retired v1 contract's reads (`best` with 5 felts, no `leaderboard_provisional`) do not match
this client. Playing, the two tiers, the statuses and the known limits: [`testers.md`](testers.md).

### Sepolia, contract v2 (lot D2, 2026-09-27)

The dry run first: `deploy/e2e.sh` and `E2E_SETTLE=keccak deploy/e2e.sh` on starknet-devnet 0.10.0, both
green (devnet L2 gas: attested `submit` 5,182,960; relayed `submit_settled` 7,034,080 on the translated
fact, 13,994,080 on the keccak fact). Then `deploy/sepolia.sh deploy` with `SLINGFALL_VERIFIER=stub`
and the attestation public key, from the admin account `0x59b1a0…3753` (Braavos).

| | |
|---|---|
| `Slingfall` v2 | `0x292f4b7dcbdb3ee7e5c3d1873e36ac03c71f3d4d5146ff009bcdf6e8bca4a02`, block 15 729 982 |
| class | `0x256e46a924bc9e435d8de5015fd6ec1b1bbe0e1eaf84d887a75961ea82a749f` |
| verifier / key / epoch | `Stub` (both tiers) / `0x1d569abbfe59185d5bc5a95a24cc53d13a40838a1df8e40cd9a89e05d120a1d` / 2 (rotated, `set_attestation_key` `0x702c0989…7efe2e`, block 16 007 385; epoch 1 was `0x66ca673b…bf4` at deploy) |
| program | `current_program` = c1main alpha.6 `0x580ef5d1…edf75a`, `program_valid_until` = `u64::MAX` |
| `satellite_config` | Atlantic bootloader `0x288ba129…b668f09`, SHARP bootloader `0x5ab580b0…2db07`, Satellite `0x421cd95f…676e` (v1's constants) |
| levels | the six fixture levels, same hashes as v1, active; `expire_delay` 86 400 s |
| v1 | `0x4b645f…0ae2`: its six levels `set_level_active(false)` in one multicall |

Everything above was read back from the chain after the deployment (`admin`, `verifier`,
`current_program`, `program_valid_until`, `attestation_epoch`, `attestation_key`, `satellite_config`,
`level` / `level_data` of each level, both boards empty).

Transactions (fee in STRK; L2 gas; every one estimated first):

| transaction | hash | L2 gas | L1 data gas | fee (STRK) |
|---|---|--:|--:|--:|
| declare Slingfall | [`0x3d680d3c…1350`](https://sepolia.voyager.online/tx/0x3d680d3c735d12fcb844b794f8a6fefc2dede0a34fbd4808ebacd9c34911350) | 1,440,278,835 | 192 | 30.9569 |
| deploy Slingfall | [`0x66caecc6…a999`](https://sepolia.voyager.online/tx/0x66caecc68080197860b525f076328cc27aff8a711590d2c2022edcad8a2a999) | 2,933,135 | 512 | 0.0635 |
| configure | [`0x6079548c…e3b0`](https://sepolia.voyager.online/tx/0x6079548cffbd0d81aae63468e0fb4a36833b0377983982b2e150461eb4fe3b0) | 5,232,105 | 864 | 0.1126 |
| register_level bridge | [`0x497a5e55…e532`](https://sepolia.voyager.online/tx/0x497a5e551049f781c1a82c122dfb9ed54ecaf7fb99b2b79d35542add05fe532) | 70,463,038 | 12,096 | 1.5172 |
| register_level cores3 | [`0x325e10d0…be42`](https://sepolia.voyager.online/tx/0x325e10d062ced454c8197a8916d337032b0a771e19c0aa73dbefb746b58be42) | 63,936,822 | 10,944 | 1.3831 |
| register_level one_block | [`0x2444710d…06d5`](https://sepolia.voyager.online/tx/0x2444710d4294de5d4a3203403e4e64977fa11621a55e2ee4ae438b1405206d5) | 37,750,242 | 6,528 | 0.8167 |
| register_level pile10 | [`0x1b9dd8e1…e340`](https://sepolia.voyager.online/tx/0x1b9dd8e1d3277b5294ec800c8fc252adcc51232c58f9c6cfd1031cef883e340) | 71,913,979 | 12,384 | 1.5557 |
| register_level tower | [`0xbbd1347e…aa99`](https://sepolia.voyager.online/tx/0xbbd1347e8c44a322c750136fbb15407539a61bf029ed78cdad39b4e4ddaa99) | 70,905,038 | 12,192 | 1.5267 |
| register_level twin | [`0x3cbfb788…2286`](https://sepolia.voyager.online/tx/0x3cbfb788728970bbad057ee7184978cee46695db989e0cb0ce9e5a0a3862286) | 79,272,447 | 13,632 | 1.7148 |
| submit (attested) pile10 | [`0x29b3289b…1651`](https://sepolia.voyager.online/tx/0x29b3289bf65b2d6fad40e263b76d94ec9c000bd5cd6d1b39b7d07e4c791651) | 5,494,931 | 864 | 0.1182 |
| submit_settled f55cabf2 (relayed) | [`0x369d3bde…a8fe`](https://sepolia.voyager.online/tx/0x369d3bde2bfb4447c1774135fa7370086d64a7b0ea54df8565354a5ed97a8fe) | 17,746,555 | 896 | 0.3808 |
| v1: set_level_active false x6 | [`0x2f94fbcc…12b7`](https://sepolia.voyager.online/tx/0x2f94fbccfafdc2e3e67da0e825862b4c9127d16dfbb6781c34153a91bba12b7) | 4,655,975 | 576 | 0.1001 |
| **total** | | | | **40.2463** |

The whole lot spent 40.25 STRK (the account's balance fell by exactly that), 30.96 of it on the
declaration of the 563 kB class.

**Provisional tier** (the pile10 reference shot of the admin account, `deploy/outputs.py`; the
attestation service `attest.py serve --execute` on 127.0.0.1, key from the environment):

| stage | seconds |
|---|--:|
| `POST /attest` (the service re-executes the replay with `scarb execute`, 8.7M steps, and signs) | 12.2 |
| sign and send `submit(outputs, [program_hash, expiry, r, s])` | 0.7 |
| inclusion (receipt) | 5.1 |
| **request attestation → provisional record on chain** | **18.0** |

`submit` `0x29b3289b…1651`: 5,494,931 L2 gas, 864 L1 data gas, **0.118 STRK**; one `LevelValidated
{settled: false, program_hash: alpha.6}`; `best` provisional, the live board `[(admin, 5200)]`, the
settled board empty.

**Provisional tier, hosted service (AT, 2026-10-03)** (the `tower-reference` golden case of the admin account,
never submitted before; `deploy/outputs.py`, then `attest.py request --url https://attest.bal7hazar.com`
from the VPS, the service at revision 3efb4ef in `--execute` mode, key epoch 2). The hosted key
`0x1d569abb…120a1d` equals `attestation_key()` read on chain. `attempt` was `none` before the `submit`:

| stage | seconds |
|---|--:|
| `POST /attest` (hosted service, TLS, the replay re-executed with `scarb execute`, 22.3M steps, and signed) | 21.7 |
| sign, send and inclusion of `submit(outputs, [program_hash, expiry, r, s])`, to the receipt (one measure: `node deploy/slingfall.ts submit`, fee estimation included) | 6.7 |
| **request attestation → provisional record on chain** | **28.4** (plus about 3 s between the two commands) |

`submit` [`0x29309c28…6e6d`](https://sepolia.voyager.online/tx/0x29309c280b9ee6894185135fca3aafb3c85e38a8d575e55c77e94008f6cfe6d), block 16 008 085: 5,494,931 L2 gas,
864 L1 data gas, **0.1126 STRK**; one `LevelValidated {settled: false, score: 6200, won: true,
program_hash: 0x5dc8c8e2…1360}`; `best` of the admin on `tower` is that record (provisional), `attempt` reads
`attested`. Against D2 (local service, pile10): the gas is identical (the contract's cost does not depend on
the level) and the fee is 5% lower (0.1126 against 0.1182 STRK, the gas price of the day); the attestation is
slower, 21.7 s against 12.2 s, since tower is 22.3M steps against pile10's 8.7M. The replay itself took 235 s
wall on the VPS, 4.2 GB peak, of which most is the first build under the heavy lock (`deploy/outputs.py` reports
its own run at 20 s).

**Settled tier, relayed** (the same attempt; `prove_service.py serve --relay --no-translate` on 127.0.0.1,
relayer = the admin account; `POST /prove` from a script, as the page does):

| stage | measured |
|---|--:|
| `POST /prove` → PIE built (`cairo1-run`, 8,735,395 steps, 41 MB, 96 s), facts, submitted to Atlantic | 100 s |
| Atlantic `TRACE_AND_METADATA_GENERATION` (declared L, ran as S) | 86 s |
| `PROOF_GENERATION_AND_VERIFICATION` (SHARP, Stwo, verified on Ethereum Sepolia) | 3,966 s (66.1 min) |
| `BRIDGE_FACT_HASH` (keccak fact to the Satellite) | 224 s |
| bridge done → relay pass (`/status` settleable on the keccak fact, `attempt`, simulation, send) | 29 s |
| relay send → block | 3 s |
| **`POST /prove` → settled record on chain** | **4,408 s (73.5 min)** |

Atlantic query `01M3J20R8B8P1VSQSWSS8D1Y94` (job `f55cabf2…`), keccak fact
`0x4be7eef9…77a69` valid on the Satellite, the Poseidon fact `0x6ddf4d19…3b4b` not (no translation
sent). The relay's `submit_settled` `0x369d3bde…a8fe`, sent by the admin account for `claim.player`
(the same account here), is the **upgrade** of the attested attempt on the **keccak** path: 17,746,555 L2
gas (3.23x the attested `submit`; v1's first keccak settlement: 18,819,885), 896 L1 data gas, **0.381
STRK**, one `LevelValidated {settled: true}`. After it: `attempt` = 2 (settled); `best` = the attested
record (block 15 730 073) marked `settled`; `best_settled` = `{5200, won}` at block 15 732 681; both
boards `[(admin, 5200)]` (`deploy/slingfall.ts boards`). Record: `deploy/sepolia.json`
`settled_submits`, `fixtures/proofs/atlantic/pile10-reference-sepolia-v2.json`.
