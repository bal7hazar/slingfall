# AGENTS.md

Canonical working agreement for every agent (and human) contributing to `slingfall`.

## 1. Mission

Ship a playable slingshot-destruction game whose every physics tick runs in Cairo, so that a
level's outcome can be proven and validated on Starknet. The physics engine is `rapier2d`
(rapier-cairo); this repository holds the game: level format, rules, replay executables, the
Starknet contract and the web client.

## 2. Principles

1. **Determinism is the product.** The client, the prover and the verifier run the same Cairo
   code on the same fixed-point scalar. No floats anywhere in game logic; iteration orders are
   explicit (event order, ascending handles); nothing depends on dict iteration order.
2. **Cairo steps are the budget.** A shot must fit `docs/DESIGN.md` D10; every lot reports the
   steps of its hot path (`snforge test --detailed-resources --tracked-resource cairo-steps`) and
   the replay executable's steps per shot and per level. Gas matters second (SNIP-36 charges L2 gas).
3. **Use the engine as upstream Rapier is used.** Game code goes through `rapier2d`'s public API
   (the Rust-parity surface); a needed accessor that is missing is an escalation, never a copy
   of engine code. Where a faithful use costs Cairo steps, the cheaper form wins and is documented.
4. **Small, testable diffs.** One lot, one branch, one pull request, one `REPORT.md`.
5. **Measure, never guess** (rapier-cairo's rule): candidates are benchmarked, losers stay under
   `#[cfg(test)] mod alternatives`.

## 3. Roles

| role | does | does not |
|---|---|---|
| **Orchestrator** (the `slingfall` Claude Desktop session) | owns `docs/PLAN.md`, `docs/DESIGN.md`, root and crate `Scarb.toml`, every `lib.cairo`, `.tool-versions`, `scripts/**`, `.github/**`, `client/package.json`; pre-declares stubs; writes briefs; reviews `REPORT.md` + CI; merges; updates status after each merge | large implementation work |
| **Executor** (headless `claude -p`, account claude-b7r, own worktree and branch `feat/<id>`) | implements exactly one brief inside its file allowlist, with tests and step probes; opens its PR, drives CI to green, writes `REPORT.md` | edit shared files (needs go under "Escalations"), merge, ask questions |
| **Reviewer** (the orchestrator, or an `audit-<id>` lot on `codex exec`) | parity with the design, determinism, step tables | first implementation |

Launch: `scripts/executor-unit.sh <id> claude:<sonnet|opus|fable> docs/briefs/<id>.md` (systemd
user unit, survives the session); resume with `scripts/executor-unit.sh resume <id> claude:<model>
"<follow-up>"`. Model by difficulty: Sonnet for mechanical, well-framed lots (converters, fixtures,
renderer on recorded traces); Opus for rules, replay, contract, worker integration; Fable
sparingly. **codex only for audits** (lot id `audit-*`). Programme rules: `docs/ORCHESTRATOR.md`.

## 4. Brief (mandatory sections, in this order)

1. Files to read first (`AGENTS.md`, `docs/DESIGN.md`, the research report the lot implements, style precedents on `main`).
2. Strict scope: file allowlist; everything else is forbidden (needs go to "Escalations").
3. Expected API / data layout (exact names from `docs/DESIGN.md`), what is deferred (DEFER).
4. Step budget of the lot's hot path; candidates to bench when the formulation is not obvious.
5. Tests: table-driven, golden `(level, inputs) -> outputs` fixtures, determinism checks, panics with exact messages; compile budget (≤ 800 lines per file, ≤ 4 `fuzz_*` per module).
6. Definition of done (§6), `REPORT.md` format (Summary · API · Step table · Deviations · Deferred · Escalations · PR URL).
7. "Work autonomously, do not ask questions, do not widen the scope."

## 5. Parallelisation

Disjoint crates / directories per lot on top of pre-declared stubs; one executor per worktree;
CI matrix per crate. Orchestrator-only, serialised: manifests, `lib.cairo` files, `scripts/**`,
`.github/**`, `docs/PLAN.md`, `docs/DESIGN.md`, `client/package.json`.

## 6. Required validation (executor, in the foreground)

Crate-scoped checks only (programme rule 2026-09-25: the shared machine is CPU-capped; the pull
request CI is the full gate):

```
scarb fmt --workspace
scarb lint -p <crate> --deny-warnings && scarb build -p <crate>     # each touched crate + direct dependents
snforge test -p <crate>
python3 scripts/steps.py snapshot --filter <crate>                   # step snapshots of the lot's probes
cd client && npm ci && npm run lint && npm test                        # client lots only
```

Then conventional commits with the trailer `Co-Authored-By: Claude <model> <noreply@anthropic.com>`,
push, `gh pr create` from the template, `gh pr checks --watch` until green, never merge, `REPORT.md`
(git-ignored) at the worktree root. Never run `snforge test --workspace` locally, never background
a command and end the turn, never switch branches, stash or reset, never touch other worktrees.

## 7. Cairo rules (from the ports; measured there)

- Scalars are `fixed::Fixed` (Q32.32 in `i64`); sums of products go through `fixed::wide` kernels;
  no `u256`, no `pow`, no loops in fixed-size math; `DivRem` instead of `/` + `%`.
- Level, inputs, outputs and world state are `Serde` structs; the felt layout is API (`docs/DESIGN.md`).
- Panic messages are stable API (`felt252` constants in an `errors` module).
- The proof build has no `println!`; the trace build's observer is the only place that prints.
- No `starknet` dependency outside `crates/slingfall_contract`.

## 8. Rationalizations to reject

"This accessor is missing, I'll copy the engine's struct." · "Floats only in the client preview."
· "Constant inputs are fine for this probe." · "A small refactor of the neighbouring crate while
I'm here." · "This shared file needs just one line." (escalate) · "I'll add the golden fixture later."
