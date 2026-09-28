# H2 — `slingfall_split` in the root workspace, layout (e) as the game's layout, class-size gate in CI

## 1. Read first
`AGENTS.md`; `docs/research/07-split-game-step.md` (lot S36a) and its report's escalation 2; `crates/slingfall_split/**`;
`tools/classsize/**`; `.github/workflows/ci.yml`.

## 2. Decision to implement (programme session, 2026-09-28)
Layout (e) is the game's layout (world class keeps the world for the chunk, one rules call per tick, edits across a
crossing). Gates: every declared class at most 73,728 Sierra and CASM felts, **except the game's world class, at most
78,000** (Starknet's limit is 81,920; rapier is asked to shrink its slim caller so that the world class comes back
under 73,728 later). Layout (b) stays in the crate as the fallback that passes 73,728 everywhere.

## 3. Scope (allowlist)
`crates/slingfall_split/**` (delete `shims/`, its `[workspace]` section and `Scarb.lock`; pins through
`.workspace = true`), root `Scarb.toml` (members, `rapier2d_classes = "=0.1.0-alpha.7"`), root `Scarb.lock`,
`tools/classsize/**` (`classsize.py split`: the two gates, prints the margin of every class), `.github/workflows/ci.yml`
(the crate in the test matrix; the class-size gate in the build job), `steps/slingfall_split/**` (snapshots of the
default suite), `docs/research/07-split-game-step.md` (a "Status after H2" paragraph). No behaviour change, no
deployment, no credentials.

## 4. Work
1. Move the crate into the workspace (the root is on alpha.7 since lot B5); the default suite and the `#[ignore]`
   probes still pass and give the same figures (report any difference).
2. Name the layouts for what they are in the public items of the crate (`WorldClass` = layout (e), `FallbackGame` +
   `StepClass` = layout (b)); remove layouts (a), (c), (d), (f) from the default build, keep them behind `#[cfg(test)]`
   or a feature only if the probes need them.
3. CI: tests of the crate in the matrix (time budget: under 10 minutes; heavy probes stay `#[ignore]`), class-size
   gate with margins printed in the job summary.
4. Pin the class hashes in one module (`ClassHashes` constants) with a test that fails when a class changes without
   the constants being regenerated, and a script that regenerates them.

## 5. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/h2-split-in-workspace`; `gh pr create`; `gh pr checks --watch` in the foreground until green; never merge;
`REPORT.md`. Foreground only. Heavy runs one at a time under the heavy-run lock (`crates/slingfall_split/scripts/heavy.py`).
Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs.
