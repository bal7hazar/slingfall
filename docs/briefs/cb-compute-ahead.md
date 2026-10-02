# CB — compute ahead, then play without slow motion

Profile `impl-sonnet` (a client lot with a clear design from measured figures). Lot id `cb-compute-ahead`, branch
`feat/cb-compute-ahead`.

## 1. Goal and context

**Goal.** No more slow motion after the first impact. The worker computes the shot ahead, and playback starts only
when the lead can no longer run dry, so the whole shot then plays at real time. The proof is unchanged: the same Cairo
run, the same outputs and the same chain flow.

**Why** (research thread of 2026-10-02, report `/home/claude/.herdr-projects/slingfall-game/threads/t-0023.md`,
read-only; path (b) of its Table 3, chosen by the owner):
- Playing at real time needs about 2.8M Cairo steps/s in flight, but 12–14M/s from the first contact on: the steps per
  tick jump 15–20x when the pile wakes up.
- The client VM does 6.3–6.9M steps/s on the Mac and 1.0–1.8M/s on the loaded VPS.
- Measured waits before play with (b), on the VPS: owner's shot 11.6–20.9 s, reference shot 5.2–9.7 s. Estimated on the
  Mac: 1.2 s and 0 s.

**What exists today.**
- `client/src/render/buffer.ts` keeps every frame, and `follow.ts` looks 12 frames ahead.
- `client/src/render/live.ts` holds the timing: `LEAD_FRAMES = 8`, `ArrivalRate`, and `liveSpeed()`, which slows the
  head to the arrival rate when the lead is short. That slowing is the slow motion.
- `client/src/game/play.ts` starts the head.
- The contact tick is already predicted, by the chunk cut (`client/src/vm/`; read it).

**Design.**
- **The start rule is a pure function**, `shouldStart(input) -> boolean`, in `live.ts`, and it counts in **Cairo
  steps**, not ticks: the steps per tick jump 15–20x at the contact, so a rate measured on flight chunks would be 15–20x
  too optimistic for the rest. Its input:
  - the ticks produced and the ticks shown so far;
  - the measured speed in steps per second, from `steps` and `ms` of the **stepping** chunks only (`ChunkReport.ticks`
    is 0 for `init` and `outputs`: exclude them);
  - the remaining steps: the remaining ticks times a steps-per-tick estimate for the phase. In flight, the mean of the
    flight chunks. After the contact, a post-contact figure: the measured mean of the post-contact chunks once there is
    one; before that, the flight figure times a factor taken from the references (about 20x; measure it and say which).
  - The contact is detected from the chunk reports: the first chunk whose steps per tick exceed the flight mean by a
    threshold (say which).
  - **Before the first stepping chunk there is no rate: the rule holds.**

  Start when the time to produce the remaining steps at the measured speed is no longer than the time to play
  everything not yet shown at real time.
- **The ticks still to come are per shot.** Take them from single-shot golden cases: `ticks_run` is element 9 of the
  `outputs` felt array (`OUTPUT_FIELDS`, `client/src/vm/program.ts`), for example `pile10-reference` 0x6b = 107.
  Multi-shot cases give level totals: use the differences between consecutive shots, or a fixed per-level constant.
  Apply a margin (say which), and cap by the level's `tick_cap` minus the current tick. `tick_cap` is felt index 5 of
  `session.level.felts` (`cut.ts` skips it today). The owner's shot (-1022, -63) is in no golden: measure it in the
  report.
- **The rule applies from the release on.** On the loaded VPS even the flight is slower than real time (1.0–1.8M
  steps/s against about 2.8M needed). The contact is a lower bound, not the trigger. If you need it, take it from the
  chunk reports (the cut ends the flight chunk at the contact, and the steps per tick then jump 15–20x), not from
  `predictContactTick` in the page.
- **The hold sets `playback.speed = 0`.** The existing indicator, `#simulating` in `client/index.html`, shown by
  `main.ts` when `producing() && playback.speed < 1`, then shows during the hold with no change to `main.ts`,
  `index.html` or `hud.ts`. Once started, the speed is 1 and the head never slows down. If a prediction was wrong and
  the lead runs dry, `Playback.advance` already clamps to the last frame: the head waits at speed 1, without slow
  motion, and the event is logged with the numbers.
- An optional 0.5x "impact cam": not asked for by the owner. Off by default; describe it in the report only.

**M6 and the order.** M6 phase A (PR #67) changes `client/src/render/scene.ts`, `render/skin/**`, `game/stage.ts`,
`main.ts`, `aim/controller.ts`, `client/ASSETS.md` and the assets. M6's brief allowlists all of `client/src/render/**`,
`main.ts`, `index.html`, `style.css` and `client/README.md`. This lot is narrowed so as not to collide with phase A,
and it merges **first**: #67 rebases on it if needed, and M6 phase B is cut from main after this lot merges. If you
need a file outside §3, stop and escalate.

## 2. Transactions

None.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `client/src/render/live.ts`, `client/src/render/live.test.ts`.
- `client/src/game/play.ts`, `client/src/game/play.test.ts`.
- `client/README.md`: rewrite the two places that describe the slow motion (around line 46, and line 88: "live
  (arrival rate, slow-motion speed)"), and add one paragraph on the start rule. Remove `ArrivalRate` and `liveSpeed`,
  and their tests, if nothing else uses them; otherwise keep them and say why.
- `REPORT.md` (at the worktree root, not committed).
- Not `buffer.ts`, `follow.ts`, `hud.ts`, `scene.ts`, `skin/**`, `stage.ts`, `main.ts`, `controller.ts`, `index.html`,
  `style.css`, `session.ts`, nor `client/vm/**`.

## 4. Work and acceptance

1. The start rule and the hold, as in §1, with unit tests:
   - the start decision for given inputs;
   - the never-stall property once started, as a named test with the impact cam off: with a fake producer that keeps
     the lead, the head advances by `dt*60` on every `advance` after the start (speed 1 alone is not enough: a dry lead
     also has speed 1 and a motionless head);
   - a fake run where the flight chunks are fast and the impact chunk is 15x slower per tick: the rule must not start
     at the release;
   - a dry lead is logged with its numbers;
   - the fallback when the lead runs dry;
   - production ending while still holding (a short shot, or a fast machine): the hold releases at once, and the end
     check still fires;
   - a shot that fails during the hold: the hold clears;
   - `dispose` during the hold;
   - a second shot that starts with the head at the last frame;
   - pause and scrub during the hold.
2. **The proof is unchanged.**
   - In `play.test.ts`: assert the `session.fire` arguments (the same as main's, except an added `onChunk` handler) and
     the exact sequence pushed into the buffer, with and without `onChunk`.
   - For the real run: dump the buffer ticks and the outputs felts of both pile10 shots from the Mac browser run, on main
     and on the branch, and compare them by hash.
   - The existing `play.test.ts` and `vm.test.ts` pass.
3. **Measure on the Mac, headless**, as real output: the wait before play, and the wall time against real time per
   phase (flight, impact, settle), on both pile10 shots: the owner's (-1022, -63) and the reference (-604, -392).
   - The client needs the wasm runner: build it first with `client/vm/scripts/build.sh` (Rust wasm32 and
     wasm-bindgen). This is outside "no Cairo build" and allowed.
   - Use the built client (`PLAY_BUILT=1` if lot PB has merged, otherwise `vite build` and `vite preview`).
   - Driver: your own short Playwright script. Aim the shot with the keys, as `scripts/play/qa-browser.mjs` does.
     Sample `#scrub.value`, the HUD tick and `#simulating.hidden` with `requestAnimationFrame` in `page.evaluate`: the
     page exposes no other hook.
   - Use the `PLAYWRIGHT_MODULE` and the Chromium that lot L2 used on this Mac (`docs/qa/2026-09-30-mac-play.md`).
   - `build.sh` downloads `wasm-bindgen-cli` 0.2.100 into `client/vm/tools/bin` if it is not on PATH. That download is
     allowed, inside the repository's git-ignored tools folder. If any other prerequisite is missing, report it and
     install nothing.
   - If PB has not merged, use the fallback: `vite build`, then `vite preview`.
   - The VPS measurement is not yours: I take it after the merge.
4. The slow motion is gone: no tick plays slower than real time once the head has started (the named test of 1), and
   the Mac measurement shows **0 dry events** on both pile10 shots.

## 5. Machine

The Mac (`/Users/bal7hazar/git/slingfall`). No Cairo build: the client uses the committed executables; only the wasm
runner is built. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `feat/cb-compute-ahead` once, when complete, then `gh pr create`.
- At most one `gh` call every 5 minutes, and no `--watch`.
- Never merge; launch no agent and no review.
- `REPORT.md`: the rule, the tests, and the measurement tables.

Work autonomously, do not ask questions, do not widen the scope.
