# Playing Slingfall on Starknet Sepolia (testers)

Slingfall runs every physics tick of a level in Cairo, in your browser (cairo-vm compiled to wasm), and
a finished level can be validated on Starknet Sepolia. This page is the path from "open the page" to
"my attempt is on the leaderboard", and what to look at while you do it. Design background:
[`DESIGN.md`](DESIGN.md) D8-D9, the two tiers: [`e2e.md`](e2e.md), the proving side:
[`proving.md`](proving.md).

Nothing here needs a private key in a file. Wallet keys stay in your wallet; the service keys
(Atlantic, the attestation key) are environment variables of the machine that runs the service.

## The deployment

| | |
|---|---|
| network | Starknet Sepolia (`SN_SEPOLIA`) |
| contract `Slingfall` | `0x4b645fe7cf06775c99c61148097b3aecabb67eacfd2937e0431affef5000ae2` ([Voyager](https://sepolia.voyager.online/contract/0x4b645fe7cf06775c99c61148097b3aecabb67eacfd2937e0431affef5000ae2)) |
| verifier | **Satellite**: only a *settled* submission is accepted (Herodotus Atlantic proof, its fact on the Satellite) |
| levels | `bridge`, `cores3`, `one_block`, `pile10`, `tower`, `twin` (hashes in `deploy/sepolia.json`) |

Everything in `deploy/sepolia.json` is the source of truth; `client/.env.sepolia` is checked against it
by `client/src/chain/config.test.ts`.

**What this means for you.** The contract was deployed with `verifier = Satellite`, so the attested
("provisional") `submit(outputs, [r, s])` is refused there: there is no attestation key registered.
On this deployment the page therefore offers **Prove (settled)** instead of **Submit**, and the one
path to the leaderboard is *proof, then settle*. The provisional path (below) works on a deployment whose
verifier is `Stub` (the devnet of `docs/e2e.md`, or a Sepolia deployment made with
`SLINGFALL_VERIFIER=stub`); it is documented because the page and the services support it.

## 1. Open the client

Either:

* the **hosted build**, when the owner has published it (Actions > CI > Run workflow, see
  "Hosted build" below), at `https://<owner>.github.io/slingfall/`; or
* **locally** (Node 24; the wasm runner is built once, ~2 min, Rust via rustup):

  ```sh
  client/vm/scripts/build.sh          # client/vm/pkg/, git-ignored (client/vm/README.md)
  cd client && npm ci && npm run dev:sepolia
  ```

  `dev:sepolia` is Vite in mode `sepolia`: it reads `client/.env.sepolia` (public values only:
  `VITE_NETWORK`, `VITE_SLINGFALL_ADDRESS`, `VITE_STARKNET_RPC_URL`, `VITE_PROVE_URL`,
  `VITE_ATTEST_URL`). To override one, export it in the shell, or put it in
  `client/.env.sepolia.local` (git-ignored); [`deploy/sepolia.env.example`](../deploy/sepolia.env.example)
  lists them all. Without `client/vm/pkg/` the page says "VM not built" and only replays a recorded trace.

The top-right strip shows the network, the contract (a Voyager link) and the **on-chain hash of the
level** you are playing (hover for the full felt). The level list is the same six levels as on
Sepolia (`client/public/levels/`); each level's hash equals the one registered in the contract.

## 2. Connect a wallet

The end-of-level panel has **Submit on Starknet**. Choose:

* **Browser wallet (get-starknet)**: Braavos or Argent X, set to **Sepolia**;
* **Cartridge Controller**.

There is no "devnet account" on Sepolia (the option is hidden whatever the variables say). The wallet
account pays the gas of the final transaction (about 0.4 STRK for `submit_settled`
in `deploy/sepolia.json`); fund it from a Sepolia faucet first. Once connected, the panel lists the
account's earlier `LevelValidated` transactions as Voyager links, read from the RPC's event index.

## 3. Play and "Copy inputs"

Drag from the sling to aim (an integer pull in `[-1024, 1024]²`, the dotted arc is the exact flight),
release; the shot is simulated by the Cairo replay in a worker and streamed to the renderer. At the
end of the level the panel shows won / lost, the score and the ten output felts a proof will carry
(`inputs_hash`, `final_state_hash` highlighted). **Copy inputs** copies the shots as JSON
(`{player, shots: [{pull_x, pull_y, delay}]}`); keep it, it is the whole attempt (the prover service's
`prove --shot=PX,PY` takes the same pulls).

The `player` output is the connected wallet's address: the page recomputes the outputs for it at
submit time (the simulation never reads `player`; only `player` and `inputs_hash` change).

## 4. Provisional submit (a `Stub` deployment only)

Needs an **attestation service**; it signs `poseidon(outputs)` after verifying a proof of the outputs.
On the machine that has the proof (`docs/proving.md`, `tools/prove/prove.py`):

```sh
export SLINGFALL_ATTEST_KEY=<the attestation secret>   # an environment variable, never a flag or a file in git
python3 services/attest/attest.py pubkey                # the public key the admin registers (set_attestation_key)
python3 services/attest/attest.py serve --verify-cmd "python3 tools/prove/verify.py"   # 127.0.0.1:8547
```

(`--no-verify` signs anything and is for a private devnet only; never expose it.) Point the page at it
with `VITE_ATTEST_URL=http://127.0.0.1:8547` (the default) and give the proof's path in the panel's
"proof path" field (a path on the service's machine). **Submit** sends the outputs to `/attest`,
then `submit(outputs, [r, s])` through the wallet; the panel shows the transaction hash, its gas, your
best and the leaderboard, and the tier **Provisional (attested)**. The service answers CORS for any
origin, so a page served from elsewhere can call a service on `127.0.0.1` (see the browser limits
under "Hosted build").

## 5. Settled submit (the Sepolia path)

Needs the **prover service** and about **1.5 hours**. It holds the Atlantic API key (never the
browser), so whoever runs it needs their own key and a machine that has built the proving tools
(`docs/proving.md`, "Reproduce": the patched `cairo1-run` and `c1main`). On that machine:

```sh
export ATLANTIC_API_KEY=<your key>                       # in the environment only
export STARKNET_RPC_URL=<a Sepolia RPC>                  # the Satellite reads
# optional: with STARKNET_ACCOUNT_ADDRESS and STARKNET_PRIVATE_KEY of a funded Sepolia account the
# service also sends the (permissionless) translation transaction, which makes settlement cheaper
python3 services/prove/prove_service.py serve            # 127.0.0.1:8549
```

then start the client with `VITE_PROVE_URL=http://127.0.0.1:8549` (in `client/.env.sepolia.local`, a
git-ignored file with the single line `VITE_PROVE_URL=http://127.0.0.1:8549`, or exported in the shell
before `npm run dev:sepolia`). Then:

1. finish a level, **Connect**, press **Prove (settled)**. The page recomputes the outputs for your
   account and posts `POST /prove {level, inputs}`; the job id is a hash of level, inputs and program,
   so pressing again (or reloading and repeating the same attempt) reuses the job;
2. keep the page open: it polls `GET /status/<id>` every minute (the service also survives a restart);
3. when the fact is on the Satellite the panel shows **Settle** (or **Settle (cheap)** once the Poseidon
   fact exists) - press it and confirm in the wallet. `submit_settled(outputs, args)` reads the level
   back from the registry, checks the fact and records the attempt as *settled*.

You can also drive the same flow without the page (`docs/e2e.md` "Sepolia"): `prove_service.py prove
--level pile10 --player <your address> --shot=-604,-392 --watch`, then `deploy/sepolia.sh settle <job>`
(that script needs the deployer's environment, so it is for the owner).

### What each status means

| shown | meaning |
|---|---|
| `Connected 0x…` | wallet connected; nothing sent |
| `Attested (proof verified)` / `WITHOUT a proof` | (Stub) the attestation service signed; the second form means it runs `--no-verify`: not trustworthy |
| `Provisional (attested)` | (Stub) `submit` accepted: the record exists, `settled = false`; a later settlement upgrades it |
| `Proving · …` | the prover service builds the PIE (about 2 min), then Atlantic proves it (trace, SHARP proof, L1 verification, bridge: about 1.5 h in total). The suffix is the service's own description |
| `Settle` / `Settle (cheap)` button | the fact is on the Satellite: `Settle` uses the bridged keccak fact (more L2 gas), `Settle (cheap)` the translated Poseidon fact |
| `Settling in 0x…` | `submit_settled` sent, waiting for the receipt |
| `Settled in 0x… (L2 gas …)` | accepted: `LevelValidated{settled: true}`, your best and the leaderboard are updated |
| `Submit failed: … 'submit: nullifier'` | this exact attempt (level, player, inputs) was already submitted at this tier: change a shot, or it is already recorded |
| `Submit failed: … 'submit: proof'` | the evidence was refused (wrong attestation key, or the fact is not on the Satellite yet) |
| `Wallet: …` | the wallet connection failed or was refused |

`Provisional` is an attestation of the service's key; `Settled` rests on the SHARP proof verified on
Ethereum and bridged to the Satellite (`proving.md`, "Trust").

## 6. Hosted build (the owner)

`.github/workflows/ci.yml` has a `pages` job that builds the wasm runner and `npm run build:sepolia`
with `VITE_BASE=/<repository>/` and deploys it to GitHub Pages. It runs **only** on a manual dispatch
(Actions > CI > Run workflow), never on push or pull request, and Pages is **not enabled
automatically**: the owner turns it on once under Settings > Pages > Source: **GitHub Actions**. Until
then the deploy step fails and nothing is published. The repository variable `SLINGFALL_PROVE_URL`
(Settings > Secrets and variables > Actions > Variables) inlines a public prover-service URL into
the build; leave it empty for a play-only site. (A manual dispatch runs the whole CI, not only `pages`.)

Limits of the hosted page: the services are plain HTTP on `127.0.0.1` by default. A page served over
HTTPS may call `http://127.0.0.1` in Chromium and Firefox, but recent Chromium asks the user for
permission for local-network access and Safari refuses; when in doubt, run `npm run dev:sepolia`
locally for sections 4 and 5. A service on another machine must sit behind TLS.

## 7. Checks in CI

`client` runs `npm run build:sepolia` (step `client-build-sepolia`) and `node scripts/smoke-sepolia.mjs`,
which fails unless the entry script named by the built `index.html` carries the contract address of
`deploy/sepolia.json`, the Sepolia RPC and the Voyager Sepolia links. (Vite inlines `VITE_*` in the
JavaScript, not in `index.html` itself.)

## 8. Known limits, and what to look at

**No executor has run this page in a browser** (their sandboxes could not launch one, `client/README.md`
"Not verified in a browser"), and none has connected a wallet on Sepolia or used the panel's new
Satellite path. The Node measurements of `client/vm/README.md` are the only numbers: treat them as
expectations, and please report what you see.

Look at:

* **First frame.** Page load (the wasm is 1.5 MB, the three executables about 20 MB of JSON; 0.4-0.6 s to
  load and parse in Node), then release to first frame (77 ms in Node, 0.3 s budgeted for a browser). The console
  logs `vm: loaded in … ms` and, per shot, `first frame … ms`.
* **fps.** The renderer plays 60 Hz; during the impact the VM runs slower than real time and the HUD says
  "simulating…" (slow motion). Note when it stalls or stutters, and on which level and device.
* **Memory.** The wasm plateaus at 300-350 MB with the default chunk sizing (Node), and never shrinks; the
  tab total is more. Watch a mobile browser and a tab left open through several retries.
* **Timing.** The console prints steps, seconds and chunks per shot (`shot n: first frame … ms, … ticks, …M steps, …
  s`). In Node the `pile10` reference shot (191 ticks, 34M steps) takes about 10 s and a weak shot
  (120 ticks, 10M steps) 2.5 s; a phone will be slower.
* **Wallets.** get-starknet with Braavos and Argent X on Sepolia; Cartridge Controller with the public RPC
  (Cartridge may refuse an RPC it does not serve: then use a browser wallet).
* **The public RPC** (`starknet-sepolia-rpc.publicnode.com`) is rate limited and may not index events for a long
  block range: the "your LevelValidated" links are then missing (a warning in the console), which changes
  nothing else. Use your own endpoint via `VITE_STARKNET_RPC_URL`.
* **One record per attempt.** The contract's nullifier accepts one submission per (level, player, inputs)
  and tier (attested, then settled).
* **Cost and delay.** About 0.4 STRK of gas for `submit_settled` with the keccak fact (less with the translated
  one), and 1 to 1.5 hours between the proof request and the settle button.
