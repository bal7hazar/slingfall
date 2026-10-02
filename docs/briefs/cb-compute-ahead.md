# CB — compute ahead, then play without slow motion

Profile `impl-sonnet` (a client lot with a clear design from measured figures). Lot id `cb-compute-ahead`, branch
`feat/cb-compute-ahead`.

## 1. Goal and context

**Goal.** No more slow motion after the first impact. The worker computes the shot ahead, and playback starts only
when the lead can no longer run dry, so the whole shot then plays at real time. The proof is unchanged: the same Cairo
run, the same outputs and the same chain flow.

**Why** (research thread of 2026-10-02, report `/home/claude/.herdr-projects/slingfall-game/threads/t-0023.md`,
read-only; path (b) of its Table 3, chosen by the owner):
- Playing at real time needs about 2.8M Cairo steps/s in flight, but 12–14M/s from the first contact on, when the pile
  wakes up (about 4.5x; measure the per-tick ratio, §1 Design).
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
  steps**, not ticks: a tick after the contact costs several times a flight tick, so a rate measured on flight chunks
  is too optimistic for the rest. Its input:
  - the ticks produced and the ticks shown so far;
  - the measured speed in steps per second, from `steps` and `ms` of the **stepping** chunks only (`ChunkReport.ticks`
    is 0 for `init` and `outputs`: exclude them);
  - the remaining steps: **until a post-contact chunk has been measured, every tick not yet produced is priced at the
    post-contact prior** (the flight mean times a factor), never at the flight rate. Once a post-contact chunk is
    measured, its mean replaces the prior.
  - **The factor is measured, not assumed.** The repository's figures point to a few times, not 15–20x (`client/README.md`
    says 3x; `client/vm/README.md` and `sizing.ts` give about 65k steps per tick in flight against 200k+ at the
    impact; the `pile10-reference` golden averages about 81k per tick). Measure it on both pile10 shots and set the
    prior from it, with a margin. Say which.
  - The contact is detected from the chunk reports: the first chunk whose steps per tick are at least 2x the flight
    mean. This is the `IMPACT_RATIO = 2` of `client/src/vm/sizing.ts`, which is private there: duplicate the constant
    and say so.
  - **Before the first stepping chunk there is no rate: the rule holds.**

  Start when the time to produce the remaining steps at the measured speed is no longer than the time to play
  everything not yet shown at real time. A single post-contact mean averages a slow impact with a cheaper settle, so
  the lead can be smallest at the impact/settle boundary. Either check the condition at that boundary too, or keep
  the mean as a deliberate approximation, with the "0 dry events" measurement as the check. Say which.
- **The ticks still to come are per shot.**
  - Use a small per-level table in `live.ts` or `play.ts`, with a margin (say which). The bundled client cannot read
    `fixtures/golden/*`, so copy the figures in.
  - Sources: `ticks_run` is **index 8 (0-based)** of the golden `outputs` felt array (`OUTPUT_FIELDS`,
    `client/src/vm/program.ts`; index 9 is `final_state_hash`). Examples: `pile10-reference` 0x6b = 107; the owner's
    shot (-1022, -63) ran 151 ticks (`docs/qa/2026-09-30-mac-play.md`). Multi-shot cases give level totals: use the
    differences between consecutive shots.
  - Cap by the level's `tick_cap` minus the current tick: `levelInfo(level).tickCap` already exists
    (`client/src/vm/program.ts`).
  - A level with no table entry defaults to `tick_cap`, so the rule holds longer, not shorter.
- **The rule applies from the release on.** On the loaded VPS even the flight is slower than real time (1.0–1.8M
  steps/s against about 2.8M needed). The contact is a lower bound, not the trigger. If you need it, take it from the
  chunk reports (the cut ends the flight chunk at the contact, and the steps per tick then rise, by a factor to measure), not from
  `predictContactTick` in the page.
- **The hold sets `playback.speed = 0`.** The existing indicator, `#simulating` in `client/index.html`, shown by
  `main.ts` when `producing() && playback.speed < 1`, then shows during the hold with no change to `main.ts`,
  `index.html` or `hud.ts`. Once started, the speed is 1 and the head never slows down. If a prediction was wrong and
  the lead runs dry, `Playback.advance` already clamps to the last frame: the head waits at speed 1, without slow
  motion, and the event is logged with the numbers through `console.warn`, or a sink injected into `ShotLoop` for the
  tests.
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
   - a fake run where the flight chunks are fast and the impact chunk is 15x slower per tick (a stress case, beyond the
     measured factor): the rule must not start at the release;
   - a fake run with a slow impact followed by a fast settle: no dry event;
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
   - For the real run: compare the console `outputs …` line that `main.ts` prints at the end of the level (it carries
     `inputs_hash`, `ticks_run` and `final_state_hash`), on main and on the branch, for both pile10 shots, by hash. The
     buffer sequence is checked in `play.test.ts` only: the page exposes no hook for it.
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
   - On the Mac, `build.sh` runs `cargo install wasm-bindgen-cli --version 0.2.100 --locked --root client/vm/tools`
     (into the git-ignored `client/vm/tools`; a few minutes): that is allowed. It needs rustup's pinned toolchain
     (`client/vm/runner/rust-toolchain.toml`) and the wasm32 target: check them first. If they are missing, report it
     and install nothing.
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
