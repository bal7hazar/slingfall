## Summary

<!-- Lot id from docs/PLAN.md and what ships -->

## API

<!-- Public items with their exact names (docs/DESIGN.md), felt layouts, panic messages -->

## Step table

<!-- Cairo steps of the hot path, net of `steps_baseline`: output of `python3 scripts/steps.py diff`,
     plus the replay's steps per shot / per level when the lot touches it. Winners and losers. -->

## Deviations

<!-- From the brief and from docs/DESIGN.md, with the reason -->

## Deferred

<!-- What the brief left for later (DEFER), and what this PR did not reach -->

## Escalations

<!-- Needs outside the file allowlist: shared files, missing `rapier2d` accessors, design questions -->

---

- [ ] `scarb fmt --workspace`, `scarb lint -p <crate> --deny-warnings`, `snforge test -p <crate>` (crate-scoped, AGENTS.md §6)
- [ ] `steps_*` probes for the hot path (inputs through `slingfall_testing::opaque`), snapshots regenerated
- [ ] Golden `(level, inputs) -> outputs` fixtures and determinism checks where the lot touches the replay
- [ ] `cd client && npm ci && npm run lint && npm test` (client lots)
