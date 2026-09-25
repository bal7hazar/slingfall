# Orchestration of `slingfall`

The orchestrator session of this repository follows the model of `rapier-cairo/docs/ORCHESTRATOR.md`
(local CLIs, worktrees, briefs, `REPORT.md`, merge on green CI + review) with the programme rules
of `/home/claude/projects/pm/OPERATIONS.md`, restated here:

- **Executors run on the `claude` CLI** (account claude-b7r): Sonnet 5 for mechanical lots, Opus 5.5
  for rules / replay / contract / worker, Fable 5.1 sparingly. **codex only for audits** (`audit-*`).
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
