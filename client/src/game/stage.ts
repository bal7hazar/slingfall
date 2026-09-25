import { Graphics, type Application } from 'pixi.js';
import { AimController } from '../aim/controller';
import type { Pull } from '../aim/pull';
import { TraceBuffer } from '../render/buffer';
import { boundsOf, fitCamera, type Camera, type Insets } from '../render/camera';
import { Effects } from '../render/effects';
import { Scene } from '../render/scene';
import type { TraceEvent, TraceLevel } from '../trace/types';

/**
 * What one level (or one retry) draws: the frame buffer, the PixiJS scene, the effects of the
 * events, the camera and the aim. Built once per level or retry, never per frame.
 */
export class Stage {
  readonly level: TraceLevel;
  readonly buffer: TraceBuffer;
  readonly scene: Scene;
  readonly effects: Effects;
  readonly aim: AimController;
  /** Whether a release fires (false while a shot is in flight or the level is over). */
  armed = true;
  private camera: Camera;
  private readonly app: Application;
  private readonly insets: Insets;
  private readonly onResize = (width: number, height: number) => this.fit(width, height);

  constructor(app: Application, level: TraceLevel, events: readonly TraceEvent[], insets: Insets, onRelease: (pull: Pull) => void) {
    this.app = app;
    this.level = level;
    this.insets = insets;
    this.buffer = new TraceBuffer(level);
    this.scene = new Scene(level, this.buffer);
    this.effects = new Effects(this.buffer, events);
    app.stage.addChild(this.scene.world);
    this.camera = fitCamera(boundsOf(level), app.screen.width, app.screen.height, insets);
    this.scene.setCamera(this.camera);
    const aimLayer = new Graphics();
    this.scene.overlay.addChild(aimLayer);
    this.aim = new AimController({
      canvas: app.canvas,
      camera: () => this.camera,
      graphics: aimLayer,
      level,
      onRelease: (pull) => {
        if (this.armed) onRelease(pull);
      },
    });
    app.renderer.on('resize', this.onResize);
  }

  destroy(): void {
    this.aim.dispose();
    this.app.renderer.off('resize', this.onResize);
    this.app.stage.removeChild(this.scene.world);
    this.scene.destroy();
  }

  private fit(width: number, height: number): void {
    this.camera = fitCamera(boundsOf(this.level), width, height, this.insets);
    this.scene.setCamera(this.camera);
  }
}
