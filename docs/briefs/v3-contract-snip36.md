# V3 — contract: the SNIP-36 tier (`submit_chunk`, `finalize`), proof facts checked as the protocol defines them

## 1. Read first
`AGENTS.md`; `docs/research/07-split-game-step.md` §4 (the chain: `init`, `step_chunk`, `outputs`, their message
payloads, how a real contract links and finalises them); `docs/research/06-fast-validation.md` §1a;
`/home/claude/projects/pm/research/SN1-snip36-library-call.md` §4 (proof facts layout: program / OS hash at index 2,
`n` messages at index 7, message hashes from index 8; the message hash); `docs/contract-v2.md`;
`crates/slingfall_contract/src/**` (`verifier.cairo`'s `Snip36Verifier` is known wrong on the offsets);
`crates/slingfall_split/src/chain.cairo` (read only: lot H2 is moving that crate).

## 2. Scope (allowlist)
`crates/slingfall_contract/**` (not its dependency pins), `docs/contract-v3.md` (new), `docs/proving.md` (a section
"SNIP-36 tier"). No deployment, no transaction, no credentials, no client or service change (list what they must
follow in `REPORT.md`). `docs/DESIGN.md` D9: propose the text under "Escalations". Do not depend on
`slingfall_split` from the contract: the contract knows the chain only by its address, its marker and its payloads.

## 3. Work
1. **Third tier** beside provisional and settled: `PROVEN` (SNIP-36), ranked with settled (both are proofs; record
   which one). Shared nullifier; an attested attempt can be upgraded by either.
2. **`submit_chunk(kind, payload)`**: reads `proof_facts` of the transaction (`get_execution_info_v3`), checks the
   virtual-OS program hash against an admin-managed set with grace (same shape as `programs`), the base block
   constraints the protocol exposes, and that `poseidon([chain_address, MARKER, len(payload), ...payload])` is among
   the message hashes; stores `start[LEVEL_HASH]`, `edge[(INPUTS_HASH, STATE_IN_HASH)]`, `end[(INPUTS_HASH,
   STATE_IN_HASH)]` as the research specifies. Several chunks per transaction if calldata allows (measure).
3. **`finalize(level_hash, inputs, player…)`**: walks from a `start` of the level through the edges to an `end`,
   bounded (max edges as a constant, measured gas per edge), checks the level is registered and active, the inputs hash,
   the player bound in the inputs, the shots order (`shot`, `k` monotonic as the chain defines), then records the
   outputs for `claim.player` (relay allowed, like `submit_settled`).
4. **Admin**: chain address and marker, the set of accepted class-hash bundles per release (a record proven with a
   retired bundle is refused after its grace), the virtual-OS program set. Everything through the existing two-step
   admin; `upgrade` can carry the v2 deployment to v3 (write the storage-compatibility check as a test: v2 storage
   read by v3 code).
5. **Tests**: proof facts faked through snforge's cheat codes on the execution info (if 0.61 cannot fake
   `proof_facts`, isolate the read behind one internal function and test everything else through it; say so);
   negative tests: wrong program hash, message not in the facts, message from another address, broken link, chunk of
   another inputs hash, unfinished chain, replay (nullifier), too many edges, retired bundle, third-party relay.
   Gas table: `submit_chunk` per chunk, `finalize` for 5 and 7 chunks. Class size of `Slingfall` (limit 81,920; keep
   it under 73,728).

## 4. Definition of done
`AGENTS.md` §6 crate-scoped checks (`-p slingfall_contract`); conventional commits with the trailer
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push `feat/v3-contract-snip36`; `gh pr create`;
`gh pr checks --watch` in the foreground until green; never merge; `REPORT.md`. Foreground only. Work autonomously,
do not ask questions, do not widen the scope. At most 2 parallel jobs.
