# Operating document of the project `slingfall`

What is specific to this project, added to the standard of the organisation (the rules the project's sessions
receive). It never restates the standard; where it would contradict it, the standard wins. The project manager owns
this file.

## 1. Scope and repositories

The game Slingfall (working name) and the Cairo libraries it is built on. Everything runs on the Q32.32 fixed-point
scalar `fixed::Fixed`; numeric results are API (a last-bit change is a MINOR bump and a CHANGELOG entry).

Since 2026-10-02 the programme runs in herdr. The project manager is the coordinator of the herdr project `slingfall`;
each track has an orchestrator that is a herdr project of its own.

| Track | Repositories | Orchestrator (herdr project) | Its documents |
|---|---|---|---|
| glam | fixed-cairo, glam-cairo, glamx-cairo | `slingfall-glam` | glam-cairo `docs/PLAN.md`, `HANDOFF.md` |
| nalgebra | simba-cairo, nalgebra-cairo | `slingfall-nalgebra` | nalgebra-cairo `docs/PLAN.md`, `docs/SPLIT.md` |
| rapier | rapier-cairo | `slingfall-rapier` | rapier-cairo `docs/PLAN.md`, `AGENTS.md`, `docs/ORCHESTRATOR.md` |
| game | slingfall | `slingfall-game` | `docs/PLAN.md`, `docs/DESIGN.md`, `docs/ORCHESTRATOR.md`, `AGENTS.md` |

The game is not run by the project manager: the standard forbids the project manager to have a track's pull request
merged.

The programme's plan, decisions, research and status live in the project manager's notebook
(`/home/claude/projects/pm` on the VPS: `PLAN.md`, `STATUS.md`, `RESUME.md`, `decisions/`, `research/`, `reports/`).

### Sessions

A new session (an orchestrator, a successor) is created with the standard's `session.py`
(`session.py "<name>" orchestrator --goal "<goal>" --repo <path>... --start-file <file>`), then told in one line to
read its starting file: a committed file of the notebook (`pm/messages/orchestrators/<track>-<date>.md`) holding its
handover note, the transition document and the owner's context.

## 2. Models by kind of session and of task

Sessions: the project manager and every orchestrator run on Opus. Implementation, review and audit run in threads,
whose profile sets the model; Codex is not used.

| Kind of task | Thread profile | Notes |
|---|---|---|
| Mechanical, well-framed lot (fixtures, converters, bumps with no numeric change, doc tables, copying a script) | `impl-sonnet` | the tighter the brief, the smaller the model |
| Standard port or feature with numerics (kernels, tests, golden vectors, benches; game rules, replay, contract, worker) | `impl-opus` | default for anything that touches results |
| Genuinely hard problem, after `impl-opus` failed twice, or on the owner's request | `impl-fable` | say why in the brief |
| Review of every pull request | `review` (Sonnet) when Opus or Fable wrote it; `review-opus` when Sonnet wrote it | another model than the writer, fresh context, read-only; the routine gate |
| Audit (the few kinds of §6) | `audit` (Opus) | read-only, never implementation; the exception, not the routine |

The in-session Agent tool is used only for short read-only research.

## 3. The machines and the budgets

- Before placing a thread, read `machine-capacity` (VPS and Mac slots, memory, pool quota). Under 20 % of the pool's
  quota: fewer threads, and warn with the figure.
- The Mac (12 cores, 64 GB) takes the heavy suites: a nalgebra build peaks at 11 GB, rapier's whole-shot tests near
  20 GB.
- The VPS (Hostinger, 8 vCPU / 31 GB, shared with the owner's other programmes) runs one heavy suite at a time:
  `scarb` / `snforge` go through the shims that serialise heavy subcommands behind `~/orchestrator/heavy-build.lock`
  (rapier: a per-project lock for crate-scoped builds plus the shared heavy lock). `scarb prove` (Stwo) needs more
  than 22 GB: never on the VPS.
- `~/orchestrator/capacity.json` and the `pm-capacity` timer belong to the old setup, kept only while Nexus is the
  rollback; they are no longer the launch rule.
- Local checks are crate-scoped (`-p <crate>`); the pull-request CI is the full gate. Never `snforge test --workspace`
  on the shared machine. Every repository keeps its CI under about 10 minutes and splits test crates before they grow.
- `~/orchestrator/slots/` belongs to another project's launcher: never touched.
- The SNIP-36 prover (about 96 GB) is rented on demand elsewhere, on the owner's decision, never run here.

## 4. Threads

Implementers, reviewers and auditors are herdr threads started by the track's orchestrator (`hp thread start`): a
worktree on a branch cut from `origin/main`, the task naming the committed brief.

| Track | Brief |
|---|---|
| glam | glam-cairo `docs/briefs/<ID>-<slug>.md` (+ `COMMON.md`) |
| nalgebra | nalgebra-cairo `docs/briefs/wp-<n>.md` |
| rapier | rapier-cairo `docs/briefs/<id>-<slug>.md` |
| game | slingfall `docs/briefs/<id>.md` on `main` before the thread starts; it lists every transaction the thread may send |

Common contract: a committed brief, `REPORT.md` at the worktree root, a pull request opened by the thread with CI
green, foreground only (a thread that ends its turn on a background command stops). Threads may read but not copy
files outside their checkout: a brief that needs a file from the notebook stages it in the repository first.

Merge: after a review by another model that does not oppose it and green checks, either the owning thread merges on
the orchestrator's line `Merge the PR: review <verdict> at <sha>`, or the coordinator that started the review thread
merges with the standard's command. Never `--admin`.

The old launchers (`scripts/agent.sh`, `scripts/executor-unit.sh`, `pm/scripts/agent.sh`) belong to the old setup:
nothing is started through them.

## 5. Domain rules

- **Rust API parity unless it costs Cairo steps** (owner, 2026-09-25): port the upstream API faithfully; measure steps
  (not gas) when a faithful form may cost more; document every divergence in the repository's ADR. Parity is
  measured by a generated `docs/API_PARITY.md` checked in CI; a new closed exclusion reason needs the project manager.
- **Determinism**: explicit iteration orders, no dict-order dependence; bit-identity proved by goldens and probes.
  One compiler thread (`RAYON_NUM_THREADS=1`) makes a build reproducible per machine, not across machines: Grim World
  measured a different Sierra text and class hash for the same class on the Mac and on the VPS, single-threaded, with
  the same CASM (2026-10-02, cause under investigation). Until the cause is known, every committed file that pins a
  hash, class bytes, a class size or a declared-class margin is generated and checked on Linux only (the VPS or CI),
  never from a Mac build. The machine of every pinned or measured hash is stated where it is recorded.
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
- **Secrets**: only in `~/.config/slingfall/secrets.env` on the VPS, loaded only into threads whose brief
  lists a transaction; a brief lists every transaction a thread may send, and the thread sends no other; the registry token
  stays in the owner's settings.

## 6. What gates a merge, and the few kinds of task that need an audit

Specific to this project: parity and gas / step tables are measurements of the task itself, made by the
implementing thread, never audits; the kinds of task below name the one lens they need. An audit is the exception: a
line of a brief that names an audit for its task does not bind; the orchestrator decides when it closes the task. The
project manager counts audits asked against pull requests merged at each check-in.

Every pull request: CI green (per repository: fmt, lint, build, crate test groups, gas / steps snapshots, goldens,
API parity, bytecode sizes, consumer cost), the orchestrator's review of `REPORT.md` (scope = allowlist, deviations,
gas or step table), then a review thread (§2). Squash merge; conventional commits.

| Kind of task | Required beyond CI and the review thread |
|---|---|
| Numeric kernel or port (new results) | goldens from the upstream oracle; gas / step snapshot of the module; a `validation` audit when the lot changes results others depend on |
| Engine step path (rapier) or game rules / replay | exact-steps before / after tables on the step and game-shaped probes; bit-identity on the reference shots; a `validation` audit for a numeric change |
| Declared classes (SNIP-36 path) | class sizes under the gates with margins; SNIP-36 syscall / builtin check; bit-identity of the split layout against the in-process run |
| Contract | negative tests for every attack of the research it implements; gas table; class size; `security` audit before any deployment |
| Client / services | `npm run lint`, `npm test`, `npm run build`; devnet e2e in CI |
| Release | main CI green at the release commit, CHANGELOG, version policy, dependency order, package dry run, the project manager's written go (the owner's delegation of 2026-09-25) |
| Documents, briefs, plan, status of a track | a short review on another model, like any pull request (the Overseer's ruling of 2026-10-02: a merge with no review is outside the owner's merge rule) |
| The programme's own documents, written on the project manager's instruction (this file, the programme plan) | none: the standard's no-review path, with the line `Review: none — documents` |

## 7. Releases and deployments

- Registry releases (scarbs.xyz): the project manager gives the go in writing on the owner's behalf (delegation of
  2026-09-25) under the conditions above; the orchestrator publishes in dependency order, verifying each package
  against the registry, and tags.
- Starknet Sepolia: a deployment or an admin transaction happens only inside a brief that names it, with the
  transactions listed one by one; mainnet is reserved to the owner.
- The hosted client (GitHub Pages) is redeployed by a manual dispatch of the CI workflow after a merge that changes
  what it serves, and only when it matches the contract it talks to.
