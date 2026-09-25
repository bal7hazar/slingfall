import { fixedToNumber, type TraceLevel } from '../trace/types';

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
