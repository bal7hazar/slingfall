# Art assets

Credits: Kenney (www.kenney.nl), CC0 1.0.

Only CC0 assets (use and redistribution allowed) enter the repository; nothing is bought and no account is made.
Only the files the game uses are copied, never a whole pack, and never `preview.png`, `sample.png` or a file showing
the Kenney logo. The skin that uses them is `src/render/skin/kenney.ts`; `?skin=flat` draws no file at all.

## Packs

Fetched over HTTPS on 2026-10-02 (VPS); zip size and sha256 as downloaded.

| Pack | Version | Source | Licence | Zip (bytes, sha256) |
| --- | --- | --- | --- | --- |
| Physics Assets | 1.0 | https://kenney.nl/assets/physics-assets (zip: https://kenney.nl/media/pages/assets/physics-assets/e635010608-1677667214/kenney_physics-assets.zip) | CC0 1.0, `license.txt` of the zip (2014-08-06), copied unchanged beside the files | 2577770, `95949d1d9a733bf4b3f6312dc412013cd59184341c03ac284866499febcb67e8` |
| UI Pack | 2.0 | https://kenney.nl/assets/ui-pack (zip: https://kenney.nl/media/pages/assets/ui-pack/f651646eab-1718203990/kenney_ui-pack.zip) | CC0 1.0, `License.txt` of the zip | 1229750, `a8a14a234911eb648c062622915c93e79e94e97cb7f9f375a70f6617f1174318` |
| Particle Pack | 1.1 | https://kenney.nl/assets/particle-pack (zip: https://kenney.nl/media/pages/assets/particle-pack/f8fe0f8cb8-1677578741/kenney_particle-pack.zip) | CC0 1.0, `License.txt` of the zip | 15001764, `b631d4b07f7002549fdcf155f01141ad482f79f3440e4e301eed49ce5f1d8958` |

The Particle Pack was fetched on 2026-10-03 and **not used**: its README thanks the authors of the filter templates the
tiles were made with (Indigo Ray, Craig Nisbet, Zoltan Erdokovy, Heliagon, ThreeDee, Killst4r, Tim2501) and gives no licence
for them, and the origin of a given tile is not recorded; in doubt, left out (brief of M6, section 1). No file of it is copied.

## Files

Physics Assets: all under `public/assets/kenney/physics/`, fetched 2026-10-02 (phase A) and 2026-10-03 (phase B, the cracked, triangle
and debris sprites), unchanged from the Physics Assets 1.0 zip (`PNG/<folder>/`).

| Path | Zip path | Used for |
| --- | --- | --- |
| `license.txt` | `license.txt` | The pack's licence |
| `wood/elementWood014.png` (140x70), `wood/elementWood016.png` (70x140) | `PNG/Wood elements/` | Timber blocks, nine-slice, horizontal / vertical |
| `stone/elementStone015.png` (140x70), `stone/elementStone017.png` (70x140) | `PNG/Stone elements/` | Slate blocks, nine-slice |
| `glass/elementGlass016.png` (140x70), `glass/elementGlass023.png` (70x140) | `PNG/Glass elements/` | Frost blocks, nine-slice |
| `stone/elementStone001.png` (70x70) | `PNG/Stone elements/` | The pebble (stone circle) |
| `wood/elementWood046.png` (140x70), `wood/elementWood048.png` (70x140) | `PNG/Wood elements/` | Worn timber: the cracked sprites, swapped in under half hp |
| `stone/elementStone047.png` (140x70), `stone/elementStone049.png` (70x140) | `PNG/Stone elements/` | Worn slate |
| `glass/elementGlass048.png` (140x70), `glass/elementGlass050.png` (70x140) | `PNG/Glass elements/` | Worn frost |
| `wood/elementWood054.png`, `stone/elementStone006.png`, `glass/elementGlass001.png` (all 140x70 isosceles; checked by `skin.test.ts`) | `PNG/<Wood\|Stone\|Glass> elements/` | Triangles (cores3's static triangle, the trace's roof), mapped onto the polygon's three vertices |
| `debris/debris{Wood,Stone,Glass}_{1,2,3}.png` (9 files, about 60x55) | `PNG/Debris/` | Three pieces thrown by a destroyed body |
| `aliens/alienGreen_round.png` (70x70) | `PNG/Aliens/` | Cores |
| `other/grass.png` (70x70) | `PNG/Other/` | The ground's grass strip; its earth colour (rgb 189, 137, 88) fills below |
| `backgrounds/blue_grass.png` (1024x1024) | `PNG/Backgrounds/` | The backdrop |

Palette values (`src/render/skin/palette.ts`: posts, band, arc dots, page, text) are our own choices, picked to sit with the
sprites; they are not Kenney files.

## UI Pack 2.0 (interface)

Under `public/assets/kenney/ui/`, fetched 2026-10-03 from the zip above, unchanged; `License.txt` beside them.

| Path | Zip path | Used for |
| --- | --- | --- |
| `blue/button_rectangle_depth_gradient.png` (192x64) | `PNG/Blue/Default/` | Buttons (CSS `border-image`, `style.css`, `body[data-skin='kenney']`) |
| `extra/icon_repeat_light.png` (41x36) | `PNG/Extra/Default/` | The icon of the Retry buttons |
| `font/KenneyFuture.ttf` | `Font/Kenney Future.ttf` | The interface font |
| `License.txt` | `License.txt` | The pack's licence |
