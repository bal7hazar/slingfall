# V2 — contract v2: program grace set, relay by `claim.player`, tiered boards, domain-separated attestations, upgradeability (code only)

## 1. Read first
`AGENTS.md`; `docs/research/06-fast-validation.md` §2.0-2.3 (the design this lot implements, with its attack surface)
and §1a "Splitting and chaining" (context only); `docs/qa/2026-09-26-mac.md` M6, M7, S10, S12; `docs/DESIGN.md` D9;
`docs/proving.md`; `crates/slingfall_contract/src/**` and its tests.

## 2. Scope (allowlist)
`crates/slingfall_contract/**` (not its `Scarb.toml` dependency pins: lot B4 is bumping them), `docs/proving.md`
(contract sections), a new `docs/contract-v2.md`. No deployment, no transaction, no credentials, no client or service
change (a later lot wires them): list the interface changes the client and services must follow in `REPORT.md`.
`docs/DESIGN.md` D9 belongs to the orchestrator: propose its new text under "Escalations".

## 3. Work
1. **Programs**: `programs: Map<felt252, u64>` (`valid_until`), `current_program`; `pin_program(hash, grace_s)`,
   `revoke_program(hash)`, `program_valid_until(hash)`; `submit_settled(outputs, args, child_program_hash)` asserts the
   hash is valid now and builds the fact with it; `Record` and `LevelValidated` carry `program_hash`.
2. **Relay**: `submit_settled` records for `claim.player` whatever the caller; the attested `submit` keeps
   `caller == player`.
3. **Tiers**: a provisional record never hides a settled one (`best_settled`, settled and provisional boards or an
   equivalent you measure cheaper); permissionless `expire(level, player)` demotes a provisional record older than an
   admin-set delay (default 24 h) that was never settled.
4. **Attestations**: signed message `poseidon('SLINGFALL_ATTEST', chain_id, contract, program_hash, epoch, expiry,
   outputs...)`; key rotation bumps the epoch.
5. **Upgradeability**: `upgrade(class_hash)` (admin, `replace_class_syscall`), with an event; two-step admin transfer.
6. Both verifiers stay available at once (provisional through the attestation, settled through the Satellite): no
   `set_verifier` switch needed for the two tiers to coexist.
7. Tests: every new entry point, every attack of research 06 §2 as a negative test (stale program after grace,
   revoked program, replayed attestation across contract / epoch / program, relayed settle by a third party, race
   loser on the nullifier, provisional not hiding settled, expire before and after the delay). Gas table before /
   after for `submit` and `submit_settled`; class sizes of `Slingfall` (limit 81 920 felts, Sierra and CASM).

## 4. Definition of done
`AGENTS.md` §6 crate-scoped checks (`-p slingfall_contract`); conventional commits with the trailer
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push `feat/v2-contract`; `gh pr create`;
`gh pr checks --watch` until green (foreground); never merge; `REPORT.md`. Work autonomously, do not ask questions, do
not widen the scope. At most 2 parallel jobs.
