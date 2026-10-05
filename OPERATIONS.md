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
- **Memory cap** (organisation rule, 2026-10-03): a test file is kept small enough that its build stays well under 8 GB. On the VPS, Cairo builds, tests and measures (scarb, snforge, replays) run under `prlimit --as=8589934592` (an address-space cap: it kills a build well below its real memory, so it is used only for work known to fit well under it); Node suites and whole hooks run uncapped when every step was measured well under 8 GB (`prlimit --as` kills Node at start-up). A real peak is measured uncapped only on the Mac (64 GB, no lock), never uncapped on the VPS. Heavy suites (nalgebra workspace ~11 GB, rapier whole-shot ~20 GB) run on the Mac. Pre-push hooks on the VPS compile Cairo under that cap inside the heavy flock and, if the cap kills the compile, print "memory cap reached: Cairo compile left to CI" and pass, like the lock-busy case.
- **Long pushes**: a push whose pre-push hook may run long uses `git -c core.sshCommand='ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=40' push …` (no config written).
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
  One compiler thread (`RAYON_NUM_THREADS=1`) stays the rule for every hashed, sized or measured build.
- **Build root** (closed 2026-10-02 for Slingfall and Grim World, grimworld #283): the compiler names closure types
  `{closure@<absolute path>/…cairo:L:C}` and the Sierra type id is the keccak of that name, so every artefact holding a
  closure type changes with the absolute build root: file bytes, Sierra text sha256, class hash. Sierra felt counts,
  CASM felts, CASM sha256 and L2 gas do not. The platform is not a cause: a Mac build and a VPS build agree once their
  roots are normalised.
  - The reference build root is CI's checkout path. A class hash is pinned only from CI's output, with CI's root path
    recorded beside it, so that a change of runner path shows as a cause, not a regression.
  - A class declared on a network uses CI's class artefact, never a local build.
  - Local builds, on any machine and at any path, check felt counts, CASM and gas only. Gas pins, felt sizes and
    CASM-side program hashes (such as the game's `c1main` hash) do not depend on the path.
  - A local class-hash difference against CI is expected, not a regression.
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
| Release | main CI green at the release commit, CHANGELOG, version policy, dependency order, package dry run, the project manager's publication go (§7) |
| Documents, briefs, plan, status (nothing that runs changed) | none required: merge with the line `Review: none — <reason>`, per the standard's orchestrator text "Merging without a review"; a review when the orchestrator judges it useful. Never for value, access, secrets, a published interface or a result others depend on: a release record holding a checksum or a pin, and a publication request, are reviewed |
| The programme's own documents, written on the project manager's instruction (this file, the programme plan) | none: the standard's no-review path, with the line `Review: none — documents` |

A lot that must show no step change may show it by CI: every affected test's gas snapshot unchanged and `gas/bytecode.size` unchanged (2026-10-03).

slingfall's `all-checks` gates 11 jobs, each path-gated: a job runs only when its inputs changed; pushes to main run everything (2026-10-03).

## 7. Releases and deployments

- Registry releases (scarbs.xyz): the project manager gives the go in writing on the owner's behalf (delegation of
  2026-09-25) under the conditions above; the orchestrator publishes in dependency order, verifying each package
  against the registry, and tags.
- **Release commit off main** (2026-10-03, project manager, with the Overseer's reading of the standard): when a
  package's manifest cannot be published as it stands, because it lists unpublished `[dev-dependencies]` (test helpers
  kept off the registry by the package-size rule), the release commit goes on a branch `release/<version>` cut from a
  commit of `main`. Its whole diff is the removal of the `[dev-dependencies]` of the published crates. It is reviewed
  by another model like any PR, and its CI is green. The publication go names that commit; the archives are built from
  a clean checkout detached at it; the tag goes on it; the branch is kept and never merged. `main` keeps its
  dev-dependencies. The release record on `main` names the release commit and says why it is off main. Reversed when
  the helpers are published, or when scarb accepts unpublished dev-dependencies.
- **Its CI**: a release commit lands on its branch by fast-forward (never a squash merge). Its "CI green" reads: every job that does not need the removed dev-dependencies is green on the release commit; the jobs that need them are green on its parent on main; and `scarb publish` verifies each crate. When a dependent crate cannot verify before its dependency is published, the goes are staged in dependency order (rapier 0.1.0-alpha.9, 2026-10-03).
- **Request archives** may be built with `scarb package --no-verify -p` (packaging is not publication; the hash is identical, measured); the project manager spot-checks a package with no unpublished dependency built with verification. Publication itself is always plain `scarb publish -p`.
- **Heavy publications** (standing rule, the Overseer, 2026-10-04, for both programmes): a package whose `scarb publish` verification compile exceeds the 8 GiB cap is published by the track's orchestrator on the VPS, inside the heavy flock, `RAYON_NUM_THREADS=1`, `prlimit --as=25769803776 -- /usr/bin/time -v scarb publish -p <pkg>`, started only when `machine-capacity` shows at least 18 GB free on the VPS (lowered from 20 GB by the Overseer on 2026-10-05: twice the measured peak, the figure the VPS holds), its peak recorded in the release record. Bounds: a package whose last recorded peak exceeded 16 GiB RSS, or whose verification failed once under this rule, goes to the owner on the Mac instead; the rule covers `scarb publish -p` only (a build or a test above 8 GiB still runs on the Mac or capped). Measured basis: nalgebra 0.2.0's facade `nalgebra` peaked at 9,154,636 kB RSS (2:28), `nalgebra_glam` at 1,912,516 kB (0:23), on 2026-10-03. Reversed by the owner, or by a resident-memory cap (nexus #96) that makes the address-space cap unnecessary. The 18 GB threshold reverts to 20 GB (and the package to the owner on the Mac) if a run under it ever fails on memory.
- **Flags**: `scarb publish` never runs with `--allow-dirty`, `--no-verify` or `--index` (the standard's rule). If
  verification fails without `--no-verify`, the exact error goes to the Overseer as a platform request; nothing is
  published meanwhile.
- **The project manager's checklist** before a go, run by the project manager in a clean clone: the commit is on
  `main` (or is a release commit as above, whose diff the project manager reads), with green checks; its review left
  no blocker and no major; the archive built from a checkout detached exactly at that commit (the archive embeds the
  checkout's HEAD) has the sha256 of the request. Several packages of one release may share one request and one go
  message naming every row (package, version, commit, sha256).
- Starknet Sepolia: a deployment or an admin transaction happens only inside a brief that names it, with the
  transactions listed one by one; mainnet is reserved to the owner.
- The hosted client (GitHub Pages) is redeployed by a manual dispatch of the CI workflow after a merge that changes
  what it serves, and only when it matches the contract it talks to.
- Relayer (owner, 2026-10-02): on Starknet Sepolia the relayer is the admin account, with no dedicated account ("on
  Sepolia there is no real risk"). The question reopens before mainnet, where fees and admin rights are real. This
  authorises no new act: the admin key, its placement on a machine and every deployment remain the owner's.
- Hosting (owner, 2026-10-02): the attestation service (provisional tier) is hosted on the project's VPS, bound to
  127.0.0.1; the web clients get subdomains later, created by the owner. No Atlantic for the MVP: its settled tier is
  proof verification in the protocol (SNIP-36), tested when the Starknet upgrade is live on Sepolia; the Atlantic path
  already on Sepolia is a test result, not the MVP's path. SNIP-36 proving needs a machine larger than the VPS, rented
  by the owner. The subdomain, the Caddy site, the services' system user and the secrets are the owner's; no agent can
  read the secrets.
