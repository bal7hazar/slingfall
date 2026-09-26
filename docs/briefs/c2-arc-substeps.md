# C2 — exact flight arc in the client: model rapier's substepped free flight

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D3, D5, D8; S1's escalation 1 in `docs/briefs/s1-substeps.md` (rapier integrates the
pebble's free flight as `substeps` semi-implicit Euler steps of `dt // substeps`, gravity included in each step:
`v_y += mul(g, h); x += mul(v_x, h); y += mul(v_y, h)`; the model is bit-exact against the trace in
`tools/golden/matrix.py::arc_points`); on `main`: `client/src/aim/{arc,fixed}.ts` and `arc.test.ts`,
`crates/slingfall_rules/src/world.cairo` (`SOLVER_ITERATIONS = 4`, `TICK_DT_RAW`), `fixtures/traces/pile10-reference.json`
(the pebble's frames during flight: the golden for the arc).

## 2. Scope (allowlist)
`client/src/aim/**`, `client/src/**` only where the arc is drawn / configured, `client/README.md`, `docs/levels.md` (a line).

## 3. Work
1. `arc.ts`: replace the one-step-per-tick Euler by the substepped model (`SUBSTEPS = 4`, `h = dt // 4` in raw Q32.32
   with the same floor rounding as `fixed` products; document that `h` is the integer division of the raw dt),
   exported constants so a future setting change is one edit.
2. Golden test: the first 60 flight frames of `fixtures/traces/pile10-reference.json` (pebble body) must equal the arc
   positions bit for bit (raw felts), and the same for the 20-position table recomputed with `matrix.py::arc_points`
   (copy its Python into the test's expected values, don't call Python from Vitest).
3. Dots until first contact only: since the arc is exact, stop the preview at the first tick whose position enters
   a body's AABB (approximate contact; document that it is a display cut, not physics).

## 4. Budget
None (client only).

## 5. Tests
`npm run lint`, `npm test` (the new goldens), `npm run build`.

## 6. Definition of done
`AGENTS.md` §6 client part; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`;
push `feat/c2-arc-substeps`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`.

## 7. Work autonomously, do not ask questions, do not widen the scope.
