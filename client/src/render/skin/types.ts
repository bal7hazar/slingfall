import type { Container } from 'pixi.js';
import type { LevelBody } from '../../trace/types';

/**
 * Colours the page and the sling take from the skin (0xRRGGBB, CSS strings for the page). Plain
 * data, so modules that keep PixiJS out of their imports (`aim/controller.ts`) can use it.
 */
export interface Palette {
  /** Page and canvas background (CSS colour). */
  page: string;
  /** Text over the page (CSS colour): the HUD sits straight on the playfield. */
  text: string;
  /** The sling's posts and fork. */
  post: number;
  /** The band. */
  band: number;
  /** The dots of the aim arc. */
  dot: number;
  /** Tint of a sleeping body (white: none). */
  asleep: number;
  /** The pebble, where the skin draws it as a flat circle (the controller's fallback). */
  pebble: number;
}

/** A backdrop behind the world, in screen pixels; `resize` lays it out for the canvas. */
export interface Backdrop {
  readonly view: Container;
  resize(width: number, height: number): void;
}

/**
 * Every visual choice of the renderer sits behind this interface (docs/briefs/m6-art-kenney.md):
 * `scene.ts`, `effects.ts` and the aim controller call nothing else, so swapping the art touches one
 * folder. The world is y-flipped (`Scene.setCamera`): a skin counter-flips what has an up (sprites).
 *
 * The scene positions, rotates, tints and fades the returned views, and never touches their scale.
 */
export interface Skin {
  readonly name: string;
  readonly palette: Palette;
  /**
   * The view of one level body in its local frame (scene units: centimetres, y up, origin at the body's
   * pose): blocks by material and size, cores, the ground half-plane, any other shape.
   */
  body(body: LevelBody, extent: number): Container;
  /** The pebble, at the sling and in flight, of radius `radiusMetres`. */
  pebble(radiusMetres: number): Container;
  /** The backdrop behind the world; `undefined` for the page colour alone. */
  background(): Backdrop | undefined;
}
