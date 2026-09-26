# E3a — Stone + Integrity round trip on Sepolia through Atlantic: prove `main`, verify on-chain, read the fact

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D9 (Integrity fallback: `fact = poseidon(program_hash, output_hash)`);
`docs/research/01-proof-pipeline.md` §2 (Integrity: FactRegistry addresses on Sepolia / mainnet, `fact_hash` /
`verification_hash` rules, layouts, security bits) and §3 (Atlantic: job sizes, `PROOF_VERIFICATION_ON_L2`, the
`Felt252Dict` + builtins trace-generation known issue and its local-PIE workaround), `01b` (audit); on `main`:
`crates/slingfall_replay/` (`main`, README argument layouts), `tools/golden/golden.py` (running a case),
`fixtures/golden/one_block-miss.json` and `pile10-reference.json`, `tools/tracec/tracec.py args`.
Web (read, cite): https://docs.herodotus.cloud/atlantic-api (introduction, sending-query, known-issues, steps /
l2-proof-verification, the OpenAPI at https://atlantic.api.herodotus.cloud/docs/json), https://github.com/HerodotusDev/integrity
(README + `deployed_contracts.md`: Sepolia FactRegistry, `get_all_verifications_for_fact_hash`, the settings /
security-bits encoding, the fact hash formula for Cairo 1 executables and the bootloader).

## 2. Credentials (in your unit's environment; never print them, never write them to a file in the repo)
`ATLANTIC_API_KEY` (header `api-key`), `STARKNET_RPC_URL` (public node: send a `User-Agent` header, e.g.
`slingfall/1.0`, or it answers 403), `STARKNET_ACCOUNT_ADDRESS` / `STARKNET_PRIVATE_KEY` / `STARKNET_ACCOUNT_TYPE`
(a Braavos dev account with funds: only read calls in this lot; NO transaction is sent from it in E3a).

## 3. Scope (allowlist)
`tools/atlantic/**` (new, Python 3 stdlib + `curl`; a `venv` under `tools/atlantic/.venv` git-ignored if a package is
unavoidable), `fixtures/proofs/**` (small files: job ids, fact hashes, outputs; no proof blobs), `docs/proving.md`
section "Atlantic + Integrity" (create the file if P1 has not merged yet; keep the section self-contained),
`.gitignore`.

## 4. Work
1. Program artefact: build `slingfall_replay` and produce what Atlantic's Cairo 1 lane wants: try in this order
   (a) `scarb execute --output cairo-pie` of `main` on `one_block-miss` (2.8M steps; args via `tracec.py args`) and
   submit the `.zip` PIE (job size S); (b) if the PIE lane fails on the `Felt252Dict` + builtins issue, the
   known-issues workaround (local PIE with Herodotus's cairo-vm fork); (c) the program + input lane. Record the exact
   request bodies (without the key), the layout chosen (`auto` / `recursive` / `dynamic`: Integrity cannot verify
   `dynamic`; report which layouts Atlantic accepted and which Integrity supports), `sharpProver = stone`,
   `PROOF_VERIFICATION_ON_L2` on Sepolia, `network` / `chain` fields as the OpenAPI names them.
2. `tools/atlantic/atlantic.py`: `submit --pie <zip> [--layout ...]` → job id; `status <job>` (poll; print stage
   transitions and timestamps); `fact <job>` (fetch the proof's public output / fact hash); `check-fact <fact_hash>`
   (read `get_all_verifications_for_fact_hash` on Integrity's Sepolia FactRegistry through the RPC: print security bits
   and settings). Idempotent, `--json`.
3. Run it end to end on `one_block-miss`, then on `pile10-reference` (10.7M steps: job size S or M; report the price
   tier). Record: latency per stage, proof size if exposed, the fact hash, the verification transaction hash on
   Sepolia (from the job details or from the registry's events), and the exact **fact formula**: how `program_hash`
   is computed for our executable (bootloaded? the executable's hash as Atlantic reports it) and how the
   `output_hash` covers our 10 output felts (order, length prefix, panic flag). Verify by recomputing
   `poseidon(program_hash, output_hash)` in Python (stdlib Poseidon exists in `tools/levelc/poseidon.py`) and matching
   the fact registered on-chain.
4. Write the contract-side spec for E3b: what `IntegrityVerifier::check(outputs, evidence)` must do
   (recompute `fact_hash` from `PROGRAM_HASH` and the outputs, call the FactRegistry, require ≥ 96 security bits /
   the expected settings; the registry's interface and address), and the client / service flow (who submits the
   Atlantic job, polling, what the player sends to `submit`).

## 5. Budget
Report Atlantic costs (credits) and latencies; nothing else.

## 6. Tests
`atlantic.py check-fact` returns the on-chain verification for the fact you registered; the Python recomputation of
the fact matches. Unit tests of the encoding helpers.

## 7. Definition of done
`AGENTS.md` §6 (tools only); conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`;
push `feat/e3a-atlantic-integrity`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · Runs table (case, lane, layout, job id, stages + latency, fact hash, verification tx) · Fact formula ·
E3b contract spec · Deviations · Escalations · PR URL). Work autonomously, do not ask questions, do not widen the scope.
