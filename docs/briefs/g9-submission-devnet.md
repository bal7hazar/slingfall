# G9 — end-to-end on a local devnet: attestation service, client submission flow, deploy scripts

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D9 (two-class contract, `StubVerifier`: admin-signed ECDSA attestation over
`poseidon(outputs felts)`, nullifier, `submit(outputs, evidence)`), `docs/research/01-proof-pipeline.md` §4 rank 2
(attested path), `docs/research/05-local-proving.md` (what a proof and its outputs look like); on `main`:
`crates/slingfall_contract/` (ABI: `register_level`, `submit`, `best`, `leaderboard`, admin `set_verifier` /
`set_attestation_key`; `tools/vectors.py` for the key / signature vectors), `client/src/` (end-of-level panel with
the 10 output felts and "copy inputs"; `game/session.ts`), `client/README.md`. P1 (prover tooling, Opus) runs in
parallel: do not depend on its files; the service accepts a proof path + outputs and calls a `verify` command that
P1 provides (`tools/prove/verify.py`; until it exists, a `--no-verify` flag with a loud warning).

## 2. Scope (allowlist)
`services/attest/**` (new: Python 3 stdlib + `starknet.py`-free signing: the ECDSA on the STARK curve as in
`crates/slingfall_contract/tools/vectors.py`), `deploy/**` (new: devnet scripts, `sncast` profiles), `client/src/**`,
`client/package.json` + lockfile for `starknet` (starknet.js) and `get-starknet` / Cartridge Controller SDK,
`client/README.md`, `docs/e2e.md` (new), `.github/workflows/ci.yml` ONLY an `e2e` job if `starknet-devnet` is
installable on the runner in reasonable time (else document local-only).

## 3. Work
1. `deploy/devnet.sh`: start `starknet-devnet` (install via `pip`/`cargo` in a local venv / `~/.cargo`; document
   the version), declare `Slingfall` (registry class; `SlingfallSim` is NOT deployable: skip it), deploy with the
   devnet's prefunded account as admin, set `verifier = Stub`, `set_attestation_key`, register the six fixture
   levels (`register_level` with the felts of `fixtures/levels/*.felts.json`), write `deploy/devnet.json` (addresses,
   class hash, level hashes). `deploy/sepolia.sh`: the same with `sncast` profiles reading the account from env,
   not run here (owner's keys), documented.
2. `services/attest/`: `attest.py serve --key <hex> --verify-cmd "<cmd>"`: HTTP `POST /attest {outputs: [10 felts],
   proof_path or proof (base64)}` → runs the verify command (P1's) → on success signs
   `attestation_hash = poseidon_hash_span(outputs)` (must equal the contract's `verifier::attestation_hash`: reuse
   `crates/slingfall_contract/tools/vectors.py`'s Poseidon / signing) → returns `[r, s]`. `attest.py sign` for
   offline use. Tests: a vector matching the contract's `GOLDEN_R / GOLDEN_S` fixtures.
3. Client: a "Submit" step after the level: wallet connection (get-starknet, plus Cartridge Controller if its SDK
   installs cleanly; else get-starknet only and say so), `POST /attest` with the outputs (+ the proof path when
   P1's tooling produced one; for the MVP the attestation service may run on the same machine that proved), then
   `submit(outputs, [r, s])` through the wallet; show the transaction hash, then `best(player, level_hash)` and
   the leaderboard. Config from `deploy/devnet.json` (`VITE_SLINGFALL_ADDRESS`, RPC URL).
4. `docs/e2e.md`: the whole flow on the devnet with exact commands, and the Sepolia variant.
5. Scripted end-to-end check `deploy/e2e.sh`: devnet up → deploy → run the reference shot outputs from
   `fixtures/golden/pile10-reference.json` → attest → `submit` with the devnet account as the player (the outputs'
   `player` felt must be the caller: regenerate the outputs for the devnet account by running `main` with
   `inputs.player` = that account through `scarb execute`, as `tools/golden/golden.py` does) → assert `best`
   returns the score and `LevelValidated` was emitted; a second submit is rejected (`'submit: nullifier'`).

## 4. Budget
`submit` gas on the devnet reported; nothing else.

## 5. Tests
`deploy/e2e.sh` green locally (documented output in the report); Vitest for the client's submit encoding and the
attest client; `attest.py` unit tests.

## 6. Definition of done
`AGENTS.md` §6 client part + the scripts; conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
push `feat/g9-submission-devnet`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · Flow · e2e transcript · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
