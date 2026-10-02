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

**The patch.** It was written on the VPS (`library/t-0023/harness/play-built.patch` there), which a Mac thread cannot
read, so its substance is given here. Apply it by hand on current main. If L4 (#68) has merged by then, it has changed
`scripts/play.sh` too.
- `PLAY_BUILT=1` builds the client into `target/play/dist` at each start of the client. The contract address is baked
  in, so the build is redone each time.
- It then runs `vite preview` with the same proxy (`/rpc`, `/attest-service`, `/prove-service`) and the same
  `--host` / `--port`.
- The default (dev server) is unchanged.
- The details to get right:
  - The build runs in the foreground before `start` (the background start waits at most 30 s for HTTP).
  - Build into `target/play/dist` with `--outDir … --emptyOutDir` (the folder is outside the client root).
  - Give the build the same `VITE_*` values as `start`: they are baked in.
  - Keep `--config scripts/play/vite.config.mts` on `preview` (`running client` matches it), and give `preview` the
    same `--outDir "$PLAY/dist"` (it defaults to `client/dist`, which would serve nothing or a stale build). Setting
    `build.outDir` once in `scripts/play/vite.config.mts` is an alternative.
  - Adjust the header range that `help` prints, so the new header line shows.
- A running client is reused whatever its mode (`fresh client`). Record the mode with the client's PID, or make `up`
  restart a client of the other mode. At the least, `docs/play-local.md` says to run `down` before switching modes.

Read first: `scripts/play.sh` (`up`, `start client`, the `VITE_*` variables), `scripts/play/vite.config.mts`,
`docs/play-local.md`, and the research report's Finding 1.

## 2. Transactions

None on any public network. On the local devnet: the deploy that `play.sh up` runs, and the shot's own transactions
if a harness plays one.

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
3. Run `PLAYWRIGHT_MODULE=… PLAY_BUILT=1 scripts/play.sh up`, load the page in headless Chromium and fire one shot
   (the reference pull). Use your own short harness (§4.4), not the whole `qa-browser.mjs` flow, which also submits,
   proves and settles (about 6 minutes per run). Then run `down`, run `up` again without `PLAY_BUILT`, and show the
   page reaches its first playable frame.
4. **Measure on desktop** (no throttling, and also the Fast 4G profile), as real output: bytes transferred, request
   count, and time to the first playable frame, for dev against built.
   - Write a small harness in your scratch directory from `scripts/play/qa-browser.mjs`. Count bytes with CDP
     `Network.loadingFinished`'s `encodedDataLength`. "Playable" means the sling accepts a pull: the hint switches to
     "Drag the pebble…".
   - The research's VPS figures (dev 23.9 MB / 74 requests, built 2.6 MB / 19) are the reference to compare with.
   - **Prerequisites on the Mac:**
     - The wasm must be built (`play.sh`'s `build()`: Rust and `client/vm/scripts/build.sh`), not `PLAY_NO_VM=1`.
       Without it there is no wasm in `dist`, and the bytes and the wasm-compression result mean nothing.
     - Playwright: use the `PLAYWRIGHT_MODULE` and the browser that lot L2 used on this Mac
       (`docs/qa/2026-09-30-mac-play.md`).
     - If either is missing, report it, and install nothing.

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
