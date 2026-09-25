# G6 — `client/`: PixiJS renderer of a recorded trace, aim UI with the exact flight arc

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D3, D8, D12; `docs/research/02-game-design-and-client.md` §4 (recommendation,
interaction loop); on `main`: `client/` (Vite + TS + PixiJS 8 + ESLint + Vitest skeleton, `src/trace/{types,source}.ts`,
`README.md`), `docs/research/03-spike-wasm-vm.md` §"Program under test" (the `println!` tick format
`tick <i> y <raw>` of the spike; the real observer format comes with G4: keep the parser behind an interface).

## 2. Scope (allowlist)
`client/src/**`, `client/public/**`, `client/index.html`, `client/README.md`, `client/package.json` +
`package-lock.json` ONLY to add runtime/dev dependencies (no version bumps of existing ones; list them in
the report), `fixtures/traces/**` (new). Nothing under `crates/`, `scripts/`, `.github/`.

## 3. Expected content
- `src/trace/types.ts` evolves into the recorded trace format v1: `{version: 1, level: {bounds, sling_anchor,
  bodies: [{handle, kind, shape, material}]}, frames: [{tick, bodies: [{handle, x, y, re, im, asleep}]}],
  events: [{tick, kind: "damage"|"destroyed"|"score"|"shot_end", ...}]}`, raw Q32.32 as decimal strings.
  A `TraceSource` (existing interface) yields frames incrementally (async iterator) so the worker source of
  G1c plugs in later without touching the renderer.
- `src/render/`: PixiJS 8 scene: ground half-space, cuboids, balls, convex polygons, cores, the pebble;
  placeholder flat-colour sprites per material (D12 names); camera fit to `level.bounds`; interpolation
  between frames for display only; asleep bodies dimmed; a HUD (score, shots left, tick).
- `src/aim/`: drag from the sling anchor -> integer pull `(px, py)` in `[-1024, 1024]²` clamped to the disk
  (same integer math as D3, in `BigInt`), shown as a dotted **exact** arc: semi-implicit Euler at 60 Hz
  under `gravity_y` with Q32.32 floor rounding, in `BigInt`, `n` dots until `bounds` or 120 ticks
  (a golden test compares the first 20 positions with values you compute by hand from the formula
  `v += g·dt; p += v·dt` with the rounding of `fixed` products: floor of the exact product, one rescale;
  document the formula so G4 can assert it against rapier's `integrate`).
- `src/main.ts`: load a fixture trace (`fixtures/traces/pile10.json`, hand-made or generated from the
  format: at least 120 frames with a falling pebble and 3 asleep-then-awake blocks), play / pause /
  scrub, aim UI (the release logs the pull; no simulation yet).
- Tests (Vitest): trace parsing, pull clamping table, arc golden, `fixedToNumber` edge values.

DEFER: live simulation (G6b), wallet, sounds, real assets.

## 4. Budget
60 fps on a 2020 laptop for 60 bodies (PixiJS sprites, no per-frame allocations); bundle ≤ 1 MB gz.

## 5. Tests
`npm run lint`, `npm test` (≥ 12 tests), `npm run build`. Screenshot of the page in `client/README.md` is
optional (no browser may be available; `vite preview` + description is enough).

## 6. Definition of done
`AGENTS.md` §6 client part (foreground, `nice -n 10 npm ci`); conventional commits with the trailer
`Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push `feat/g6-client-renderer`; `gh pr create`;
`gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Layout · Trace format v1 ·
Deviations · Deferred · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
