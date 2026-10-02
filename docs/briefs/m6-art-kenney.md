# M6 — the game's look: Kenney CC0 sprites in an isolated, replaceable skin

Profile `impl-sonnet` (a light client lot with a clear verdict to apply). Lot id `m6-art-kenney`, branch
`feat/m6-art-kenney`.

## 1. Goal and context

**Goal.** Replace the placeholder flat colours of the renderer with a coherent free art set: Kenney's **Physics
Assets** (blocks, cores, ground, backgrounds, debris), **UI Pack** (buttons, font) and optionally **Particle Pack**
(impact effects), all CC0. Keep the renderer isolated and replaceable.

**Owner's decisions (M6, 2026-10-02).** The name stays Slingfall, and the owner has no style preference. Free
assets that cover the game coherently come first; vector shapes from code only fill what no set covers.

**Rules.**
- An asset enters the repository only under CC0 or a licence that allows use and redistribution.
- The source and licence of every file are recorded in the repository.
- Nothing is bought, and no account is created.
- The renderer stays isolated in the client and replaceable.
- A capture of the result goes to the owner before generalising: see §4, phase A.

**Search result** (research thread of 2026-10-02; its report is summarised here):
- Kenney Physics Assets 1.0, https://kenney.nl/assets/physics-assets. Licence: CC0 (`license.txt` in the zip, dated
  2014-08-06). Five materials of block elements, each with filled, hollow and one cracked variant per most size
  families; 15 aliens (70x70 px, round, five colours); 9 debris pieces; 8 backgrounds of 1024x1024; ground tiles
  (grass, dirt, sand, snow, rock) of 70x70; editable SVG sources.
- Kenney UI Pack 2.0, https://kenney.nl/assets/ui-pack. CC0 (`License.txt`). Buttons in five colours, icons
  (`icon_repeat`, `icon_play`), sliders, and the Kenney Future font (TTF, same licence).
- Kenney Particle Pack 1.1, https://kenney.nl/assets/particle-pack. CC0 (`License.txt`). Smoke, spark and dirt
  tiles of 512x512.
- If a Particle Pack file is used, check its README's credits (it names filter-template authors with no licence
  of their own) for that file's origin, and record it in `client/ASSETS.md`; when in doubt, leave the pack out.
- **Never copy `preview.png` or `sample.png`**, nor any file that shows the Kenney logo: Kenney reserves its logo.
- Mapping: timber is Wood, slate is Stone, frost is Glass (pale cyan, reads as ice), and the cores are aliens.
- Gaps, drawn from code in the pack's palette: the sling, the band and the aim arc (already drawn from code; recolour
  only), and the pebble (the Stone circle sprite if it reads well at 0.5 m, otherwise a drawn circle).

Read first:
- `client/README.md`;
- `client/src/render/**`: `scene.ts` (every body is a flat `Graphics` today), `effects.ts`, `playback.ts`, `hud.ts`;
- `client/src/aim/controller.ts` (the sling, the band, the arc);
- `client/src/trace/types.ts` (the `damage` event carries `hp`);
- `docs/levels.md` and `fixtures/levels/*.json` (every body size: cuboids up to 7x0.4 m, balls of r 0.25 and 0.4,
  the ground half-space, the `cores3` static triangle and tilted slab);
- `docs/DESIGN.md` (material hp: timber 100, slate 300, frost 40, core 30).

## 2. Transactions

None.

## 3. Scope (allowlist)

Everything else is forbidden; needs go to "Escalations".

- `client/src/main.ts` and `client/src/game/stage.ts`: only to preload the skin's textures (Pixi `Assets.load` is
  asynchronous; build the `Scene` once they are loaded), to select the skin, and to take the page background from the
  skin.
- `client/public/assets/kenney/**` (new): only the files the game uses (PNG or SVG, plus the font), never a whole
  pack. Each pack's licence file sits beside its files, unchanged.
- `client/ASSETS.md` (new): one row per file or per family, giving the path, pack and version, source URL, licence,
  and the date fetched; plus a "Credits" line: "Kenney (www.kenney.nl), CC0 1.0".
- `client/src/render/**`, `client/src/aim/controller.ts` (only to take the pebble, the band
  and the colours from the skin), `client/index.html`, `client/src/style.css`,
  and the client's tests.
- `docs/captures/m6/**` (new): the captures of §4.
- `REPORT.md` at the worktree root.
- A capture script under `docs/captures/m6/` (it may copy the harness of `scripts/play/qa-browser.mjs`).
- Not `client/vm/**`, not `client/package.json` (no new dependency: Pixi v8 already has sprites, nine-slice and text),
  not the game, the contract or the replay.

## 4. Work

**The skin is replaceable.** Every visual choice lives behind one module, for example `client/src/render/skin/`, with
an interface such as `bodySprite(material, shape, size, state)`, `ground(extent)`, `background()`, `pebble()`,
`core()` and `palette`. `scene.ts` and `effects.ts` call only that interface. A second implementation, `flat`, keeps
today's coloured shapes. A query parameter or constant selects the skin, and a test runs both, so swapping the art
later touches one folder.

**One source of truth.** The controller's pebble and band (`controller.ts` draws its own pebble today with a copy of
the scene's colour) come from the skin too, so the pebble at the sling and in flight are the same.

**The world is y-flipped** (`scene.ts`: `this.world.scale.set(s, -s)`): every skin sprite is counter-flipped
(`scale.y = -1` or an equivalent), and the ground strip and background are laid out in that frame. A test, or the
capture, shows the grass edge on top and the aliens upright.

**Phase A: one level, then stop.**
1. Implement the Kenney skin for the playfield of `pile10`:
   - blocks by material, with any box size through a **nine-slice** of the plain 140x70 / 70x140 sprite (measure the
     border, about 8 px);
   - the cores;
   - the ground as a tiled strip along the half-plane plus fill below;
   - one background;
   - the pebble;
   - the sling, band and arc recoloured.
   States as today: asleep tint, damage flash, destroyed fade.
2. Capture it on the VPS with headless Chromium. Use the harness of `scripts/play/qa-browser.mjs` (Playwright comes
   from `PLAYWRIGHT_MODULE`, since `playwright` is not a client dependency; its browser is cached under
   `~/.cache/ms-playwright`), against the dev server. Choose each frame deterministically: a fixed tick of the
   reference trace (`client/public/traces/`) through the scrub range. one PNG at rest with the sling, one mid-flight on the reference shot's trace,
   and one after impact. Save them under `docs/captures/m6/`.
3. Commit, push, open the PR, and **stop**. Write `REPORT.md` with the captures' paths and what phase B would add.
   Phase B starts only on my line `Phase B` (the capture goes to the owner first). If the owner asks for changes,
   they come as a prompt.

**Phase B, on my line only.**
4. Every level, including `cores3`'s static triangle (a Kenney triangle sprite) and its tilted slab.
5. Wear: the cracked variant when `hp` falls under half the material's hp (from the `damage` events). For a
   nine-slice slab with no cracked sprite, overlay a crack texture from a cracked sprite, or show no wear: say which.
6. Destroyed: the existing fade, plus 2-3 debris sprites of the material, and a puff from the Particle Pack if it
   reads well (optional; keep it light).
7. Interface: buttons and icons from the UI Pack, the Kenney Future font, and the panels styled in CSS from the same
   palette.
8. Captures of every level after impact, and of the interface, under `docs/captures/m6/`.

**Performance.** Measure the frame time of the reference shot's playback with the flat skin and with the Kenney skin
(`performance.now()` around the frame update, in the headless run), and report both.

## 5. Machine

The VPS (headless Chromium). No Cairo build is needed: the client uses the committed fixtures and traces. Foreground
only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing, if it exists on main.
- Push `feat/m6-art-kenney`, then `gh pr create`, then `gh pr checks --watch` in the foreground until green (`client`
  job included).
- Never merge; launch no agent and no review.
- `REPORT.md`:
  - the skin interface;
  - the files copied, with their licences;
  - the captures;
  - the frame times;
  - what was not done.

Work autonomously, do not ask questions, do not widen the scope.
