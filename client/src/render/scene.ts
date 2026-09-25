import { Container, Graphics } from 'pixi.js';
import { ABSENT, ASLEEP, TraceBuffer } from './buffer';
import { UNITS_PER_METRE, type Camera } from './camera';
import { fixedToNumber, type LevelBody, type Shape, type TraceLevel } from '../trace/types';

/** Placeholder flat colours per material (docs/DESIGN.md D12 names) until real assets exist. */
export const MATERIAL_COLOURS: Readonly<Record<string, number>> = {
  timber: 0xb07d48,
  slate: 0x66727f,
  frost: 0x9fd8e8,
  core: 0xe0554b,
  ground: 0x3a4150,
};
export const PEBBLE_COLOUR = 0xe8b64c;
const FALLBACK_COLOUR = 0x9a9a9a;

/** D12: the pebble is a ball of radius 0.25 m (raw 0.25 * 2^32). */
const PEBBLE_SHAPE: Shape = { type: 'ball', radius: String(2 ** 30) };

const AWAKE_TINT = 0xffffff;
const ASLEEP_TINT = 0x8a8f99;
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

function bodyGraphics(body: LevelBody | undefined, extent: number): Graphics {
  const g = new Graphics();
  if (body) {
    drawShape(g, body.shape, MATERIAL_COLOURS[body.material] ?? FALLBACK_COLOUR, extent);
  } else {
    drawShape(g, PEBBLE_SHAPE, PEBBLE_COLOUR, extent);
  }
  return g;
}

/**
 * The PixiJS scene of a trace: one `Graphics` per body, flat-coloured, drawn once. `update`
 * moves them from the buffer with linear interpolation between frames (display only) and dims the
 * sleeping ones; it allocates nothing. The scene is in centimetres, y up: `world` carries the
 * camera transform.
 */
export class Scene {
  readonly world = new Container();
  /** Layer above the bodies for overlays (the aim arc). */
  readonly overlay = new Container();

  private readonly level: TraceLevel;
  private readonly buffer: TraceBuffer;
  private readonly extent: number;
  private readonly sprites: Graphics[] = [];
  private readonly tints: number[] = [];

  constructor(level: TraceLevel, buffer: TraceBuffer) {
    this.level = level;
    this.buffer = buffer;
    const b = level.bounds;
    const w = fixedToNumber(b.max_x) - fixedToNumber(b.min_x);
    const h = fixedToNumber(b.max_y) - fixedToNumber(b.min_y);
    this.extent = u(Math.hypot(w, h));
    this.world.addChild(this.overlay);
    this.syncSprites();
  }

  setCamera(camera: Camera): void {
    const s = camera.scale / UNITS_PER_METRE;
    this.world.scale.set(s, -s);
    this.world.position.set(camera.offsetX, camera.offsetY);
  }

  /** Draws the buffer at fractional frame index `position`. */
  update(position: number): void {
    this.syncSprites();
    const { frameCount, columns } = this.buffer;
    if (frameCount === 0) return;
    const last = frameCount - 1;
    const i = Math.min(Math.max(Math.floor(position), 0), last);
    const j = Math.min(i + 1, last);
    const a = Math.min(Math.max(position - i, 0), 1);
    for (let slot = 0; slot < columns.length; slot++) {
      const c = columns[slot];
      const sprite = this.sprites[slot];
      const state = c.state[i];
      sprite.visible = state !== ABSENT;
      if (state === ABSENT) continue;
      // A body gone at the next frame stays where it was until then.
      const t = c.state[j] === ABSENT ? 0 : a;
      sprite.position.set(u(c.x[i] + (c.x[j] - c.x[i]) * t), u(c.y[i] + (c.y[j] - c.y[i]) * t));
      const re = c.re[i] + (c.re[j] - c.re[i]) * t;
      const im = c.im[i] + (c.im[j] - c.im[i]) * t;
      sprite.rotation = Math.atan2(im, re);
      const tint = state === ASLEEP ? ASLEEP_TINT : AWAKE_TINT;
      if (this.tints[slot] !== tint) {
        this.tints[slot] = tint;
        sprite.tint = tint;
      }
    }
  }

  /** Creates the sprites of the slots the buffer gained since (pebbles appear with the frames). */
  private syncSprites(): void {
    while (this.sprites.length < this.buffer.slotCount) {
      const slot = this.sprites.length;
      const handle = this.buffer.handles[slot];
      const body = this.level.bodies.find((b) => b.handle === handle);
      const sprite = bodyGraphics(body, this.extent);
      sprite.visible = false;
      this.sprites.push(sprite);
      this.tints.push(AWAKE_TINT);
      this.world.addChildAt(sprite, this.world.children.length - 1); // below the overlay
    }
  }
}
