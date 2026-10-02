# Playing Slingfall locally, with one command (lot L1)

Everything on your own machine: a local Starknet devnet with the contract (v3), the attestation service,
the prover service and the web client. The three validation tiers work with no credential, no testnet
and no wallet extension; the proofs are **simulated** (below). Supported: macOS on Apple silicon and
Linux x86_64.

```sh
scripts/play.sh doctor     # what is missing, and how to install it (installs nothing)
scripts/play.sh            # (or `up`) builds what is missing once, starts everything, prints the URL
scripts/play.sh status     # what runs, where; the contract and the player
scripts/play.sh down       # stops exactly what `up` started; the devnet saves its state first
scripts/play.sh reset      # `down`, then forgets the devnet's state: the next `up` deploys afresh
```

Then open **http://127.0.0.1:5173/**. The strip at the top right says **local devnet: proofs are
simulated**.

## Prerequisites

`scripts/play.sh doctor` checks each of these, says how to install what is missing, and checks that the
ports are free.

| | needed for | install |
|---|---|---|
| Node 24 (`.tool-versions`: 24.21.0) | the client, `deploy/slingfall.ts` | `asdf plugin add nodejs && asdf install nodejs 24.21.0` |
| scarb 2.19.4 | the replay, the contract, the proven tier's classes | `asdf plugin add scarb && asdf install scarb 2.19.4` |
| snforge 0.61.0 | the Cairo tests only (not to play) | `asdf plugin add starknet-foundry && asdf install starknet-foundry 0.61.0` |
| Python 3.10+ | both services (standard library only) | macOS: `brew install python`; Linux: the distribution's `python3` |
| Rust (rustup) | once, to build the browser's Cairo VM (`client/vm/`, a few minutes) | https://rustup.rs; the pinned toolchain installs itself |
| curl, tar | the devnet's release binary | present on both systems |

asdf reads `.tool-versions` (`asdf install` at the repository root installs all three pins; on macOS
`brew install asdf` first). `starknet-devnet` 0.10.0 needs nothing from you: the first `up` downloads its
release binary for your platform into `deploy/.devnet/bin/`.

## What `up` does

1. **Builds, once**: the client's dependencies (`npm ci`), the wasm runner (`client/vm/scripts/build.sh`,
   Rust), the replay executables (`crates/slingfall_replay`) and the proven tier's classes
   (`slingfall_split`), one after the other. Each is skipped when it exists.
2. **The devnet** (`deploy/devnet.sh`, port 5050): starknet-devnet `--seed 0`, contract v3 deployed with the
   public devnet attestation key ('slingfall-devnet', never a real one), the six levels, the devnet's
   `FakeSatellite`, and the proven tier opened (`SplitChain`, marker, virtual OS, `pin_chain`). This takes
   about a minute the first time; `down` saves the devnet's state to `target/play/devnet-state.json` and the
   next `up` loads it instead (your records survive).
3. **The attestation service** (port 8547): `services/attest/attest.py serve --execute` (it re-executes
   each attempt with `scarb execute` before signing; no rate limit locally).
4. **The prover service** (port 8549): `scripts/play/prove_local.py`, the service of
   `services/prove/prove_service.py` with the fake SNIP-36 prover and a fake Atlantic (below).
5. **The client** (port 5173): Vite in devnet mode. The page reaches the devnet and both services through
   the dev server itself (`/rpc`, `/attest-service`, `/prove-service`, `scripts/play/vite.config.mts`), so
   the services never leave 127.0.0.1.

Everything listens on 127.0.0.1. Logs and PID files are in `target/play/`; `down` stops only the processes
whose PID files `up` wrote (and checks they are still those processes). A second `up` reuses whatever
already runs, and restarts a service only when the devnet had to be redeployed.

Accounts (the devnet's predeployed ones, deterministic with `--seed 0`): **#1 is you**, the player; #0 the
admin (and the `FakeSatellite`'s facts); #2 the prover service's SNIP-36 transactions; #3 its relay.

Measured on the development machine (Linux x86_64, 8 cores): first `up` 314 s (wasm runner, replay and
deployment; the split classes, built beforehand, take 48 s more alone), a second `up` while everything
runs 1 s, an `up` after `down` 21 s (the devnet reloading its saved state). See the lot's `REPORT.md`.
On a Mac (Apple silicon, lot L2, `docs/qa/2026-09-30-mac-play.md`): the builds took 6 m 46 s (wasm runner),
8 min (replay) and 3 min (split classes); `up` with them cached 63 to 87 s on a fresh devnet and 29 s after
`down`; in the browser, Prove (SNIP-36) took 275 s and Settle 52 s.

## Playing: the three tiers here and on Sepolia

Pick a level, drag the pebble, release. A strip at the top says "local devnet: proofs are simulated". At the end
of the level the panel (folded to its title and summary so that the board stays visible: **Details** opens it)
**Submit on the local devnet
(proofs are simulated)** is already connected with account #1 (no wallet to pick). **Submit** gives the
provisional record in seconds; the panel then offers the proof of that attempt, at one tier of your choice
(the contract records an attempt proven *or* settled, not both: play again for the other; once you pick a
tier, both buttons go away):

| tier | here (local) | on Sepolia |
|---|---|---|
| **Provisional** | `attest.py --execute` re-executes your attempt with `scarb execute` and signs with the public devnet key; you `submit`. Seconds. | The same, with the operator's secret key. Seconds. |
| **Proven** (SNIP-36): **Prove (SNIP-36, simulated)** | The service plans the attempt's chain of transactions, "proves" each with the **fake prover** (the devnet runs `--proof-mode none`: it ignores the proof, but checks its facts' layout as the protocol does), sends them and `finalize`s for you. About a minute. | Not available yet (`docs/testers.md` "The proven tier"): needs a real SNIP-36 prover. |
| **Settled** (Atlantic + SHARP): **Settle (Atlantic, simulated)** | No Atlantic and no proof: the service replays your attempt, computes the fact a real proof would carry, registers it on the devnet's **FakeSatellite** at once, and its relay sends `submit_settled` for you. Seconds. | Herodotus Atlantic proves the attempt, SHARP verifies it on Ethereum and the fact is bridged to the Satellite: about 1.5 h. |

Both boards of the level are shown after each step: **Settled (proven: SHARP or SNIP-36)** and **Live
(provisional and settled)**, each row with its proof and release. What a local record proves: that the
contract, the services and the page agree on your attempt; nothing about its proof, which nobody made.

## Resetting the devnet

`scripts/play.sh reset` stops everything and deletes the saved state (`target/play/devnet-state.json`), the
deployment record and the prover service's jobs; the next `up` deploys a fresh contract (about a minute).
Do it after pulling a change to the contract or the levels, or to empty the boards. The builds are kept;
to rebuild one, delete it (`client/vm/pkg/`, `crates/slingfall_replay/target/`, `target/dev/`).

## Your environment is ignored

The local mode drops the `STARKNET_*`, `SLINGFALL_*`, `ATLANTIC_*`, `VITE_*` and `DEVNET_*` variables of
your shell (and starknet-devnet's own, such as `FORK_NETWORK`) and says which ones it ignored: every
process gets the devnet's values only. This closes the defect found by lot B6: `tools/atlantic`'s
`account_env` prefers `STARKNET_RPC` to `STARKNET_RPC_URL` while its reads use `STARKNET_RPC_URL`, so a
devnet job started from a shell holding a Sepolia `STARKNET_RPC` could read one network and send to the
other. Here both names are set to the devnet, and no key of yours reaches any process.

## Playing from another device (phone, tablet)

```sh
PLAY_HOST=0.0.0.0 scripts/play.sh
```

prints `http://<this machine's address>:5173/` too; open it on a device of the **same network**. Only the dev
server listens on the network; the devnet and the services stay on 127.0.0.1 behind it, but **anyone on
the network can reach them through it**: the devnet's RPC (including its `devnet_*` methods: minting,
time travel), the attestation and the prover services. **Never do this on a network exposed to the
internet** (a café, a hotel, a machine with public ports): this mode has no authentication and signs with
public test keys. Stop with `scripts/play.sh down`. To change the address of a running setup, `down`
first (a second `up` reuses the running dev server as it is).

## Troubleshooting

* **A port is taken** (`port 5050 is taken by another process`): another devnet (`deploy/devnet.sh`,
  `deploy/e2e.sh` uses 5055), another Vite, another service. Stop it, or move ours: `PLAY_PORT`,
  `PLAY_DEVNET_PORT`, `PLAY_ATTEST_PORT`, `PLAY_PROVE_PORT`. Keep the devnet's port off the WHATWG
  "bad ports" list (5060, 5061, 6000, ...): Node's `fetch` (the deploy tool) refuses them.
* **Node version**: Vite 8 and starknet.js 10 need Node 24 (`doctor` says which one runs). `doctor` and
  `play.sh` accept any Node 24.x: if the shell's `node` is another major (a Node 22 first on `PATH`) but
  asdf has a 24.x installed, they use it for every command they run and say so (`note  node`); run
  `node scripts/play/check.ts` from a shell whose `node` is 24 (`asdf shell nodejs 24.21.0`). With none
  installed: `asdf install nodejs 24.21.0` at the repository root; with nvm, `nvm install 24`.
* **"VM not built"** on the page: the wasm runner was not built (Rust missing, or `PLAY_NO_VM=1`); the page
  only replays a recorded trace. Install Rust and run `scripts/play.sh` again.
* **Safari**: the page and the services share one origin (the dev server's proxy), so Safari's refusal of
  pages that call `http://127.0.0.1` from elsewhere (docs/testers.md "Hosted build") does not apply. If
  Safari on iOS or macOS cannot open the address of another machine, check that both are on the same
  network, and that the Mac's firewall lets Node accept incoming connections (System Settings > Network >
  Firewall). If macOS asks whether Node or your terminal may accept connections or access the local
  network, allow it (System Settings > Privacy & Security > Local Network). Playing on the Mac itself, in
  Chromium, is verified (lot L2); the LAN address (`PLAY_HOST=0.0.0.0`), Safari and the firewall dialog are not.
* **`No version is set for command starknet-devnet`** (asdf's shim): `deploy/devnet.sh` ignores a
  `starknet-devnet` that does not run and downloads its own release binary into `deploy/.devnet/bin/` and looks it up again (a first `up` used to stop
  silently there); if the installed binary still does not run, `up` prints the failing command and its output.
* **Something failed during `up`**: its last lines are printed; the whole log is in `target/play/`
  (`deploy.log`, `vm-build.log`, `replay-build.log`, `split-build.log`, `attest.log`, `prove.log`,
  `client.log`, `devnet-5050.log`). After a contract change, `scripts/play.sh reset`.
* **A proof job failed** (the panel says `proof failed: ...`): `target/play/prove.log`; the job's files are
  in `target/play/prove/<contract>/<job>/`.

## Checked in CI

The `play-local` job runs `scripts/play.sh up` on a fresh Ubuntu runner (without the wasm runner,
`PLAY_NO_VM=1`), then `node scripts/play/check.ts`: the page's own modules (`client/src/chain`) make the
page's calls through the dev server, for account #1: the pile10 reference shot attested, submitted and
proven (SNIP-36, fake prover), a bridge shot attested, submitted and settled (FakeSatellite, relay), then
both boards of both levels. Then `status`, `down`, and a second `up` from the saved state.
