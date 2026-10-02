import { Container } from 'pixi.js';
import { ABSENT, ASLEEP, TraceBuffer } from './buffer';
import { UNITS_PER_METRE, type Camera } from './camera';
import type { Effects } from './effects';
import { fixedToNumber, type TraceLevel } from '../trace/types';
import type { Skin } from './skin';

/** D12: the pebble is a ball of radius 0.25 m. */
export const PEBBLE_RADIUS_METRES = 0.25;

const AWAKE_TINT = 0xffffff;
/** A damaged body flashes red (`Effects`). */
const FLASH_TINT = 0xff6a5c;

const u = (metres: number): number => metres * UNITS_PER_METRE;

/**
 * The PixiJS scene of a trace: one view per body, from the skin (`render/skin/`), built once. `update`
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
  private readonly skin: Skin;
  private readonly extent: number;
  private readonly sprites: Container[] = [];
  private readonly tints: number[] = [];

  constructor(level: TraceLevel, buffer: TraceBuffer, skin: Skin) {
    this.level = level;
    this.skin = skin;
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

  /**
   * Draws the buffer at fractional frame index `position`; with `effects`, damaged bodies flash
   * and destroyed ones fade out at their last pose (`now`: display time, ms).
   */
  update(position: number, effects?: Effects, now = 0): void {
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
      let state = c.state[i];
      let f = i;
      let g = j;
      let alpha = 1;
      // A spent pebble (its shot ended) is gone like a destroyed body (D5).
      if (effects !== undefined && effects.spent(slot, i)) state = ABSENT;
      if (state === ABSENT && effects !== undefined) {
        // A destroyed body stays at its last pose while it fades.
        alpha = effects.fade(slot, now);
        f = g = alpha > 0 ? effects.fadePose(slot) : -1;
        if (f >= 0) state = c.state[f];
      }
      sprite.visible = state !== ABSENT && f >= 0;
      if (!sprite.visible) continue;
      if (sprite.alpha !== alpha) sprite.alpha = alpha;
      // A body gone at the next frame stays where it was until then.
      const t = c.state[g] === ABSENT ? 0 : a;
      sprite.position.set(u(c.x[f] + (c.x[g] - c.x[f]) * t), u(c.y[f] + (c.y[g] - c.y[f]) * t));
      const re = c.re[f] + (c.re[g] - c.re[f]) * t;
      const im = c.im[f] + (c.im[g] - c.im[f]) * t;
      sprite.rotation = Math.atan2(im, re);
      const tint =
        effects !== undefined && effects.flashing(slot, now) ? FLASH_TINT : state === ASLEEP ? this.skin.palette.asleep : AWAKE_TINT;
      if (this.tints[slot] !== tint) {
        this.tints[slot] = tint;
        sprite.tint = tint;
      }
    }
  }

  /** Removes the scene from the stage and frees its sprites (a new level or a retry). */
  destroy(): void {
    this.world.destroy({ children: true });
  }

  /** Creates the sprites of the slots the buffer gained since (pebbles appear with the frames). */
  private syncSprites(): void {
    while (this.sprites.length < this.buffer.slotCount) {
      const slot = this.sprites.length;
      const handle = this.buffer.handles[slot];
      const body = this.level.bodies.find((b) => b.handle === handle);
      const sprite = body ? this.skin.body(body, this.extent) : this.skin.pebble(PEBBLE_RADIUS_METRES);
      sprite.visible = false;
      this.sprites.push(sprite);
      this.tints.push(AWAKE_TINT);
      this.world.addChildAt(sprite, this.world.children.length - 1); // below the overlay
    }
  }
}
