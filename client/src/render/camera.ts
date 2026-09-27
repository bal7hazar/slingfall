import { fixedToNumber, type Shape, type TraceLevel } from '../trace/types';

/**
 * Pixi geometry is tessellated from its local coordinates, and a 0.25 m circle drawn in metres
 * gets a handful of segments. The scene therefore lives in centimetres and the camera scales it.
 */
export const UNITS_PER_METRE = 100;

/** World rectangle in metres, y up. */
export interface Rect {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

/** Screen x = offsetX + x * scale, screen y = offsetY - y * scale (`scale` in pixels per metre). */
export interface Camera {
  scale: number;
  offsetX: number;
  offsetY: number;
}

export interface Insets {
  top: number;
  bottom: number;
}

export function boundsOf(level: TraceLevel): Rect {
  const b = level.bounds;
  return {
    minX: fixedToNumber(b.min_x),
    minY: fixedToNumber(b.min_y),
    maxX: fixedToNumber(b.max_x),
    maxY: fixedToNumber(b.max_y),
  };
}

/** The largest camera that shows all of `bounds` inside the screen minus `insets`, centred. */
export function fitCamera(
  bounds: Rect,
  width: number,
  height: number,
  insets: Insets = { top: 0, bottom: 0 },
  margin = 0.03,
): Camera {
  const availableW = Math.max(1, width * (1 - 2 * margin));
  const availableH = Math.max(1, height - insets.top - insets.bottom - 2 * margin * height);
  const worldW = Math.max(bounds.maxX - bounds.minX, 1e-9);
  const worldH = Math.max(bounds.maxY - bounds.minY, 1e-9);
  const scale = Math.min(availableW / worldW, availableH / worldH);
  const centreX = (bounds.minX + bounds.maxX) / 2;
  const centreY = (bounds.minY + bounds.maxY) / 2;
  const areaCentreY = insets.top + (height - insets.top - insets.bottom) / 2;
  return { scale, offsetX: width / 2 - centreX * scale, offsetY: areaCentreY + centreY * scale };
}

export function worldToScreen(camera: Camera, x: number, y: number): { x: number; y: number } {
  return { x: camera.offsetX + x * camera.scale, y: camera.offsetY - y * camera.scale };
}

export function screenToWorld(camera: Camera, x: number, y: number): { x: number; y: number } {
  return { x: (x - camera.offsetX) / camera.scale, y: (camera.offsetY - y) / camera.scale };
}

/** World margin around the sling and the structures, metres. */
export const FRAME_MARGIN_METRES = 1.5;

/** `a` grown to contain `b`. */
export function union(a: Rect, b: Rect): Rect {
  return {
    minX: Math.min(a.minX, b.minX),
    minY: Math.min(a.minY, b.minY),
    maxX: Math.max(a.maxX, b.maxX),
    maxY: Math.max(a.maxY, b.maxY),
  };
}

/** `r` cut to `bounds` (the level's despawn box: nothing is ever drawn outside it). */
export function clampRect(r: Rect, bounds: Rect): Rect {
  const minX = Math.min(Math.max(r.minX, bounds.minX), bounds.maxX);
  const minY = Math.min(Math.max(r.minY, bounds.minY), bounds.maxY);
  return {
    minX,
    minY,
    maxX: Math.max(minX, Math.min(r.maxX, bounds.maxX)),
    maxY: Math.max(minY, Math.min(r.maxY, bounds.maxY)),
  };
}

/** Height of the ground under the sling: the highest upward half-space below the anchor (else 1 m below it). */
export function groundBelowAnchor(level: TraceLevel): number {
  const anchorY = fixedToNumber(level.sling_anchor.y);
  let ground = -Infinity;
  for (const body of level.bodies) {
    if (body.shape.type !== 'halfspace' || fixedToNumber(body.shape.normal.y) <= 0) continue;
    const y = fixedToNumber(body.pose.y);
    if (y <= anchorY && y > ground) ground = y;
  }
  return Number.isFinite(ground) ? ground : anchorY - 1;
}

/**
 * The part of the level worth framing: the sling (anchor down to the ground) and every body that
 * is not a half-space (bounding circles at the level pose), with `FRAME_MARGIN_METRES` around,
 * inside the level bounds. Not the bounds themselves: pile10's 60 x 50 m box made its pile 90 px
 * wide on a 1280 x 800 window (QA 2026-09-26, M5).
 */
export function frameRect(level: TraceLevel): Rect {
  const ax = fixedToNumber(level.sling_anchor.x);
  const ay = fixedToNumber(level.sling_anchor.y);
  let r: Rect = { minX: ax, minY: groundBelowAnchor(level), maxX: ax, maxY: ay };
  for (const body of level.bodies) {
    const reach = shapeReach(body.shape);
    if (reach === null) continue;
    const x = fixedToNumber(body.pose.x);
    const y = fixedToNumber(body.pose.y);
    r = union(r, { minX: x - reach, minY: y - reach, maxX: x + reach, maxY: y + reach });
  }
  const m = FRAME_MARGIN_METRES;
  return clampRect({ minX: r.minX - m, minY: r.minY - m, maxX: r.maxX + m, maxY: r.maxY + m }, boundsOf(level));
}

/** Radius of a body-local bounding circle; `null` for a half-space (unbounded). */
function shapeReach(shape: Shape): number | null {
  switch (shape.type) {
    case 'ball':
      return fixedToNumber(shape.radius);
    case 'cuboid':
      return Math.hypot(fixedToNumber(shape.hx), fixedToNumber(shape.hy));
    case 'polygon':
      return Math.max(0, ...shape.vertices.map((v) => Math.hypot(fixedToNumber(v.x), fixedToNumber(v.y))));
    case 'halfspace':
      return null;
  }
}

/**
 * The camera of `rect` that also keeps `padPx` pixels of screen around `anchor` (room for a full
 * drag in every direction, `fullPullPixels`). The pad in metres depends on the scale it produces,
 * so the rectangle is grown and refitted a few times (the scale only shrinks; three rounds leave
 * it within a pixel on the screens measured, `render.test.ts`).
 */
export function frameCamera(
  rect: Rect,
  anchor: { x: number; y: number },
  padPx: number,
  width: number,
  height: number,
  insets: Insets = { top: 0, bottom: 0 },
): Camera {
  let camera = fitCamera(rect, width, height, insets);
  for (let round = 0; round < 3; round++) {
    const pad = padPx / camera.scale;
    const grown = union(rect, { minX: anchor.x - pad, minY: anchor.y - pad, maxX: anchor.x + pad, maxY: anchor.y + pad });
    camera = fitCamera(grown, width, height, insets);
  }
  return camera;
}

/** Time constant of the camera's easing towards its target, ms. */
export const CAMERA_EASE_MS = 220;

/** `from` moved towards `to` over `deltaMs` (exponential easing, display only); snaps when close. */
export function easeCamera(from: Camera, to: Camera, deltaMs: number): Camera {
  const near =
    Math.abs(from.scale - to.scale) < 1e-3 * to.scale &&
    Math.abs(from.offsetX - to.offsetX) < 0.25 &&
    Math.abs(from.offsetY - to.offsetY) < 0.25;
  if (near) return to;
  const k = 1 - Math.exp(-Math.max(0, deltaMs) / CAMERA_EASE_MS);
  return {
    scale: from.scale + (to.scale - from.scale) * k,
    offsetX: from.offsetX + (to.offsetX - from.offsetX) * k,
    offsetY: from.offsetY + (to.offsetY - from.offsetY) * k,
  };
}
