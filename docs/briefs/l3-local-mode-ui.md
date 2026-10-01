# L3 — three client defects of the local mode, found by lot L2 on the Mac

## 1. Read first
`AGENTS.md`; `OPERATIONS.md`; `docs/qa/2026-09-30-mac-play.md` (lot L2: screenshots under `docs/qa/img/l2/`);
`docs/play-local.md`; `client/src/chain/{config,panel}.ts`, `client/src/main.ts`, `client/src/game/play.ts`,
`client/src/render/hud.ts`, `client/index.html`, `client/src/style.css`.

## 2. Defects (L2's escalations)
1. `#banner` is empty in local mode: the "local devnet: proofs are simulated" banner the design asks for does not
   render (the chain strip and the panel title carry the text, the banner element does not).
2. After a proof is recorded (proven or settled), the "Prove (SNIP-36, simulated)" and "Settle (Atlantic, simulated)"
   buttons stay enabled: a second click on the same tier is refused by the contract (`'submit: nullifier'`); the
   buttons must reflect the attempt's state (hide or disable the tier already recorded; keep the other).
3. The end-of-level panel covers half the board on a 1280x800 desktop viewport (screenshot 03/07 of L2): it must
   leave the scene visible (fold by default on desktop too, or a side placement; measure with the L2 driver).

## 3. Scope (allowlist)
`client/src/**` (not `client/src/vm/**`, not `client/src/aim/{arc,contact,fixed}.ts`), `client/index.html`,
`client/src/style.css`, `scripts/play/qa-browser.mjs` (reuse it for the evidence; headless Chromium on this Linux
machine is fine), `docs/play-local.md`. No change to what is sent to the VM for a given pull; no service change.

## 4. Definition of done
`cd client && npm run lint && npm test && npm run build`; screenshots before / after for the three defects with the L2
driver (committed under `docs/qa/img/l3/`); conventional commits with the trailer of the model you are; push
`feat/l3-local-mode-ui`; `gh pr create`; `gh pr checks --watch` in the foreground until green; never merge;
`REPORT.md`. Foreground only: never end your turn on a background command or a watcher. Work autonomously, do not
ask questions, do not widen the scope.
