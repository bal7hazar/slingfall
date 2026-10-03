import { Assets, Container, Graphics, Matrix, NineSliceSprite, Sprite, Texture, TilingSprite } from 'pixi.js';
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
/** The pebble is drawn this much larger than its 0.25 m body (taste: it must read at a glance), and dark. */
const PEBBLE_VISUAL_SCALE = 1.3;
const PEBBLE_TINT = 0x4a5a63;
/** A debris piece is about this wide, scene units. */
const DEBRIS_SIZE = 38;

/** The earth of `other/grass.png` (pixel (0, 50): rgb 189, 137, 88). */
const DIRT_COLOUR = 0xbd8958;

/** Where the skin's files live under the app's base URL (`public/assets/kenney/`, `client/ASSETS.md`). */
const ROOT = 'assets/kenney/physics/';
export const KENNEY_FILES = {
  timberH: 'wood/elementWood014.png',
  timberV: 'wood/elementWood016.png',
  timberHCracked: 'wood/elementWood046.png',
  timberVCracked: 'wood/elementWood048.png',
  timberTri: 'wood/elementWood054.png',
  slateH: 'stone/elementStone015.png',
  slateV: 'stone/elementStone017.png',
  slateHCracked: 'stone/elementStone047.png',
  slateVCracked: 'stone/elementStone049.png',
  slateTri: 'stone/elementStone006.png',
  frostH: 'glass/elementGlass016.png',
  frostV: 'glass/elementGlass023.png',
  frostHCracked: 'glass/elementGlass048.png',
  frostVCracked: 'glass/elementGlass050.png',
  frostTri: 'glass/elementGlass001.png',
  core: 'aliens/alienGreen_round.png',
  pebble: 'stone/elementStone001.png',
  grass: 'other/grass.png',
  background: 'backgrounds/blue_grass.png',
  debrisWood1: 'debris/debrisWood_1.png',
  debrisWood2: 'debris/debrisWood_2.png',
  debrisWood3: 'debris/debrisWood_3.png',
  debrisStone1: 'debris/debrisStone_1.png',
  debrisStone2: 'debris/debrisStone_2.png',
  debrisStone3: 'debris/debrisStone_3.png',
  debrisGlass1: 'debris/debrisGlass_1.png',
  debrisGlass2: 'debris/debrisGlass_2.png',
  debrisGlass3: 'debris/debrisGlass_3.png',
} as const;
export type KenneyTextures = Record<keyof typeof KENNEY_FILES, Texture>;

/** Loads the skin's textures (asynchronous in PixiJS) and builds the skin; `base` is the app's base URL. */
export async function loadKenneySkin(base: string): Promise<Skin> {
  const entries = Object.entries(KENNEY_FILES);
  const textures = await Promise.all(entries.map(([, file]) => Assets.load<Texture>(`${base}${ROOT}${file}`)));
  return kenneySkin(Object.fromEntries(entries.map(([key], i) => [key, textures[i]])) as KenneyTextures);
}

/** The sprites of a block material: plain and cracked, horizontal and vertical, and its triangle. */
const BLOCKS = {
  timber: { h: 'timberH', v: 'timberV', hCracked: 'timberHCracked', vCracked: 'timberVCracked', tri: 'timberTri', debris: 'debrisWood' },
  slate: { h: 'slateH', v: 'slateV', hCracked: 'slateHCracked', vCracked: 'slateVCracked', tri: 'slateTri', debris: 'debrisStone' },
  frost: { h: 'frostH', v: 'frostV', hCracked: 'frostHCracked', vCracked: 'frostVCracked', tri: 'frostTri', debris: 'debrisGlass' },
} as const;
type Block = (typeof BLOCKS)[keyof typeof BLOCKS];

/** Wear swaps a nine-slice's texture for the cracked sprite of the same material (and orientation). */
const wearOf = new WeakMap<Container, (worn: boolean) => void>();

const u = (metres: number): number => metres * UNITS_PER_METRE;

/**
 * The Kenney skin (CC0, `client/ASSETS.md`): blocks are nine-slices of the plain sprite of their
 * material (the cracked sprite once worn), triangles are the material's triangle sprite mapped onto the
 * polygon, cores are aliens, the ground is a grass strip over a flat earth fill, the pebble is the stone
 * circle, tinted dark. Shapes no sprite covers (polygons of more than three vertices, other balls) fall back
 * to the flat skin. Every sprite is counter-flipped or mapped in the y-up frame: the world is y-flipped.
 */
export function kenneySkin(t: KenneyTextures): Skin {
  const fallback = flatSkin();
  const circle = (texture: Texture, radiusMetres: number): Sprite => {
    const s = new Sprite({ texture, anchor: 0.5 });
    const k = (2 * radiusMetres * UNITS_PER_METRE) / texture.width;
    s.scale.set(k, -k);
    return s;
  };
  const blockOf = (material: string): Block | undefined => BLOCKS[material as keyof typeof BLOCKS];
  // Anything else static or unknown reads as stone.
  const triangleBlock = (material: string): Block => blockOf(material) ?? BLOCKS.slate;

  return {
    name: 'kenney',
    palette: KENNEY_PALETTE,
    body(body: LevelBody, extent: number): Container {
      const { shape } = body;
      // A static slab or triangle of any other material (`ground`) reads as stone.
      const block = blockOf(body.material) ?? (body.kind === 'static' ? BLOCKS.slate : undefined);
      if (shape.type === 'cuboid' && block) {
        const w = 2 * fixedToNumber(shape.hx) * PX_PER_METRE;
        const h = 2 * fixedToNumber(shape.hy) * PX_PER_METRE;
        const wide = w >= h;
        const plain = t[wide ? block.h : block.v];
        const cracked = t[wide ? block.hCracked : block.vCracked];
        const slice = new NineSliceSprite({
          texture: plain,
          leftWidth: BORDER,
          rightWidth: BORDER,
          topHeight: BORDER,
          bottomHeight: BORDER,
          width: w,
          height: h,
        });
        slice.pivot.set(w / 2, h / 2);
        slice.scale.set(K, -K);
        wearOf.set(slice, (worn) => {
          slice.texture = worn ? cracked : plain;
        });
        return slice;
      }
      if (shape.type === 'ball' && body.material === 'core') {
        return circle(t.core, fixedToNumber(shape.radius));
      }
      if (shape.type === 'polygon' && shape.vertices.length === 3) {
        return triangle(t[triangleBlock(body.material).tri], shape.vertices.map((v) => ({ x: u(fixedToNumber(v.x)), y: u(fixedToNumber(v.y)) })));
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
    pebble(radiusMetres) {
      const s = circle(t.pebble, radiusMetres * PEBBLE_VISUAL_SCALE);
      s.tint = PEBBLE_TINT;
      return s;
    },
    wear(view, worn) {
      wearOf.get(view)?.(worn);
    },
    debris(material, index) {
      const kind = (blockOf(material) ?? BLOCKS.slate).debris;
      const texture = t[`${kind}${(index % 3) + 1}` as keyof KenneyTextures];
      const s = new Sprite({ texture, anchor: 0.5 });
      const k = DEBRIS_SIZE / texture.width;
      s.scale.set(k, -k);
      return s;
    },
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

/**
 * A triangle sprite (apex top centre, base along the bottom) mapped onto three local vertices: the apex
 * is the vertex opposite the longest edge, the base runs along that edge.
 */
function triangle(texture: Texture, v: { x: number; y: number }[]): Container {
  let apex = 0;
  let longest = -1;
  for (let i = 0; i < 3; i++) {
    const a = v[(i + 1) % 3];
    const b = v[(i + 2) % 3];
    const len = Math.hypot(a.x - b.x, a.y - b.y);
    if (len > longest) {
      longest = len;
      apex = i;
    }
  }
  const top = v[apex];
  const left = v[(apex + 1) % 3];
  const right = v[(apex + 2) % 3];
  const w = texture.width;
  const h = texture.height;
  // Sprite pixel (x, y) -> top + ex * (x - w / 2) + ey * y, with ex along the base and ey from the apex to the base.
  const ex = { x: (right.x - left.x) / w, y: (right.y - left.y) / w };
  const mid = { x: (left.x + right.x) / 2, y: (left.y + right.y) / 2 };
  const ey = { x: (mid.x - top.x) / h, y: (mid.y - top.y) / h };
  const s = new Sprite(texture);
  s.setFromMatrix(new Matrix(ex.x, ex.y, ey.x, ey.y, top.x - ex.x * (w / 2), top.y - ex.y * (w / 2)));
  // The scene moves and turns the returned view: the mapped sprite sits inside it.
  const view = new Container();
  view.addChild(s);
  return view;
}
