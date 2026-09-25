import { Graphics } from 'pixi.js';
import { UNITS_PER_METRE, screenToWorld, type Camera } from '../render/camera';
import { fixedToNumber, type TraceLevel } from '../trace/types';
import { arcParamsFromLevel, flightArc, type ArcParams } from './arc';
import { pullFromDrag, pullToDrag, type Pull } from './pull';

/** How far from the anchor, in metres, a press still grabs the sling. */
const GRAB_RADIUS_METRES = 1.5;

const BAND_COLOUR = 0xc9b28a;
const DOT_COLOUR = 0xffffff;
const ANCHOR_COLOUR = 0x8a6a3c;

const u = (metres: number): number => metres * UNITS_PER_METRE;

/**
 * Aim UI: drag from the sling anchor to set the integer pull, shown as the exact flight arc
 * (`flightArc`, BigInt Q32.32), one dot per tick. Release calls `onRelease` with the pull (the
 * live mode fires the shot, `src/game/`). The pull is opposite to the launch: drag back to shoot forward.
 */
export class AimController {
  private readonly canvas: HTMLElement;
  private readonly camera: () => Camera;
  private readonly graphics: Graphics;
  private readonly params: ArcParams;
  private readonly radius: number;
  private readonly anchor: { x: number; y: number };
  private readonly onRelease: (pull: Pull) => void;
  private pull: Pull | undefined;
  private pointerId: number | undefined;

  constructor(options: {
    canvas: HTMLElement;
    camera: () => Camera;
    graphics: Graphics;
    level: TraceLevel;
    onRelease: (pull: Pull) => void;
  }) {
    this.canvas = options.canvas;
    this.camera = options.camera;
    this.graphics = options.graphics;
    this.params = arcParamsFromLevel(options.level);
    this.radius = options.level.pull_radius;
    this.anchor = {
      x: fixedToNumber(options.level.sling_anchor.x),
      y: fixedToNumber(options.level.sling_anchor.y),
    };
    this.onRelease = options.onRelease;
    this.canvas.addEventListener('pointerdown', this.onDown);
    this.canvas.addEventListener('pointermove', this.onMove);
    this.canvas.addEventListener('pointerup', this.onUp);
    this.canvas.addEventListener('pointercancel', this.onCancel);
    this.draw();
  }

  dispose(): void {
    this.canvas.removeEventListener('pointerdown', this.onDown);
    this.canvas.removeEventListener('pointermove', this.onMove);
    this.canvas.removeEventListener('pointerup', this.onUp);
    this.canvas.removeEventListener('pointercancel', this.onCancel);
  }

  private world(event: PointerEvent): { x: number; y: number } {
    const rect = this.canvas.getBoundingClientRect();
    return screenToWorld(this.camera(), event.clientX - rect.left, event.clientY - rect.top);
  }

  private readonly onDown = (event: PointerEvent): void => {
    const p = this.world(event);
    if (Math.hypot(p.x - this.anchor.x, p.y - this.anchor.y) > GRAB_RADIUS_METRES) return;
    this.pointerId = event.pointerId;
    this.canvas.setPointerCapture(event.pointerId);
    this.aim(p);
  };

  private readonly onMove = (event: PointerEvent): void => {
    if (event.pointerId === this.pointerId) this.aim(this.world(event));
  };

  private readonly onUp = (event: PointerEvent): void => {
    if (event.pointerId !== this.pointerId) return;
    const pull = this.pull;
    this.cancel();
    if (pull && (pull.x !== 0 || pull.y !== 0)) {
      console.log(`release: pull (${pull.x}, ${pull.y})`);
      this.onRelease(pull);
    }
  };

  private readonly onCancel = (event: PointerEvent): void => {
    if (event.pointerId === this.pointerId) this.cancel();
  };

  private cancel(): void {
    this.pointerId = undefined;
    this.pull = undefined;
    this.draw();
  }

  private aim(p: { x: number; y: number }): void {
    const pull = pullFromDrag(p.x - this.anchor.x, p.y - this.anchor.y, this.radius);
    if (this.pull && this.pull.x === pull.x && this.pull.y === pull.y) return;
    this.pull = pull;
    this.draw();
  }

  /** Redraws the overlay: the anchor post, and while dragging the band, the pebble and the arc. */
  draw(): void {
    const g = this.graphics;
    g.clear();
    g.circle(u(this.anchor.x), u(this.anchor.y), u(0.1)).fill(ANCHOR_COLOUR);
    const pull = this.pull;
    if (!pull) return;

    const drag = pullToDrag(pull, this.radius);
    const px = u(this.anchor.x + drag.dx);
    const py = u(this.anchor.y + drag.dy);
    g.moveTo(u(this.anchor.x), u(this.anchor.y)).lineTo(px, py).stroke({ width: u(0.05), color: BAND_COLOUR });
    g.circle(px, py, u(0.25)).fill({ color: DOT_COLOUR, alpha: 0.35 });

    const arc = flightArc(this.params, pull);
    for (const point of arc) {
      g.circle(u(fixedToNumber(point.x.toString())), u(fixedToNumber(point.y.toString())), u(0.05));
    }
    g.fill({ color: DOT_COLOUR, alpha: 0.85 });
  }
}
