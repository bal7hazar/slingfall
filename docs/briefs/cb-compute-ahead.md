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
- **The start rule is a pure function**, `shouldStart(input) -> boolean`, in `live.ts`. Its input:
  - the ticks produced so far and the ticks shown so far;
  - the production rate measured on the chunks already run (ticks per second, from `ChunkReport {ticks, steps, ms}`);
  - **an estimate of the ticks still to come**. For that estimate, take the largest `ticks_run` of the level's
    golden cases (`fixtures/golden/*`) times a margin (say which and why), capped by the level's `tick_cap` (read it
    from the level felts; `cut.ts` skips it today, so parse it in `play.ts` or `live.ts`). Refine the estimate as the
    shot goes, for example when the pile falls asleep, if that is cheap.

  Start when the time to produce the remaining ticks at the measured rate is no longer than the time to play
  everything not yet shown at real time.
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
- `client/README.md`: rewrite the sentence that says playback slows to the arrival rate (around line 46), and add one
  paragraph on the start rule.
- `REPORT.md` (at the worktree root, not committed).
- Not `buffer.ts`, `follow.ts`, `hud.ts`, `scene.ts`, `skin/**`, `stage.ts`, `main.ts`, `controller.ts`, `index.html`,
  `style.css`, `session.ts`, nor `client/vm/**`.

## 4. Work and acceptance

1. The start rule and the hold, as in §1, with unit tests:
   - the start decision for given inputs;
   - the never-stall property once started, as a named test with the impact cam off: `playback.speed` is 1 on every
     `advance` after the start;
   - the fallback when the lead runs dry;
   - production ending while still holding (a short shot, or a fast machine): the hold releases at once, and the end
     check still fires;
   - a shot that fails during the hold: the hold clears;
   - `dispose` during the hold;
   - a second shot that starts with the head at the last frame;
   - pause and scrub during the hold.
2. **The proof is unchanged.** Record the outputs felts and the frame sequence (ticks and poses) of both pile10 shots
   on main and on the branch, and require them equal. `session.fire` keeps the same arguments, except an added
   `onChunk` handler if you need it. The existing `play.test.ts` and `vm.test.ts` pass.
3. **Measure on the Mac, headless**, as real output: the wait before play, and the wall time against real time per
   phase (flight, impact, settle), on both pile10 shots: the owner's (-1022, -63) and the reference (-604, -392).
   - The client needs the wasm runner: build it first with `client/vm/scripts/build.sh` (Rust wasm32 and
     wasm-bindgen). This is outside "no Cairo build" and allowed.
   - Use the built client (`PLAY_BUILT=1` if lot PB has merged, otherwise `vite build` and `vite preview`).
   - Driver: your own short Playwright script from `scripts/play/qa-browser.mjs`, with the `PLAYWRIGHT_MODULE` and
     the Chromium that lot L2 used on this Mac (`docs/qa/2026-09-30-mac-play.md`). If any of these is missing, report
     it and install nothing.
   - The VPS measurement is not yours: I take it after the merge.
4. The slow motion is gone: no tick plays slower than real time once the head has started (the named test of 1).

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
