# Operating document of the project `slingfall`

What is specific to this project, added to the standard roles of Nexus (`bal7hazar/nexus`). It never restates
the standard; where it would contradict it, the standard wins. The project manager owns this file.

## 1. Scope and repositories

The game Slingfall (working name) and the Cairo libraries it is built on. Everything runs on the Q32.32 fixed-point
scalar `fixed::Fixed`; numeric results are API (a last-bit change is a MINOR bump and a CHANGELOG entry).

| Track | Repositories | Orchestrator session | Its documents |
|---|---|---|---|
| glam | fixed-cairo, glam-cairo, glamx-cairo | opened on need (the former session is retired) | glam-cairo `docs/PLAN.md`, `HANDOFF.md` |
| nalgebra | simba-cairo, nalgebra-cairo | "[Opus 5.5] Orchestrateur nalgebra — slingfall" | nalgebra-cairo `docs/PLAN.md`, `docs/SPLIT.md` |
| rapier | rapier-cairo | "[Opus 5.5] Orchestrateur rapier — slingfall" | rapier-cairo `docs/PLAN.md`, `AGENTS.md`, `docs/ORCHESTRATOR.md` |
| game | slingfall | the project manager, as interim orchestrator | `docs/PLAN.md`, `docs/DESIGN.md`, `docs/ORCHESTRATOR.md`, `AGENTS.md` |

The programme's plan, decisions, research and status live in the project manager's notebook
(`/home/claude/projects/pm` on the VPS: `PLAN.md`, `STATUS.md`, `RESUME.md`, `decisions/`, `research/`, `reports/`).

### Sessions

A new session (an orchestrator, a successor) is proposed with the Desktop suggestion chip, as the standard's skill
`nexus-organisation` ("Create a session") says; its context is a committed file of the notebook
(`pm/messages/orchestrators/<track>-<date>.md`). A retired session keeps the prefix `[Retired]` and stands by.

## 2. Models by kind of session and of task

Sessions: the project manager runs on Fable 5.1; every orchestrator on Opus 5.5 (owner, 2026-10-01, to save Fable
quota); a session's title carries the model actually used.


| Kind of task | Model | Notes |
|---|---|---|
| Mechanical, well-framed lot (fixtures, converters, bumps with no numeric change, doc tables, copying a script) | Sonnet 5.5 | the tighter the brief, the smaller the model |
| Standard port or feature with numerics (kernels, tests, golden vectors, benches; game rules, replay, contract, worker) | Opus 5.5 | default for anything that touches results |
| Genuinely hard problem (novel numerics, hard debugging, cross-module or cross-class design, research spikes) | Opus 5.5, Fable 5.1 sparingly | say why in the brief when Fable is chosen |
| Review of a pull request | Codex, the model the project names for reviews; **while Codex has no quota, Claude Sonnet** (owner, 2026-10-01; Nexus falls back by itself) | `nexus review`, read-only; the routine gate of every pull request |
| Audit (the few kinds of §6) | Codex `gpt-6-sol`; `gpt-6-astra` for security and hard numeric cross-checks; **while Codex has no quota, Claude Opus 5.5** | `nexus audit`, read-only, never implementation; the exception, not the routine |

Implementation never runs on Codex. The in-session Agent tool is used only for short read-only research.

## 3. The machine and the budgets

- VPS (Hostinger, 8 vCPU / 31 GB, already the provider's largest plan; shared with the owner's other projects). Heavy
  work is one job machine-wide: `scarb` / `snforge` go through the shims that serialise heavy subcommands behind
  `~/orchestrator/heavy-build.lock` (rapier: a per-project lock for crate-scoped builds plus the shared heavy lock).
- Before every launch, read `~/orchestrator/capacity.json` (written every 2 minutes by the project manager's timer
  `pm-capacity`): launch only if the file is under 5 minutes old, `can_launch` is true, `oom_kills_30min` is 0 and
  `free_slots` is at least 1 (rapier: at least 2, one slot always left to nalgebra). Per orchestrator: 2 agents at a
  time (nalgebra up to 4 while its split runs, back to 2 after any OOM kill), one heavy suite at a time.
- Every agent is a transient systemd user unit with a memory cap (`MemoryMax` 12-14 GB; the user slice is capped at
  24 GB and 600 % CPU). `scarb prove` (Stwo) needs more than 22 GB: never on this VPS.
- Local checks are crate-scoped (`-p <crate>`); the pull-request CI is the full gate. Never `snforge test --workspace`
  on the shared machine. Every repository keeps its CI under about 10 minutes and splits test crates before they grow.
- `~/orchestrator/slots/` belongs to another project's launcher: never touched.
- The SNIP-36 prover (about 96 GB) is rented on demand elsewhere, on the owner's decision, never run here.

## 4. Launchers

Until this document names `nexus` for a track, implementers start with the track's launcher; reviews, audits and work
for the Mac go through `nexus`.

| Track | Launcher | Brief | Worktree, unit, log |
|---|---|---|---|
| glam | glam-cairo `scripts/agent.sh <task> claude <model> new "<prompt>"` | glam-cairo `docs/briefs/<ID>-<slug>.md` (+ `COMMON.md`) | `.claude/worktrees/cli-<task>`, log `.claude/worktrees/logs/<task>.log` |
| nalgebra | nalgebra-cairo `scripts/agent.sh` as a `systemd-run --user` unit `nalgebra-<wp>` (see its `docs/ORCHESTRATOR.md`) | `docs/briefs/wp-<n>.md` (since 2026-09-30) | `~/orchestrator/nalgebra-cairo/wt/<wp>`, logs and reports under `~/orchestrator/nalgebra-cairo/` |
| rapier | `scripts/executor-unit.sh <id> claude:<model> docs/briefs/<id>.md` | `docs/briefs/<id>-<slug>.md` | `.claude/worktrees/exec-<id>`, unit `rapier-exec-<id>`, log `~/orchestrator/logs/rapier-cairo/<id>.log` |
| game | `/home/claude/projects/pm/scripts/agent.sh game-<Short> <model> bootstrap` with `PM_WORKDIR`, `PM_MEMMAX`, `PM_SECRETS=1` when the brief lists a transaction | `docs/briefs/<id>.md` on `main` before the launch | `.claude/worktrees/exec-<Short>`, unit `pm-game-<Short>`, log `pm/logs/` |

Common contract: a committed brief, a fresh worktree on a branch cut from `origin/main`, `REPORT.md` at the worktree
root, a pull request opened by the agent with CI green, never merged by the agent; an interrupted agent is resumed
(`resume` modes of the launchers), never relaunched. Headless agents end their turn when it ends on a background
command: every brief says "foreground only". Executors may read but not copy files outside their checkout: a brief
that needs a file from the notebook stages it in the repository first.

## 5. Domain rules

- **Rust API parity unless it costs Cairo steps** (owner, 2026-09-25): port the upstream API faithfully; measure steps
  (not gas) when a faithful form may cost more; document every divergence in the repository's ADR. Parity is
  measured by a generated `docs/API_PARITY.md` checked in CI; a new closed exclusion reason needs the project manager.
- **Determinism**: explicit iteration orders, no dict-order dependence; bit-identity proved by goldens and probes.
- **Steps are the budget**: every lot reports the Cairo steps of its hot path; the game's shot budget is
  `slingfall/docs/DESIGN.md` D10; class sizes on the SNIP-36 path stay under 73,728 Sierra and CASM felts (Starknet's
  limit is 81,920), with the margins printed in CI.
- **Package size rule** (owner, 2026-09-28): a published crate has at most 40,000 library lines and adds at most 5 s /
  1 GB (marginal) to an empty consumer; a declared closure costs at most 15 s / 3 GB (20 s / 4.5 GB when it includes
  nalgebra's dimension 5 or 6); facades keep the Rust paths; a number in a crate name means exactly one dimension,
  shared code goes to `<family>_core`; measured by the shared `scripts/consumer_cost.py`, enforcing in every CI, with
  `docs/PACKAGES.md` generated by `scripts/packages_table.py`.
- **Tests live with their module** (owner, 2026-09-30, for every Cairo library of every project; from the next lot of
  each repository): the unit tests of a module (its functions, packing, checks, oracles) sit in that module's file
  under `#[cfg(test)] mod tests`, so that whoever changes the implementation sees its tests; not in separate files,
  unless a measured performance reason is written above the test. What needs a deployed contract or several packages
  stays in `tests/`: integration, gas benchmarks of an entrypoint, parity tables. Existing files move their tests when
  a lot touches them, never by a migration of their own. `#[cfg(test)]` lines do **not** count as library lines for
  the package size rule (they are not compiled into the library; `scripts/consumer_cost.py` already excludes
  test-only files and blocks). Measured on rapier (PK1): inline tests cost a consumer at most 0.04 GB, which is no
  performance reason to keep them apart.
- **Dependencies** by registry version only; pre-releases pinned exactly; a bump is its own pull request; a package
  re-exporting a dependency's type bumps its own MINOR when that dependency moves a pre-1.0 MINOR.
- **Secrets**: only in `~/.config/slingfall/secrets.env` on the VPS, loaded only into units launched with
  `PM_SECRETS=1`; a brief lists every transaction an agent may send, and the agent sends no other; the registry token
  stays in the owner's settings.

## 6. What gates a merge, and the few kinds of task that need an audit

When an audit is run, and how, is the standard's (skill `nexus-agents`, "Start an auditor"): the exception, not the
routine. Specific to this project: parity and gas / step tables are measurements of the task itself, made by the
executor, never audits; the kinds of task below name the one lens they need.


Every pull request: CI green (per repository: fmt, lint, build, crate test groups, gas / steps snapshots, goldens,
API parity, bytecode sizes, consumer cost), the orchestrator's review of `REPORT.md` (scope = allowlist, deviations,
gas or step table), then the Codex review of the standard. Squash merge; conventional commits.

| Kind of task | Required beyond CI and the Codex review |
|---|---|
| Numeric kernel or port (new results) | goldens from the upstream oracle; gas / step snapshot of the module; a `validation` audit when the lot changes results others depend on |
| Engine step path (rapier) or game rules / replay | exact-steps before / after tables on the step and game-shaped probes; bit-identity on the reference shots; a `validation` audit for a numeric change |
| Declared classes (SNIP-36 path) | class sizes under the gates with margins; SNIP-36 syscall / builtin check; bit-identity of the split layout against the in-process run |
| Contract | negative tests for every attack of the research it implements; gas table; class size; `security` audit before any deployment |
| Client / services | `npm run lint`, `npm test`, `npm run build`; devnet e2e in CI |
| Release | main CI green at the release commit, CHANGELOG, version policy, dependency order, package dry run, the project manager's written go (the owner's delegation of 2026-09-25) |
| Documents, briefs, plan, status | none: merge with `Codex review: none — documents only` |

## 7. Releases and deployments

- Registry releases (scarbs.xyz): the project manager gives the go in writing on the owner's behalf (delegation of
  2026-09-25) under the conditions above; the orchestrator publishes in dependency order, verifying each package
  against the registry, and tags.
- Starknet Sepolia: a deployment or an admin transaction happens only inside a brief that names it, with the
  transactions listed one by one; mainnet is reserved to the owner.
- The hosted client (GitHub Pages) is redeployed by a manual dispatch of the CI workflow after a merge that changes
  what it serves, and only when it matches the contract it talks to.
