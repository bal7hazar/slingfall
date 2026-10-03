import { Container } from 'pixi.js';
import { ABSENT, ASLEEP, TraceBuffer } from './buffer';
import { UNITS_PER_METRE, type Camera } from './camera';
import type { Effects } from './effects';
import { fixedToNumber, type TraceLevel } from '../trace/types';
import type { Skin } from './skin';

/** Display-only debris of a destroyed body: thrown up and out, falls under gravity, fades (scene units, s). */
interface Piece {
  view: Container;
  x: number;
  y: number;
  vx: number;
  vy: number;
  spin: number;
  born: number;
}
const DEBRIS_PIECES = 3;
const DEBRIS_LIFE_MS = 900;
const DEBRIS_GRAVITY = 980;

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
  private readonly worn: boolean[] = [];
  /** `Effects.fadeStart` of the last destruction that threw debris, per slot. */
  private readonly burst: number[] = [];
  private readonly pieces: Piece[] = [];
  private readonly debrisLayer = new Container();
  private seed = 1;

  constructor(level: TraceLevel, buffer: TraceBuffer, skin: Skin) {
    this.level = level;
    this.skin = skin;
    this.buffer = buffer;
    const b = level.bounds;
    const w = fixedToNumber(b.max_x) - fixedToNumber(b.min_x);
    const h = fixedToNumber(b.max_y) - fixedToNumber(b.min_y);
    this.extent = u(Math.hypot(w, h));
    this.world.addChild(this.debrisLayer, this.overlay);
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
    this.moveDebris(now);
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
      if (effects !== undefined) {
        const worn = effects.worn(slot);
        if (this.worn[slot] !== worn) {
          this.worn[slot] = worn;
          this.skin.wear?.(sprite, worn);
        }
        this.throwDebris(slot, effects, sprite, now);
      }
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

  /** Debris from where a body was destroyed, once per destruction (`Effects.fadeStart` changes). */
  private throwDebris(slot: number, effects: Effects, at: Container, now: number): void {
    const start = effects.fadeStart(slot);
    if (start === this.burst[slot]) return;
    this.burst[slot] = start;
    const body = slot < this.buffer.levelSlotCount ? this.level.bodies.find((b) => b.handle === this.buffer.handles[slot]) : undefined;
    if (body === undefined || start === -Infinity || !this.skin.debris) return;
    for (let i = 0; i < DEBRIS_PIECES; i++) {
      const view = this.skin.debris(body.material, i);
      const r1 = this.random();
      const r2 = this.random();
      view.position.copyFrom(at.position);
      this.debrisLayer.addChild(view);
      this.pieces.push({ view, x: at.x, y: at.y, vx: (r1 - 0.5) * 500, vy: 150 + r2 * 250, spin: (r1 - r2) * 8, born: now });
    }
  }

  /** Moves the debris along its fall and drops what has faded. */
  private moveDebris(now: number): void {
    for (let i = this.pieces.length - 1; i >= 0; i--) {
      const p = this.pieces[i];
      const age = (now - p.born) / 1000;
      if (age < 0 || age * 1000 >= DEBRIS_LIFE_MS) {
        p.view.destroy();
        this.pieces.splice(i, 1);
        continue;
      }
      p.view.position.set(p.x + p.vx * age, p.y + p.vy * age - 0.5 * DEBRIS_GRAVITY * age * age);
      p.view.rotation = p.spin * age;
      p.view.alpha = 1 - (age * 1000) / DEBRIS_LIFE_MS;
    }
  }

  /** A small deterministic generator (display only): the same trace throws the same debris. */
  private random(): number {
    this.seed = (this.seed * 1664525 + 1013904223) >>> 0;
    return this.seed / 2 ** 32;
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
      this.worn.push(false);
      this.burst.push(-Infinity);
      this.world.addChildAt(sprite, this.world.children.length - 1); // below the overlay
    }
  }
}
