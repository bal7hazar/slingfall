# PB — `scripts/play.sh` serves the built client (`PLAY_BUILT=1`)

Profile `impl-sonnet` (a small, clear change with a patch already written). Lot id `pb-play-built`, branch
`feat/pb-play-built`.

## 1. Goal and context

**Goal.** Local play can serve the **built** client (`vite build`, then `vite preview` with compression) instead of
the dev server.

**Why.** The owner's local test on the Mac took about a minute before the scene was playable. The research thread of
2026-10-02 (report: `/home/claude/.herdr-projects/slingfall-game/threads/t-0023.md`, read-only) measured the cause in
headless Chromium with mobile throttling:
- the dev server ships 23.9 MB in 74 requests, the built client 2.6 MB in 19;
- on Slow 4G: 146–156 s against 22–24 s.
The owner's decision (2026-10-02): go. Everything is measured on desktop, and the design stays mobile-first.

**The patch.** It is already written and checked with `git apply --check` on fc00698:
`/home/claude/.herdr-projects/slingfall-game/library/t-0023/harness/play-built.patch` (read-only). Lot L4 (#68) changes
`scripts/play.sh` since then, so the patch is re-applied by hand on current main, keeping its meaning:
- `PLAY_BUILT=1` builds the client into `target/play/dist` at each start of the client. The contract address is baked
  in, so the build is redone each time.
- It then runs `vite preview` with the same proxy (`/rpc`, `/attest-service`, `/prove-service`) and the same
  `--host` / `--port`.
- The default (dev server) is unchanged.

Read first: `scripts/play.sh` (`up`, `start client`, the `VITE_*` variables), `scripts/play/vite.config.mts`,
`docs/play-local.md`, and the research report's Finding 1.

## 2. Transactions

None on any public network; only the local devnet's own deploy transactions through `play.sh up`.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `scripts/play.sh`: the `PLAY_BUILT` mode and its header line.
- `scripts/play/vite.config.mts`: only if `vite preview` needs it, for example the wasm MIME type or compression.
- `docs/play-local.md`: how to use `PLAY_BUILT=1`, and when.
- `REPORT.md`.
- Not `client/**`, not `.github/**`.

## 4. Work

1. Re-apply the patch's change on current main.
2. **The wasm is compressed too, if you can do it within the allowlist.** `vite preview` gzips JS and JSON but sends
   the 1.53 MB `.wasm` uncompressed: its compression MIME regex leaves it out (research Finding 1). If `vite.config.mts`
   cannot fix that without a new dependency, leave it and say so.
3. Run `PLAY_BUILT=1 scripts/play.sh up`, load the page in headless Chromium, and play the reference shot once
   (`scripts/play/qa-browser.mjs` is the harness; Playwright comes from `PLAYWRIGHT_MODULE`). Then run `down`, and run
   once more without `PLAY_BUILT` to show the default still works.
4. **Measure on desktop** (no throttling, and also the Fast 4G profile), as real output: bytes transferred, request
   count, and time to the first playable frame, for dev against built. Use the research harness
   (`library/t-0023/harness/cold.mjs`), copied into your scratch directory.

## 5. Machine

The Mac (`/Users/bal7hazar/git/slingfall`): `play.sh up` builds Cairo, and no pin is written. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `feat/pb-play-built` once, when the work is complete, then `gh pr create`.
- At most one `gh` call every 5 minutes, and no `--watch`; you may report and stop while the checks run.
- Never merge; launch no agent and no review.
- `REPORT.md`: the change, the measurements, and the wasm compression result.

Work autonomously, do not ask questions, do not widen the scope.
