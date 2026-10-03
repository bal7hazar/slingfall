import type { Graphics } from 'pixi.js';
import { UNITS_PER_METRE, groundBelowAnchor, worldToScreen, type Camera } from '../render/camera';
import { fixedToNumber, type TraceLevel } from '../trace/types';
import { FLAT_PALETTE } from '../render/skin/palette';
import type { Palette } from '../render/skin/types';
import { overlayShown } from '../game/orientation';
import { arcParamsFromLevel, flightArc, type ArcParams } from './arc';
import { nudgePull, pullFromDrag, pullToDrag, type Pull } from './pull';

/** How far from the anchor, in metres, a press still grabs the sling... */
const GRAB_RADIUS_METRES = 1.5;
/** ...and at least this many pixels: a finger's target on touch screens (44 px), less for a mouse. */
export const GRAB_MIN_PX_TOUCH = 44;
export const GRAB_MIN_PX_MOUSE = 22;
/** Pull units an arrow key moves the aim by; with Shift, `NUDGE_COARSE`. */
export const NUDGE_FINE = 1;
export const NUDGE_COARSE = 10;

/** The pebble's view when the skin gives one (a sprite): the controller only places it. */
export interface PebbleView {
  visible: boolean;
  alpha: number;
  position: { set(x: number, y: number): void };
}

const PEBBLE_RADIUS_METRES = 0.25;
/** The fork of the sling: its tips sit this far beside and above the anchor, metres. */
const FORK_HALF_WIDTH = 0.35;
const FORK_RISE = 0.25;
const FORK_DEPTH = 0.55;

const u = (metres: number): number => metres * UNITS_PER_METRE;

/** What the controller needs from the canvas (an `HTMLCanvasElement`; a fake in the tests). */
export interface PointerSurface {
  addEventListener(type: string, listener: (event: PointerEvent) => void): void;
  removeEventListener(type: string, listener: (event: PointerEvent) => void): void;
  getBoundingClientRect(): { left: number; top: number };
  setPointerCapture(pointerId: number): void;
}

/** Where key presses come from (`window`; a fake in the tests). */
export interface KeySurface {
  addEventListener(type: 'keydown', listener: (event: KeyboardEvent) => void): void;
  removeEventListener(type: 'keydown', listener: (event: KeyboardEvent) => void): void;
}

/** The pull delta of an arrow key (pull space, y up), `null` for any other key. */
export function arrowNudge(key: string, shift: boolean): { axis: 'x' | 'y'; step: number } | null {
  const size = shift ? NUDGE_COARSE : NUDGE_FINE;
  switch (key) {
    case 'ArrowLeft':
      return { axis: 'x', step: -size };
    case 'ArrowRight':
      return { axis: 'x', step: size };
    case 'ArrowUp':
      return { axis: 'y', step: size };
    case 'ArrowDown':
      return { axis: 'y', step: -size };
    default:
      return null;
  }
}

/** Keys typed into a form field are the field's, not the aim's. */
function typing(target: EventTarget | null): boolean {
  const element = target as { tagName?: string; type?: string } | null;
  const tag = element?.tagName;
  return tag === 'SELECT' || tag === 'TEXTAREA' || (tag === 'INPUT' && element?.type !== 'range');
}

/**
 * Aim UI: the sling at rest (posts, band, pebble), and the integer pull, set by a drag from the
 * pebble or by the arrow keys (one pull unit, Shift ten; Enter releases, Escape cancels), shown as
 * the exact flight arc (`flightArc`, BigInt Q32.32), one dot per tick until the first tick inside
 * a body's box. The drag is scaled to the screen, not to the world: a full pull is `fullPullPx`
 * pixels whatever the zoom. Release calls `onRelease` with the pull `onAim` showed last (the live
 * mode fires the shot, `src/game/`). The pull is opposite to the launch: drag back to shoot forward.
 */
export class AimController {
  private readonly canvas: PointerSurface;
  private readonly keys: KeySurface | undefined;
  private readonly camera: () => Camera;
  private readonly fullPullPx: () => number;
  private readonly graphics: Graphics;
  private readonly palette: Palette;
  private readonly pebble: PebbleView | undefined;
  private readonly params: ArcParams;
  private readonly radius: number;
  private readonly anchor: { x: number; y: number };
  private readonly ground: number;
  private readonly onAim: (pull: Pull | undefined) => void;
  private readonly onRelease: (pull: Pull) => void;
  private armed = true;
  private pull: Pull | undefined;
  /** The pull the arrow keys start from: the last one released (else (0, 0)). */
  private lastPull: Pull | undefined;
  private pointerId: number | undefined;
  /** Screen point of the press: the drag is measured from there, so a grab off-centre does not jump. */
  private press = { x: 0, y: 0 };

  constructor(options: {
    canvas: PointerSurface;
    keys?: KeySurface;
    camera: () => Camera;
    fullPullPx: () => number;
    graphics: Graphics;
    /** The skin's colours (default: the flat skin's). */
    palette?: Palette;
    /** The skin's pebble, shared look with the pebble in flight (default: a flat circle). */
    pebble?: PebbleView;
    level: TraceLevel;
    initialPull?: Pull;
    onAim?: (pull: Pull | undefined) => void;
    onRelease: (pull: Pull) => void;
  }) {
    this.canvas = options.canvas;
    this.keys = options.keys;
    this.camera = options.camera;
    this.fullPullPx = options.fullPullPx;
    this.graphics = options.graphics;
    this.palette = options.palette ?? FLAT_PALETTE;
    this.pebble = options.pebble;
    this.params = arcParamsFromLevel(options.level);
    this.radius = options.level.pull_radius;
    this.anchor = {
      x: fixedToNumber(options.level.sling_anchor.x),
      y: fixedToNumber(options.level.sling_anchor.y),
    };
    this.ground = groundBelowAnchor(options.level);
    this.lastPull = options.initialPull;
    this.onAim = options.onAim ?? (() => {});
    this.onRelease = options.onRelease;
    this.canvas.addEventListener('pointerdown', this.onDown);
    this.canvas.addEventListener('pointermove', this.onMove);
    this.canvas.addEventListener('pointerup', this.onUp);
    this.canvas.addEventListener('pointercancel', this.onCancel);
    this.keys?.addEventListener('keydown', this.onKey);
    this.draw();
  }

  dispose(): void {
    this.canvas.removeEventListener('pointerdown', this.onDown);
    this.canvas.removeEventListener('pointermove', this.onMove);
    this.canvas.removeEventListener('pointerup', this.onUp);
    this.canvas.removeEventListener('pointercancel', this.onCancel);
    this.keys?.removeEventListener('keydown', this.onKey);
  }

  /** Whether the sling is loaded: a grab, a key or a release does anything only then. */
  get enabled(): boolean {
    return this.armed;
  }

  set enabled(armed: boolean) {
    if (armed === this.armed) return;
    this.armed = armed;
    if (!armed) this.cancel();
    else this.draw();
  }

  /** The pull being aimed (`undefined` when not aiming). */
  get current(): Pull | undefined {
    return this.pull;
  }

  private screen(event: PointerEvent): { x: number; y: number } {
    const rect = this.canvas.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }

  private readonly onDown = (event: PointerEvent): void => {
    if (!this.armed || this.pointerId !== undefined) return;
    const p = this.screen(event);
    const camera = this.camera();
    const a = worldToScreen(camera, this.anchor.x, this.anchor.y);
    const min = event.pointerType === 'touch' ? GRAB_MIN_PX_TOUCH : GRAB_MIN_PX_MOUSE;
    if (Math.hypot(p.x - a.x, p.y - a.y) > Math.max(min, GRAB_RADIUS_METRES * camera.scale)) return;
    this.pointerId = event.pointerId;
    this.press = p;
    this.canvas.setPointerCapture(event.pointerId);
    this.aim({ x: 0, y: 0 });
  };

  private readonly onMove = (event: PointerEvent): void => {
    if (event.pointerId !== this.pointerId) return;
    const p = this.screen(event);
    // Screen y grows downwards, the pull's upwards.
    this.aim(pullFromDrag(p.x - this.press.x, this.press.y - p.y, this.radius, this.fullPullPx()));
  };

  private readonly onUp = (event: PointerEvent): void => {
    if (event.pointerId !== this.pointerId) return;
    this.pointerId = undefined;
    // A drag still going when the phone turned to portrait (game/orientation.ts) ends without a shot.
    if (overlayShown()) this.cancel();
    else this.release();
  };

  private readonly onCancel = (event: PointerEvent): void => {
    if (event.pointerId === this.pointerId) this.cancel();
  };

  private readonly onKey = (event: KeyboardEvent): void => {
    // The "rotate your phone" overlay (game/orientation.ts) stops the keys too: `inert` only stops the pointer.
    if (!this.armed || overlayShown() || this.pointerId !== undefined || typing(event.target)) return;
    const nudge = arrowNudge(event.key, event.shiftKey);
    if (nudge !== null) {
      event.preventDefault();
      const from = this.pull ?? this.lastPull ?? { x: 0, y: 0 };
      this.aim(nudgePull(from, nudge.axis, nudge.step, this.radius), true);
    } else if (event.key === 'Enter' && this.pull !== undefined) {
      event.preventDefault();
      this.release();
    } else if (event.key === 'Escape' && this.pull !== undefined) {
      this.cancel();
    }
  };

  /** Fires the pull shown (a zero pull only cancels). */
  private release(): void {
    const pull = this.pull;
    this.cancel();
    if (pull && (pull.x !== 0 || pull.y !== 0)) {
      this.lastPull = pull;
      console.log(`release: pull (${pull.x}, ${pull.y})`);
      this.onRelease(pull);
    }
  }

  private cancel(): void {
    this.pointerId = undefined;
    this.pull = undefined;
    this.onAim(undefined);
    this.draw();
  }

  private aim(pull: Pull, force = false): void {
    if (!force && this.pull && this.pull.x === pull.x && this.pull.y === pull.y) return;
    this.pull = pull;
    this.onAim(pull);
    this.draw();
  }

  /**
   * Redraws the overlay: the posts, and either the band and the pebble at rest (armed, not
   * aiming) or the stretched band, the pulled pebble and the arc. Call it again when the camera's
   * scale changes while aiming (the pulled pebble is placed in pixels).
   */
  draw(): void {
    const g = this.graphics;
    g.clear();
    if (this.pebble) this.pebble.visible = false;
    const { x: ax, y: ay } = this.anchor;
    const left = { x: ax - FORK_HALF_WIDTH, y: ay + FORK_RISE };
    const right = { x: ax + FORK_HALF_WIDTH, y: ay + FORK_RISE };
    const post = { width: u(0.12), color: this.palette.post, cap: 'round' as const };
    g.moveTo(u(ax), u(this.ground)).lineTo(u(ax), u(ay - FORK_DEPTH)).stroke(post);
    g.moveTo(u(left.x), u(left.y)).lineTo(u(ax), u(ay - FORK_DEPTH)).lineTo(u(right.x), u(right.y)).stroke(post);
    const pull = this.pull;
    if (!pull) {
      if (!this.armed) return;
      const band = { width: u(0.05), color: this.palette.band };
      g.moveTo(u(left.x), u(left.y)).lineTo(u(ax), u(ay)).lineTo(u(right.x), u(right.y)).stroke(band);
      this.placePebble(u(ax), u(ay), 1);
      return;
    }

    const scale = this.camera().scale;
    const drag = pullToDrag(pull, this.radius, this.fullPullPx());
    const px = u(ax + drag.dx / scale);
    const py = u(ay + drag.dy / scale);
    const band = { width: u(0.05), color: this.palette.band };
    g.moveTo(u(left.x), u(left.y)).lineTo(px, py).lineTo(u(right.x), u(right.y)).stroke(band);
    this.placePebble(px, py, 0.85);

    if (pull.x === 0 && pull.y === 0) return;
    const arc = flightArc(this.params, pull);
    for (const point of arc) {
      g.circle(u(fixedToNumber(point.x.toString())), u(fixedToNumber(point.y.toString())), u(0.05));
    }
    g.fill({ color: this.palette.dot, alpha: 0.85 });
  }

  /** The pebble at the sling: the skin's view, else a flat circle on the overlay. */
  private placePebble(x: number, y: number, alpha: number): void {
    if (this.pebble) {
      this.pebble.position.set(x, y);
      this.pebble.alpha = alpha;
      this.pebble.visible = true;
    } else {
      this.graphics.circle(x, y, u(PEBBLE_RADIUS_METRES)).fill({ color: this.palette.pebble, alpha });
    }
  }
}
