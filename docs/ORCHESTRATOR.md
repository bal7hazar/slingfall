# Orchestration of `slingfall`

The orchestrator session of this repository follows the model of `rapier-cairo/docs/ORCHESTRATOR.md`
(local CLIs, worktrees, briefs, `REPORT.md`, merge on green CI + review) with the programme rules
of `/home/claude/projects/pm/OPERATIONS.md`, restated here:

- **Executors run on the `claude` CLI** (account claude-b7r): Sonnet 5 for mechanical lots, Opus 5.5
  for rules / replay / contract / worker, Fable 5.1 sparingly. **codex only for audits** (`audit-*`)
  and for the review of every pull request (below); never for implementation.
- **Local checks are crate-scoped; the pull-request CI is the full gate.** Never a workspace test run
  on the shared machine (`AGENTS.md` §6). Builds go through the machine's `scarb` / `snforge` shims.
- **Machine budget: 6 executors machine-wide**, shared with rapier / nalgebra / glam; check
  `systemctl --user list-units --state=running | grep -E 'pm-|glam-|nalgebra-|rapier-|slingfall-'`,
  `free -g`, `uptime` before every launch; 2 at a time for this repository when others are busy.
- **Executors are transient systemd user units** (`scripts/executor-unit.sh`, copied from rapier),
  never children of the session; resume an interrupted one, never relaunch from scratch.
- **Background task titles start with the model** (`[Opus 5.5] Wait for G3's CI`).
- **Escalations** (a missing `rapier2d` accessor, a numeric question for `fixed`, a proof-pipeline
  question) go to the programme session by cross-session message to "Angry Birds Cairo
  orchestration", after being written in `docs/PLAN.md`; never sideways to sibling repositories.
- Dependencies by registry version only (`rapier2d` pre-release pinned exactly); a bump is its own PR.
- After each merge the orchestrator alone updates `docs/PLAN.md` (status line, lot table), re-exports
  and step ceilings, then pushes to `main`.

## The review of every pull request by codex (owner's rule, 2026-09-29)

The code of **every pull request of a lot** is reviewed by codex before it is merged, whatever
`audit-*` lot the plan also asks for. The review reads the changes themselves, on another vendor's
model than the one that wrote them, and looks for what would hurt once merged: code that does not
do what it says, a case that is not handled, something that worked and no longer does, a result of
the replay that moved, a test that does not test what it names.

| | |
|---|---|
| Who asks | The orchestrator, once the checks of the pull request are green |
| Launch | `nexus review --project slingfall --task <id> --repository slingfall --branch feat/<id> --brief docs/briefs/<id>.md`, then `nexus wait slingfall/review-<id>` as a background task titled with the model |
| What runs | codex in its **read-only** sandbox, on the head of the branch, compared with `origin/main`, with a fresh context. It counts in the machine budget as an executor does |
| Report | `nexus report slingfall/review-<id>`: a verdict (`PASS`, `PASS WITH FINDINGS`, `FAIL`), the revision that was read, findings with a severity and an evidence |
| Findings | `blocker` and `major` block the merge; `minor` blocks unless deferred with an entry in `docs/PLAN.md`; `note` does not. The orchestrator verifies a finding before acting on it: reviewers can be wrong. The fix is made by resuming the executor |
| After a fix | The review is asked again: a new reviewer, `review-<id>-2`, on the new head. A review covers the revision it names and no other |

**Merging without the review** is the orchestrator's decision, in two cases:

| Case | How it is known |
|---|---|
| Codex cannot review | `nexus accounts` shows its account `unavailable`, the review ended `blocked_quota` or `failed`, or it could not read or run anything |
| The change needs none | Nothing that runs changed (documents, plan, briefs), or a change of a few lines that the checks cover |

Never for a lot that touches the rules, the replay, the contract, a proof or a deployment: those
wait for codex, or for the owner. A merge without the review says so in the pull request:
`Codex review: none — <reason>`. When codex could not review, the orchestrator writes it in
`docs/PLAN.md` and tells the programme session: repairing it is the owner's.
