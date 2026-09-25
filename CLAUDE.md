# CLAUDE.md

Behavioural rules live in [`AGENTS.md`](AGENTS.md); read it first. Context only here.

- Plan and lots: `docs/PLAN.md`. Decisions: `docs/DESIGN.md`. Orchestration: `docs/ORCHESTRATOR.md`.
- Research (copied from the programme folder `/home/claude/projects/pm/`): `docs/research/`.
- Toolchain: scarb 2.19.4, snforge 0.61.0 (`.tool-versions`, asdf); Python 3 stdlib for scripts;
  Node 24 + Vite + TypeScript + PixiJS for `client/`.
- Physics comes from `rapier2d` (registry, pre-release pinned exactly); never vendor or fork it:
  a missing accessor is an escalation to the rapier-cairo orchestrator through the programme session.
- The programme session ("Angry Birds Cairo orchestration", Claude Desktop, cwd `/home/claude/projects`)
  owns cross-repository arbitration; escalations go there, not to sibling repositories.
