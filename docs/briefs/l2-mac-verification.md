# L2 — verify "play locally" on the Mac, in a real browser (lot L1's unverified items)

## 1. Read first
`AGENTS.md`; `OPERATIONS.md`; `docs/play-local.md`; `docs/PLAN.md` row L1 and `docs/qa/2026-09-26-mac.md` (the
harness under `docs/qa/harness/`, the owner's earlier QA on this machine); `scripts/play.sh`, `scripts/play/**`.

## 2. Goal
Lot L1 shipped `scripts/play.sh` tested on Linux and in CI only. This lot runs it on macOS (Apple silicon) and drives
the page in a real browser, then reports what works, what fails and the fixes it made. This machine belongs to the
owner: leave it as you found it (see §5).

## 3. Scope (allowlist)
`scripts/play.sh`, `scripts/play/**`, `deploy/devnet.sh` (macOS fixes only), `docs/play-local.md`, `docs/qa/2026-09-30-mac-play.md`
(new, the report with screenshots under `docs/qa/img/`), `client/src/**` only for a defect of the local mode that
blocks the flow (say which). No Sepolia access, no credentials, no `STARKNET_*` variable read (the local mode ignores
them: check that it says so).

## 4. Work
1. `scripts/play.sh doctor`: record its full output; install nothing outside what `docs/play-local.md` names as the
   project's own tools; if a prerequisite is missing (Node version, Python >= 3.10, starknet-devnet release, Rust for
   the wasm runner), report it with the exact message and stop that path.
2. `scripts/play.sh` (first `up`): time it; then `status`; then `down`; then `up` again: time it (target under 30 s).
3. In a real browser (Playwright's Chromium or the installed Chrome, `--require browser`): open the printed URL, take
   screenshots of: the start (banner "local devnet: proofs are simulated", the auto-connected devnet account), a shot
   on pile10 with the pull (-1022, -63) by keyboard (arrow keys, Shift for 10), the provisional record, the proven
   path (button "Prove (SNIP-36, simulated)") and the settled path (button "Settle (Atlantic, simulated)"), both
   boards with the proof kind of each row. Record the timings of each step and the console errors, if any.
4. `PLAY_HOST=0.0.0.0` once: check the page answers on the Mac's LAN address, then `down`.
5. Fix what blocks on macOS inside the allowlist (bash 3.2, sed, ports, firewall prompts); document what needs the
   owner (a firewall dialog, an install).

## 5. Leave the machine as found
`scripts/play.sh down` at the end (no devnet, no service, no dev server left); nothing installed globally; the
worktree is the only thing that stays. Ports 5050 / 8547 / 8549 / 5173 free before and after (report).

## 6. Definition of done
Conventional commits with the trailer of the model you are; push `feat/l2-mac-verification`; `gh pr create`;
`gh pr checks --watch` in the foreground until green; never merge; `REPORT.md` at the worktree root (Summary, per-item
status with timings and screenshots, what could not be verified and why, fixes made, escalations). Foreground only.
Work autonomously, do not ask questions, do not widen the scope.
