import { Container, Graphics, type Application } from 'pixi.js';
import { AimController } from '../aim/controller';
import { fullPullPixels, type Pull } from '../aim/pull';
import { TraceBuffer } from '../render/buffer';
import type { Insets } from '../render/camera';
import { Effects } from '../render/effects';
import { CameraRig } from '../render/follow';
import { PEBBLE_RADIUS_METRES, Scene } from '../render/scene';
import type { Backdrop, Skin } from '../render/skin';
import type { TraceEvent, TraceLevel } from '../trace/types';

export interface StageOptions {
  /** The art: every visual choice of the stage (`render/skin/`). */
  skin: Skin;
  insets: Insets;
  /** Where the arrow keys come from (the window), for fine aiming. */
  keys?: Window;
  /** Where the arrow keys start (the last pull released before a Retry). */
  initialPull?: Pull;
  onAim?: (pull: Pull | undefined) => void;
  onRelease: (pull: Pull) => void;
}

/**
 * What one level (or one retry) draws: the frame buffer, the PixiJS scene, the effects of the
 * events, the camera and the aim. Built once per level or retry, never per frame. The camera
 * (`CameraRig`) frames the sling and the structures, with room for a full drag around the
 * anchor, and zooms out, eased, to follow a pebble in flight.
 */
export class Stage {
  readonly level: TraceLevel;
  readonly buffer: TraceBuffer;
  readonly scene: Scene;
  readonly effects: Effects;
  readonly aim: AimController;
  readonly rig: CameraRig;
  private readonly app: Application;
  private readonly insets: Insets;
  private readonly backdrop: Backdrop | undefined;
  private shownFrame = 0;
  private readonly onResize = () => {
    this.backdrop?.resize(this.app.screen.width, this.app.screen.height);
    this.rig.snap(this.shownFrame, this.effects);
    this.applyCamera(true);
  };

  constructor(app: Application, level: TraceLevel, events: readonly TraceEvent[], options: StageOptions) {
    this.app = app;
    this.level = level;
    this.insets = options.insets;
    this.buffer = new TraceBuffer(level);
    this.scene = new Scene(level, this.buffer, options.skin);
    this.effects = new Effects(this.buffer, events);
    this.backdrop = options.skin.background();
    if (this.backdrop) {
      this.backdrop.resize(app.screen.width, app.screen.height);
      app.stage.addChild(this.backdrop.view);
    }
    app.stage.addChild(this.scene.world);
    this.rig = new CameraRig(level, this.buffer, () => app.screen, this.insets, () => this.fullPullPx());
    this.scene.setCamera(this.rig.camera);
    const aimLayer = new Graphics();
    const pebble: Container = options.skin.pebble(PEBBLE_RADIUS_METRES);
    this.scene.overlay.addChild(aimLayer, pebble);
    this.aim = new AimController({
      canvas: app.canvas,
      keys: options.keys,
      camera: () => this.rig.camera,
      fullPullPx: () => this.fullPullPx(),
      graphics: aimLayer,
      palette: options.skin.palette,
      pebble,
      level,
      initialPull: options.initialPull,
      onAim: options.onAim,
      onRelease: options.onRelease,
    });
    app.renderer.on('resize', this.onResize);
  }

  /** Whether a release fires (false from a release until its shot has been shown, and once the level is over). */
  get armed(): boolean {
    return this.aim.enabled;
  }

  set armed(armed: boolean) {
    this.aim.enabled = armed;
  }

  /** Pixels of a full pull on this screen (`FULL_PULL_SHARE` of its short side), whatever the zoom. */
  fullPullPx(): number {
    const { width, height } = this.app.screen;
    return fullPullPixels(width, height);
  }

  /** Draws fractional frame `position` at display time `now`; the camera eases over `deltaMs`. */
  update(position: number, deltaMs: number, now: number): void {
    const { buffer, effects } = this;
    const frame = Math.min(Math.floor(position), Math.max(0, buffer.frameCount - 1));
    this.shownFrame = frame;
    if (buffer.frameCount > 0) effects.advance(buffer.ticks[frame], frame, now);
    const scale = this.rig.camera.scale;
    if (this.rig.step(frame, deltaMs, effects)) this.applyCamera(this.rig.camera.scale !== scale);
    this.scene.update(position, effects, now);
  }

  destroy(): void {
    this.aim.dispose();
    this.app.renderer.off('resize', this.onResize);
    if (this.backdrop) {
      this.app.stage.removeChild(this.backdrop.view);
      this.backdrop.view.destroy({ children: true });
    }
    this.app.stage.removeChild(this.scene.world);
    this.scene.destroy();
  }

  private applyCamera(rescaled: boolean): void {
    this.scene.setCamera(this.rig.camera);
    // The pulled pebble sits a fixed number of pixels from the anchor: redraw it on a new scale.
    if (rescaled && this.aim.current !== undefined) this.aim.draw();
  }
}
