import { Assets, Container, Graphics, NineSliceSprite, Sprite, Texture, TilingSprite } from 'pixi.js';
import { UNITS_PER_METRE } from '../camera';
import { fixedToNumber, type LevelBody } from '../../trace/types';
import { flatSkin } from './flat';
import { KENNEY_PALETTE } from './palette';
import type { Backdrop, Skin } from './types';

/** The Kenney sprites are drawn at 70 px per metre (a 140x70 block is 2 m x 1 m). */
const PX_PER_METRE = 70;
/** Scene units (centimetres) per sprite pixel. */
const K = UNITS_PER_METRE / PX_PER_METRE;
/** Border of the blocks' nine-slice, sprite pixels: the rim and its notches stay unstretched. */
const BORDER = 12;

/** Where the skin's files live under the app's base URL (`public/assets/kenney/`, `client/ASSETS.md`). */
const ROOT = 'assets/kenney/physics/';
export const KENNEY_FILES = {
  timberH: 'wood/elementWood014.png',
  timberV: 'wood/elementWood016.png',
  slateH: 'stone/elementStone015.png',
  slateV: 'stone/elementStone017.png',
  frostH: 'glass/elementGlass016.png',
  frostV: 'glass/elementGlass023.png',
  core: 'aliens/alienGreen_round.png',
  pebble: 'stone/elementStone001.png',
  grass: 'other/grass.png',
  background: 'backgrounds/blue_grass.png',
} as const;
export type KenneyTextures = Record<keyof typeof KENNEY_FILES, Texture>;

/** Loads the skin's textures (asynchronous in PixiJS) and builds the skin; `base` is the app's base URL. */
export async function loadKenneySkin(base: string): Promise<Skin> {
  const entries = Object.entries(KENNEY_FILES);
  const textures = await Promise.all(entries.map(([, file]) => Assets.load<Texture>(`${base}${ROOT}${file}`)));
  return kenneySkin(Object.fromEntries(entries.map(([key], i) => [key, textures[i]])) as KenneyTextures);
}

/** The earth of `other/grass.png` (pixel (0, 50): rgb 189, 137, 88). */
const DIRT_COLOUR = 0xbd8958;

const BLOCKS = {
  timber: ['timberH', 'timberV'],
  slate: ['slateH', 'slateV'],
  frost: ['frostH', 'frostV'],
} as const;

/**
 * The Kenney skin (CC0, `client/ASSETS.md`): blocks are nine-slices of the plain sprite of their
 * material, cores are aliens, the ground is a grass strip over a flat earth fill, the pebble is the stone
 * circle. Shapes no sprite covers (polygons, other balls) fall back to the flat skin. Every sprite is
 * counter-flipped (`scale.y < 0`): the world is y-flipped.
 */
export function kenneySkin(t: KenneyTextures): Skin {
  const fallback = flatSkin();
  const circle = (texture: Texture, radiusMetres: number): Sprite => {
    const s = new Sprite({ texture, anchor: 0.5 });
    const k = (2 * radiusMetres * UNITS_PER_METRE) / texture.width;
    s.scale.set(k, -k);
    return s;
  };

  return {
    name: 'kenney',
    palette: KENNEY_PALETTE,
    body(body: LevelBody, extent: number): Container {
      const { shape } = body;
      if (shape.type === 'cuboid' && body.material in BLOCKS) {
        const w = 2 * fixedToNumber(shape.hx) * PX_PER_METRE;
        const h = 2 * fixedToNumber(shape.hy) * PX_PER_METRE;
        const [horizontal, vertical] = BLOCKS[body.material as keyof typeof BLOCKS];
        const slice = new NineSliceSprite({
          texture: t[w >= h ? horizontal : vertical],
          leftWidth: BORDER,
          rightWidth: BORDER,
          topHeight: BORDER,
          bottomHeight: BORDER,
          width: w,
          height: h,
        });
        slice.pivot.set(w / 2, h / 2);
        slice.scale.set(K, -K);
        return slice;
      }
      if (shape.type === 'ball' && body.material === 'core') {
        return circle(t.core, fixedToNumber(shape.radius));
      }
      if (shape.type === 'halfspace') {
        // Built in a frame where the boundary's normal points up the image, then turned to the real normal.
        const nx = fixedToNumber(shape.normal.x);
        const ny = fixedToNumber(shape.normal.y);
        const frame = new Container();
        frame.rotation = Math.atan2(ny, nx) - Math.PI / 2;
        frame.scale.set(K, -K);
        const width = (2 * extent) / K;
        const tile = t.grass.height;
        const grass = new TilingSprite({ texture: t.grass, width, height: tile });
        // The grass tile's own earth colour (sampled from its middle rows) fills below the strip.
        const dirt = new Graphics().rect(-width / 2, tile, width, extent / K).fill(DIRT_COLOUR);
        grass.position.set(-width / 2, 0);
        frame.addChild(dirt, grass);
        const view = new Container();
        view.addChild(frame);
        return view;
      }
      return fallback.body(body, extent);
    },
    pebble: (radiusMetres) => circle(t.pebble, radiusMetres),
    background(): Backdrop {
      const sprite = new Sprite(t.background);
      const view = new Container();
      view.addChild(sprite);
      return {
        view,
        // Covers the canvas, the horizon (the bottom of the image) kept in view.
        resize(width, height) {
          const s = Math.max(width, height) / t.background.width;
          sprite.scale.set(s);
          sprite.position.set((width - t.background.width * s) / 2, height - t.background.height * s);
        },
      };
    },
  };
}
