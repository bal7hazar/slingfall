# M6b — phones play in landscape: a "rotate your phone" overlay in portrait

Profile `impl-sonnet` (a small client change with a clear rule). Lot id `m6b-phone-landscape`, branch
`feat/m6b-phone-landscape`.

## 1. Goal and context

M6 (#67) fits the camera to the level's width. In portrait on a phone, that leaves the whole level as a strip about
60 px high at the bottom of a sky-filled screen, with blocks a few pixels each
(`docs/captures/m6/pile10-rest-412x915.png`). For a mobile-first game that is not playable.

**The project manager's decision** (reversible): phones play in landscape, as Angry Birds-type games do.
- In portrait, the page shows a clear "rotate your phone" overlay over the paused scene.
- There is no gameplay change.

**Your call:** if you find a framing that keeps portrait playable at no real cost, propose it in the PR instead of the
overlay, with captures. One example is a camera that follows the pebble from the sling to the target. "At no real
cost" means no change to the simulation, the trace or the proof, and no extra frame time worth measuring. Otherwise,
build the overlay.

## 2. Transactions

None.

## 3. Scope (allowlist)

- `client/index.html`: the overlay element.
- `client/src/style.css`: its look and the orientation query.
- `client/src/game/orientation.ts` (new) and its test: the overlay's logic as a small pure module, testable.
- `client/src/main.ts`: only to wire that module (the query listener, the pause and resume, the inert scene). No timing
  logic changes: CB's rule in `live.ts` / `play.ts` is untouched.
- `client/src/render/camera.ts`, only for the portrait-framing alternative of §1.
- Tests in `client/src/**/*.test.ts` for what you add.
- `docs/captures/m6/` (new captures, and `captures.txt`; `capture.mjs` may gain the new viewport).
- `REPORT.md` (not committed).
- Not the skin's sprites, not `client/vm/**`, not anything under `crates/`.

## 4. Work

1. **The overlay:**
   - It shows on a phone in portrait: `(orientation: portrait) and (max-width: 600px) and (pointer: coarse)`. The
     coarse pointer keeps a narrow desktop window, with its mouse, out. 600 px matches `main.ts`'s NARROW query.
   - **One source of truth:** `orientation.ts` evaluates the query (`matchMedia`) and sets a class on `<body>`.
     `style.css` shows the overlay from that class, never from its own media query, so the overlay and the pause can
     never disagree.
   - It covers the scene with a short message and an icon drawn in CSS or SVG inline, using the UI Pack's font and
     palette. No new asset.
   - It pauses the live playback while shown. On return to landscape it resumes **only if the playback was playing when
     the overlay appeared**, so a pause the user chose before rotating stays paused. A shot in flight keeps its frames:
     only the head waits.
   - **The mechanism, pinned:** set the playback's playing flag directly. Save it when the overlay appears, set it to
     false, and on return set it back to the saved value. **Never call `togglePlay()` / `Playback.toggle()`**: at the
     end of a finished trace it restarts from 0, so a rotation would replay a finished shot.
   - While it shows, everything but the overlay is **inert**: `inert` on every interactive sibling of the overlay:
     `#app` (the scene), `#controls`, `#result` (Retry, Copy inputs, the wallet's Connect and Submit), `#banner`, and the
     chain strip. Or put them under one wrapper and make that inert. The keyboard handlers (`Space`, `Enter`, the
     arrows) do nothing: no aim, no shot, no Play or Retry.
   - Unit tests in `orientation.test.ts`, with a mocked `matchMedia`:
     - a coarse-pointer portrait shows the overlay; a fine-pointer narrow portrait (a desktop window) does not;
     - the resume rule: was playing, it resumes; was paused, it stays paused; a finished trace is not restarted;
     - the key handlers are ignored while it shows;
     - every interactive sibling, `#result` included, is inert while it shows.
   - Accessible: `role="dialog"` or `status`, readable text, no motion that ignores `prefers-reduced-motion`.
2. **Landscape phone captures** at 915×412. In `capture.mjs`, the phone flows (rest, the impact of all six levels,
   the interface) move from 412×915 to 915×412, in a context with `hasTouch: true` and `isMobile: true` (coarse pointer).
   **Delete every old `*-412x915.png`** from `docs/captures/m6/`, since they would now show only the overlay. Rewrite
   `captures.txt` with the new ones, naming the ticks.
   Also capture one **narrow desktop window** (for example 500×900, fine pointer, no touch): the overlay must not show.
   That is the checkable proof of the query.
3. **Fit at 412 px height:** check that the HUD, the hint, the bottom bar and the result panel all fit and stay readable
   at 915×412, and fix what does not, in `style.css`. A capture of the result panel open at 915×412 shows it.
4. **A portrait capture** at 412×915 showing the overlay, in a coarse-pointer context.
5. If you propose the portrait-framing alternative of §1 instead, measure its frame time against M6's figures
   (`docs/captures/m6/frame-times.json`, same method), and capture it.

## 5. Machine

The VPS (headless Chromium, the harness of `docs/captures/m6/capture.mjs`). No Cairo build. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer. Run `scripts/prepush.sh` before pushing.
- Push `feat/m6b-phone-landscape` once, then `gh pr create` with the captures linked in the body.
- At most one `gh` call every 5 minutes. Never merge; launch no agent and no review.
- `REPORT.md`: the overlay rule, the captures, and the portrait-framing alternative, if any, with its captures.

Work autonomously, do not ask questions, do not widen the scope.
