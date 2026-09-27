# Q1 — client: playback-gated result and sling, aiming and camera, small UI defects (QA M2, M3, M5, m1-m4)

## 1. Read first
`AGENTS.md`; `docs/qa/2026-09-26-mac.md` sections M2, M3, M5, m1, m2, m3, m4 and suggestions S1, S3, S5, S6 (with the
images); `docs/DESIGN.md` D5, D12; `client/README.md`; `client/src/game/{stage,session}.ts`,
`client/src/render/{playback,hud,camera,scene,live}.ts`, `client/src/aim/{controller,pull}.ts`, `client/src/main.ts`.

## 2. Scope (allowlist)
`client/src/game/**`, `client/src/render/**`, `client/src/aim/controller.ts`, `client/src/aim/pull.ts` and their tests,
`client/src/main.ts`, `client/src/style.css`, `client/index.html`, `client/README.md`, `docs/qa/harness/**` (reuse for
evidence). Forbidden: `client/src/aim/arc.ts`, `contact.ts`, `fixed.ts` (exact arithmetic, frozen), `client/src/vm/**`
(lot Q2), `client/src/chain/**` (lot Q3), anything that changes what is sent to the VM for a given pull.

## 3. Work
1. **M2 / M3**: the result panel and `stage.armed` wait for the playback to reach the last frame of the shot and the
   producer to be done; a released shot counts as spent at once (m2); Play / Pause label from the real state (m3);
   the spent pebble leaves the scene at the end of its shot (m4). Tests with a fake clock: VM faster than real time,
   VM slower than real time, paused playback, Retry during playback.
2. **M5**: camera framed on the sling and the structures (margin, not the level bounds; keep the whole flight
   reachable: zoom out or follow during the shot, your choice, measured); the sling drawn at rest (posts, band,
   resting pebble); drag scaled to the screen (full pull = 25-30 % of the short side, independent of the zoom);
   fine aiming: arrow keys nudge one pull unit (Shift: 10), and the current pull is displayed as integers; a grab area
   of at least 44 px on touch screens. Every integer pull in the disc must be reachable: prove (-1022, -63) on pile10
   by keyboard in a test.
3. **m1**: narrow screens: short hint, chain strip stacked under the HUD, collapsible result panel (390x844 and
   844x390 checked with the harness; screenshots in the PR).
4. Determinism guard: the pull sent to the VM is the integer pair displayed; existing replay / golden tests of the
   client unchanged.

## 4. Definition of done
`AGENTS.md` §6 (client: `npm run lint`, `npm test`, `npm run build` in `client/`); conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push the branch; `gh pr create`; `gh pr checks --watch` until green (foreground); never merge; `REPORT.md` (Summary, per-defect status with the evidence, measurements, deviations, escalations, PR URL). Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs. Another lot (B4) is regenerating fixtures and goldens: do not touch `client/vm/fixtures/**`, `client/public/levels/**`, `fixtures/**`, `steps/**`, `deploy/sepolia.json`. Branch `feat/q1-client-play`.
