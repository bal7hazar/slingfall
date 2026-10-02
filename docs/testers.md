# Playing Slingfall on Starknet Sepolia (testers)

Slingfall runs every physics tick of a level in Cairo, in your browser (cairo-vm compiled to wasm), and
a finished level can be validated on Starknet Sepolia. This page is the path from "open the page" to
"my attempt is on the leaderboard", and what to look at while you do it. Design background:
[`DESIGN.md`](DESIGN.md) D8-D9, the two tiers: [`e2e.md`](e2e.md), the proving side:
[`proving.md`](proving.md).

To try all three tiers on your own machine first, without a wallet or a testnet (the proofs
simulated on a local devnet): `scripts/play.sh`, see [`play-local.md`](play-local.md).

Nothing here needs a private key in a file. Wallet keys stay in your wallet; the service keys
(Atlantic, the attestation key) are environment variables of the machine that runs the service.

## The deployment

| | |
|---|---|
| network | Starknet Sepolia (`SN_SEPOLIA`) |
| contract `Slingfall` | **v2** `0x292f4b7dcbdb3ee7e5c3d1873e36ac03c71f3d4d5146ff009bcdf6e8bca4a02` ([Voyager](https://sepolia.voyager.online/contract/0x292f4b7dcbdb3ee7e5c3d1873e36ac03c71f3d4d5146ff009bcdf6e8bca4a02)), deployed 2026-09-27 at block 15 729 982 (lot D2) |
| verifier | **Stub**: both tiers open. *Provisional*: `submit` with an attestation of the key `0x66ca673bb9a69e143f1072eda143886e2349baf4c996f200b06f7e3d4ddbf4` (epoch 1); *settled*: `submit_settled` on a Herodotus Atlantic proof, its fact on the Satellite |
| engine release | `c1main` rapier2d alpha.6, `0x580ef5d1896ce36ddc0309eed11218303ed39d1c30ad8ccea4d194be3edf75a` (`current_program`, no grace: the first pin) |
| levels | `bridge`, `cores3`, `one_block`, `pile10`, `tower`, `twin` (hashes in `deploy/sepolia.json`, the same as v1's) |
| v1 (retired) | `0x4b645fe7cf06775c99c61148097b3aecabb67eacfd2937e0431affef5000ae2` (lot E3b, `verifier = Satellite`): its six levels are deactivated (`set_level_active(false)`), its records stay readable; `deploy/sepolia.json` keeps it under `"v1"` |

Everything in `deploy/sepolia.json` is the source of truth; `client/.env.sepolia` is checked against it
by `client/src/chain/config.test.ts`. The deployment has been exercised end to end on both tiers with
the pile10 reference shot of the admin account (`e2e.md` "Sepolia (contract v2, lot D2)"). No hosted
attestation or prover service exists yet: sections 4 and 5 run them locally. On a deployment whose
verifier is `Satellite` (the attested tier closed) the page offers **Prove (settled)** instead of
**Submit**.

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

The `player` output is the connected wallet's address: once you connect, the page recomputes the
outputs for it and redraws the table (m11; the simulation never reads `player`, so only `player` and
`inputs_hash` change).

The panel shows both boards of the level: **Settled (proven)** (`leaderboard`, settled records only)
and **Live (provisional and settled)** (`leaderboard_provisional`, each player's best of either
tier; a provisional row is marked). Each row names the engine release (`program_hash`) its record was
validated with, marked "older release" when it is not the contract's current program.

## 4. Provisional record, in seconds

Needs an **attestation service**. It re-executes your attempt natively (`scarb execute` of the replay:
seconds) and signs when its outputs equal the page's; the signature names the chain, the contract,
the engine release, the key's epoch and an expiry (10 min). On the service's machine (a built replay:
`scarb --manifest-path crates/slingfall_replay/Scarb.toml build`):

```sh
export SLINGFALL_ATTEST_KEY=<the attestation secret>   # an environment variable, never a flag or a file in git
python3 services/attest/attest.py pubkey                # the public key the admin registers (set_attestation_key)
python3 services/attest/attest.py serve --execute --contract <address> --rpc <RPC>   # 127.0.0.1:8547
```

(`--verify-cmd "python3 tools/prove/verify.py"` checks a proof you bring instead, through the panel's
"proof path" field; `--no-verify` signs anything and is for a private devnet only, never expose it.)
The service allows 20 requests per player per hour (`--rate`). Point the page at it with
`VITE_ATTEST_URL=http://127.0.0.1:8547` (the default). **Submit** sends the level, the inputs and the
outputs to `/attest`, then `submit(outputs, [program_hash, expiry, r, s])` through the wallet; the
panel shows the transaction, your best and both boards, and the tier **Provisional (attested)**. The
service answers CORS for any origin, so a page served from elsewhere can call a service on
`127.0.0.1` (see the browser limits under "Hosted build").

A provisional record that is never settled can be expired by anyone after 24 h: it then leaves the
live board and your best falls back to your settled one.

## 5. Settled record: proof in the background, relayed

Needs the **prover service** and about **1.5 hours**, during which you may close the page when the
service relays. It holds the Atlantic API key (never the browser), so whoever runs it needs their own
key and a machine that has built the proving tools (`docs/proving.md`, "Reproduce": the patched
`cairo1-run` and `c1main`). On that machine:

```sh
export ATLANTIC_API_KEY=<your key>                       # in the environment only
export STARKNET_RPC_URL=<a Sepolia RPC>                  # the Satellite and contract reads
export SLINGFALL_ADDRESS=<the v2 contract>
# with STARKNET_ACCOUNT_ADDRESS and STARKNET_PRIVATE_KEY of a funded account the service can send the
# (permissionless) translation transaction and, with --relay, submit_settled for the players
python3 services/prove/prove_service.py serve --relay    # 127.0.0.1:8549
```

then start the client with `VITE_PROVE_URL=http://127.0.0.1:8549` (in `client/.env.sepolia.local`, a
git-ignored file, or exported in the shell before `npm run dev:sepolia`). Then:

1. after **Submit** (or **Prove (settled)** on a Satellite-only deployment) the page posts `POST /prove
   {level, inputs}` by itself; the job id is a hash of level, inputs and program, so repeating the
   same attempt reuses the job. Before anything else the service asks the contract whether its own
   `child_program_hash` is still accepted (`program_valid_until > now`, M6): the current program, or
   the previous one during its grace period after a re-pin. If not, it refuses at once with `409`
   instead of spending ~1.5 h of Atlantic on a proof the contract will not settle; the panel reads the
   same answer from `GET /health` when the page loads and says so up front;
2. the page follows `GET /status/<id>` every minute. With a relay it tells you that you may close the
   page: when the fact lands on the Satellite the service simulates, then sends, `submit_settled` for
   you (the contract records it for the proof's player, whoever sends it), and the page shows
   **Settled by the relay in 0x…** if it is still open;
3. without a relay (or meanwhile), when the fact is on the Satellite **and** the proof's program is
   still accepted, the panel shows **Settle** (or **Settle (cheap)** once the Poseidon fact exists):
   press it and confirm in the wallet. `submit_settled(outputs, args, program)` reads the level back
   from the registry, checks the fact and records the attempt as *settled*. If the relay got there
   first the contract refuses the second settle (`'submit: nullifier'`): your record is settled
   either way.

You can also drive the same flow without the page (`docs/e2e.md` "Sepolia"): `prove_service.py prove
--level pile10 --player <your address> --shot=-604,-392 --watch`, then `deploy/sepolia.sh settle <job>`
(any funded account may send it; the record is the proof's player's).

### What each status means

| shown | meaning |
|---|---|
| `Connected 0x…` | wallet connected; nothing sent |
| `Outputs for 0x…: inputs_hash …, final_state_hash …` | the outputs recomputed for the connected account (m11): what the proof and the settlement actually carry |
| `Proofs blocked: this prover service proves engine release 0x…, which the contract no longer accepts (current 0x…). …` | M6: the service's `child_program_hash` is past its grace period or revoked on the contract; ask the operator to point the service at the new `c1main` |
| `Attested (execute)` / `Attested (verify)` / `WITHOUT a replay` | the attestation service signed after re-executing the attempt, or after verifying your proof; the last form means it runs `--no-verify`: not trustworthy |
| `Provisional record in 0x… (L2 gas …): your best …` | `submit` accepted: the record exists, `settled = false`, it is on the live board; a later settlement upgrades it |
| `Provisional (attested) · …; you may close this page: the prover service settles it for you …` | the proof is being made and the service relays: nothing more to do |
| `Provisional (attested) · …; the proof takes about 1.5 h; come back to this level to settle it` | the service does not relay: come back for **Settle** |
| `Proving · …` | (Satellite-only deployment) the prover service builds the PIE (about 2 min), then Atlantic proves it (trace, SHARP proof, L1 verification, bridge: about 1.5 h in total). The suffix is the service's own description |
| `… proof made with engine release 0x…, which the contract no longer accepts (current 0x…): it cannot be settled` | M6: the fact is on the Satellite, but this proof's program is past its grace period (or revoked); a fresh proof is needed |
| `Settle` / `Settle (cheap)` button | the fact is on the Satellite **and** the proof's program is still accepted: `Settle` uses the bridged keccak fact (more L2 gas), `Settle (cheap)` the translated Poseidon fact |
| `Settling in 0x…` | `submit_settled` sent, waiting for the receipt |
| `Settled by the relay in 0x…: your settled best …` | the service's relay settled it for you; your settled best and the settled board are updated |
| `Settled in 0x…: your settled best …` | your own settle was accepted: `LevelValidated{settled: true}`; replaces the line above, not appended to it (m14) |
| `Submit failed: this exact attempt was already submitted at this tier (perhaps by the relay)` (`'submit: nullifier'`) | this exact attempt (level, player, inputs) was already submitted at this tier: change a shot, or it is already recorded |
| `Settle failed: the contract no longer accepts the engine release …` (`'submit: program'`) | the proof's program is past its grace period or revoked |
| `… refuses this proof or attestation …` (`'submit: proof'`) | no such fact on the Satellite yet, or an expired or stale attestation (key rotated) |
| `Wallet: cancelled in the wallet` | the wallet connection (or the transaction) was cancelled by the user |
| `Wallet: …` / `Settle failed: …` (anything else) | the wallet's or the node's own message, unchanged: contract panics (`submit: *`) and cancellations are translated to plain words (m14), everything else keeps its raw text |

`Provisional` is an attestation of the service's key; `Settled` rests on the SHARP proof verified on
Ethereum and bridged to the Satellite (`proving.md`, "Trust").

### The proven tier (SNIP-36): not on Sepolia yet

Contract v3 (`docs/contract-v3.md`) adds a third tier, **proven**: the shot proven by Starknet itself
(SNIP-36), as a chain of transactions each proven in one proof, sent to the contract and recorded by the
prover service for you. It runs on a local devnet only (`docs/e2e.md`): the Sepolia deployment is still
v2, and no SNIP-36 proof can be made on Sepolia today (the protocol's proof format PROOF2 is not
confirmed there, and the prover needs a large machine). When it arrives the panel needs nothing from you:
a prover service started with `--snip36 snip36 --prover-url <a SNIP-36 prover>` says so on `/health`,
and the page then asks for the proven tier instead of the settled one. What you would see:

| shown | meaning |
|---|---|
| `… planning the SNIP-36 chain of the shot …` | the service runs the shot's transactions to cut them under the proof budget |
| `… proving by SNIP-36: 2/4 transactions proven` | one proof per transaction, in parallel |
| `… sending the SNIP-36 proofs to the contract: 1/4` | one transaction per proof (`submit_chunk`), then `finalize` |
| `Proven by SNIP-36 (the prover service finalized it in 0x…): your settled best …` | recorded: ranked on the settled board with SHARP's |
| board row `… proven by SNIP-36 · bundle 0x…` / `… settled by SHARP · program 0x…` | which proof validated the row, and the release: a SNIP-36 chain's bundle hash, or `c1main`'s program hash |

Cost, measured on the devnet for the pile10 reference shot: 4 proofs, 320M L2 gas (300M of it the
protocol's 75M per proof), about 6.8 STRK at Sepolia's gas price of 2026-09-28 (`docs/proving.md`
"Cost sheet"), paid by the service's account.

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
* **Cost and delay** (measured on the v2 deployment, lot D2, pile10 reference). Provisional: 18 s from the
  attestation request to the record on chain (12 s of them the service's replay), 0.12 STRK for `submit`.
  Settled: 73.5 min from the proof request to the record (PIE 100 s, Atlantic 71 min, of which SHARP 66
  min, then the relay within a minute), 0.38 STRK for the relayed `submit_settled` on the keccak fact
  (less with the translated one; paid by the relay's account when the service relays).
