import { Container, Graphics } from 'pixi.js';
import { UNITS_PER_METRE } from '../camera';
import { fixedToNumber, type LevelBody, type Shape } from '../../trace/types';
import { FLAT_PALETTE } from './palette';
import type { Skin } from './types';

/** Flat colours per material (docs/DESIGN.md D12 names). */
export const MATERIAL_COLOURS: Readonly<Record<string, number>> = {
  timber: 0xb07d48,
  slate: 0x66727f,
  frost: 0x9fd8e8,
  core: 0xe0554b,
  ground: 0x3a4150,
};
const FALLBACK_COLOUR = 0x9a9a9a;
const OUTLINE = 0x14161b;

const u = (metres: number): number => metres * UNITS_PER_METRE;

/** Draws a shape in body-local coordinates, in scene units (centimetres). */
function drawShape(g: Graphics, shape: Shape, colour: number, extent: number): void {
  switch (shape.type) {
    case 'ball':
      g.circle(0, 0, u(fixedToNumber(shape.radius)));
      break;
    case 'cuboid': {
      const hx = u(fixedToNumber(shape.hx));
      const hy = u(fixedToNumber(shape.hy));
      g.rect(-hx, -hy, 2 * hx, 2 * hy);
      break;
    }
    case 'polygon':
      g.poly(shape.vertices.flatMap((v) => [u(fixedToNumber(v.x)), u(fixedToNumber(v.y))]));
      break;
    case 'halfspace': {
      // The half-plane below its boundary, cut to `extent` around the body.
      const nx = fixedToNumber(shape.normal.x);
      const ny = fixedToNumber(shape.normal.y);
      const tx = -ny * extent;
      const ty = nx * extent;
      const dx = -nx * extent;
      const dy = -ny * extent;
      g.poly([tx, ty, -tx, -ty, -tx + dx, -ty + dy, tx + dx, ty + dy]);
      break;
    }
  }
  g.fill(colour);
  if (shape.type !== 'halfspace') g.stroke({ width: u(0.03), color: OUTLINE });
}

/** The flat skin: coloured shapes with a dark outline, no textures; also the Kenney skin's fallback. */
export function flatSkin(): Skin {
  return {
    name: 'flat',
    palette: FLAT_PALETTE,
    body(body: LevelBody, extent: number): Container {
      const g = new Graphics();
      drawShape(g, body.shape, MATERIAL_COLOURS[body.material] ?? FALLBACK_COLOUR, extent);
      return g;
    },
    pebble(radiusMetres: number): Container {
      const g = new Graphics();
      drawShape(g, { type: 'ball', radius: String(Math.round(radiusMetres * 2 ** 32)) }, FLAT_PALETTE.pebble, 0);
      return g;
    },
    background: () => undefined,
  };
}
