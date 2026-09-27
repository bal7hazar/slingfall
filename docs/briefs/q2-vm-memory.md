# Q2 — client VM: keep the worker's wasm under 400 MB on every shot (QA M4)

## 1. Read first
`AGENTS.md`; `docs/qa/2026-09-26-mac.md` section M4 and suggestion S2 (chunk table); `docs/DESIGN.md` D11, D12 (chunk
sizing: K <= 20, 1.25x reserve, 5M-cell floor); `client/vm/README.md`; `client/src/vm/{sizing,shot,worker,protocol}.ts`;
`client/src/aim/{arc,contact}.ts` (read only: the exact predicted contact tick); `client/vm/runner/`.

## 2. Scope (allowlist)
`client/src/vm/**`, `client/vm/runner/**`, `client/vm/README.md`, `docs/qa/harness/memory.mjs`. The worker may import
`client/src/aim/**` read-only to compute the contact tick from the level and the pull it already receives; do not
edit `client/src/main.ts`, `game/**`, `render/**` (lot Q1) nor `chain/**` (lot Q3).

## 3. Work
1. Reproduce: pile10 owner's shot (-1022, -63), pile10 reference, tower, twin: per-chunk ticks, steps, execution
   cells, reserve, wasm size (Node runner is enough; one browser confirmation with the harness if available).
2. Implement and measure both candidates, keep the winner, document the loser:
   (a) cut the flight chunk at the predicted contact tick so that the impact opens a fresh chunk, with a small K for
   the first impact chunks; (b) raise the reserve floor. Also evaluate (c) freeing / recreating the wasm instance
   between shots if memory never shrinks.
3. Targets: peak wasm <= 400 MB on the six levels' reference shots, the owner's shot and the cap shot (-1019, -72);
   no segment doubling; total shot time not worse than +5 %; outputs bit-identical (chunk boundaries do not change
   results: prove it on the goldens through the chunked path).
4. Update the documented figures in `client/vm/README.md` (say which rapier2d version they were measured on).

## 4. Definition of done
`AGENTS.md` §6 (client: `npm run lint`, `npm test`, `npm run build` in `client/`); conventional commits with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push the branch; `gh pr create`; `gh pr checks --watch` until green (foreground); never merge; `REPORT.md` (Summary, per-defect status with the evidence, measurements, deviations, escalations, PR URL). Work autonomously, do not ask questions, do not widen the scope. At most 2 parallel jobs. Another lot (B4) is regenerating fixtures and goldens: do not touch `client/vm/fixtures/**`, `client/public/levels/**`, `fixtures/**`, `steps/**`, `deploy/sepolia.json`. Branch `feat/q2-vm-memory`.
