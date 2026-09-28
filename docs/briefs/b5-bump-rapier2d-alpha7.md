# B5 — bump to `rapier2d = "=0.1.0-alpha.7"` (step results unchanged), pin the new program on Sepolia v2 with a grace period

## 1. Read first
`AGENTS.md`; `docs/briefs/b4-bump-rapier2d-alpha6.md` and the B4 row of `docs/PLAN.md` (the pattern); `docs/contract-v2.md`
(`pin_program`, grace); `deploy/sepolia.sh` (`pin`); rapier-cairo CHANGELOG 0.1.0-alpha.7 (registry source after
`scarb fetch`): step results unchanged, shape-cast results changed for touching starts (the game uses no cast), new
crate `rapier2d_classes` (NOT adopted in this lot), `StageConfig`, `BasicWorldState`.

## 2. Credentials and transactions
`STARKNET_*` in your environment; never print or commit values. Transactions this lot MAY send on Sepolia, and no other:
exactly one `pin_program(new c1main hash, grace)` on contract v2 through `deploy/sepolia.sh pin`, with
`--bit-compatible` (86 400 s) if and only if every golden output is bit-identical to alpha.6; otherwise stop before the
transaction and report. None if the `c1main` program hash is unchanged.

## 3. Scope (allowlist)
Version pins (root `Scarb.toml`, `crates/slingfall_replay/Scarb.toml`, `client/vm/fixtures/ball_drop/Scarb.toml`,
`tools/atlantic/c1main/Scarb.toml`, `deploy/contract/`) + lockfiles; `steps/**`; `fixtures/golden/**` (expected:
unchanged); `client/vm/fixtures/**`; `fixtures/proofs/**` (new program hash record); `deploy/sepolia.json`,
`deploy/slingfall.ts` (the default pin of a fresh deployment); `docs/proving.md` (program-hash history),
`client/vm/README.md` (pinned version). Everything else: "Escalations".

## 4. Work
1. Pin alpha.7; build; `golden.py run` WITHOUT `--update` first: all 11 cases must be bit-identical (outputs and
   `final_state_hash`). Steps table alpha.6 -> alpha.7 per case; `c1main` bytecode size; class sizes.
2. Rebuild executables, stand-in state, `c1main` and its program hash; client fixtures.
3. Sepolia: `pin` as in §2; read `program` back; both programs valid during the grace window (check
   `program_valid_until` of the alpha.6 hash).
4. Report the owner's shot on pile10 (player `123610794124658`, pull (-1022, -63)): expected 5300, 151 ticks.

## 5. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/b5-bump-rapier2d-alpha7`; `gh pr create`; `gh pr checks --watch` in the foreground until green; never merge;
`REPORT.md`. Foreground only: never end your turn on a background command or a scheduled wakeup. Work autonomously,
do not ask questions, do not widen the scope. At most 2 parallel jobs.
