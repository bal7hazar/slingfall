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

**Design** (the research's sketch; you may improve it, saying why):
- Hold the head at the release, or better at the predicted contact tick, since the flight is cheap and can play live.
- Start when the predicted end of production is no later than the end of playback at real time.
- Predict production from the measured steps/s of the chunks already run, and a steps-per-tick estimate after the
  contact.
- During the hold, show a small "simulating…" indicator. Optionally, an intentional 0.5x "impact cam" over the first
  ticks after the contact, to hide part of the wait: the owner has not asked for it, so leave it off by default and
  describe it.
- Once started, the head never stalls. If a prediction was wrong and the lead runs dry, the head waits, without slow
  motion, and the event is logged with the numbers.

**M6 runs alongside.** M6 (the art skin, PR #67) changes `client/src/render/scene.ts`, `render/skin/**`,
`game/stage.ts`, `main.ts` and `aim/controller.ts`. Keep **timing** in `live.ts` / `play.ts` and keep drawing out of
them, so the two lots do not collide. A later M6 phase B is cut from main after this lot merges.

## 2. Transactions

None.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `client/src/render/live.ts`, `client/src/render/live.test.ts`.
- `client/src/game/play.ts`, `client/src/game/play.test.ts`.
- `client/src/render/buffer.ts`, `client/src/render/follow.ts` and their tests, only if the hold needs them.
- `client/src/render/hud.ts`: only the "simulating…" indicator, text only, no styling of the skin.
- `client/README.md`: one paragraph on the start rule.
- `REPORT.md`.
- Not `scene.ts`, `skin/**`, `stage.ts`, `main.ts`, `controller.ts`, `index.html`, `style.css` (M6), and not
  `client/vm/**`.

## 4. Work and acceptance

1. The start rule and the hold, as in §1, with unit tests: the start decision for given production and consumption
   rates, the never-stall property once started, and the fallback when the lead runs dry.
2. The proof is unchanged: the same outputs and chain calls as before, for the reference shot and the owner's shot.
3. **Measure, on desktop, headless**, as real output: the wait before play and the wall time against real time per
   phase (flight, impact, settle), on both pile10 shots (owner's (-1022, -63) and reference (-604, -392)):
   - on the **Mac** (the lot runs there);
   - on the **VPS**, the same measurement through the research harness (`library/t-0023/harness/shot.mjs`,
     `phases.mjs`, `waits.mjs`, copied into your scratch directory). If you cannot reach the VPS from the Mac, say
     so: I run the VPS measurement after the merge.
   Use the built client (`PLAY_BUILT=1` if lot PB has merged, otherwise `vite build` plus `vite preview`).
4. The slow motion is gone: no tick plays slower than real time once the head has started.

## 5. Machine

The Mac (`/Users/bal7hazar/git/slingfall`). No Cairo build is needed: the client uses the committed executables.
Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `feat/cb-compute-ahead` once, when complete, then `gh pr create`.
- At most one `gh` call every 5 minutes, and no `--watch`.
- Never merge; launch no agent and no review.
- `REPORT.md`: the rule, the tests, and the measurement tables.

Work autonomously, do not ask questions, do not widen the scope.
