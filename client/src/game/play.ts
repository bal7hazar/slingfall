// The live shot loop of one stage, without DOM or renderer: a release fires the shot in the
// worker, its frames stream into the buffer, the playback head holds until the shot can be
// produced faster than it plays (`render/live.ts`, lot CB), then runs at real time to the end; only
// once the head has SHOWN the shot's last frame, with the worker done, does the sling re-arm or the
// level's result come (QA 2026-09-26 M2, M3).
import type { Pull } from '../aim/pull';
import type { TraceBuffer } from '../render/buffer';
import { expectedShotTicks, ProductionModel, shouldStart } from '../render/live';
import type { Playback } from '../render/playback';
import type { TraceFrame } from '../trace/types';
import { levelInfo } from '../vm/program';
import type { ChunkReport } from '../vm/shot';
import type { LevelSession, ShotReport } from './session';

export interface ShotLoopHooks {
  /** A shot was released (the HUD counts it spent from now). */
  released?(pull: Pull): void;
  /** The worker finished the shot; its end is not necessarily shown yet. */
  produced?(report: ShotReport): void;
  /** The shot failed in the worker; the sling is armed again. */
  failed?(error: unknown): void;
  /** The shot has been shown to its last frame and the level goes on: the sling is armed. */
  armed?(): void;
  /** The shot has been shown to its last frame and the level is over: the result panel. */
  over?(): void;
}

/** Where the frames go: the stage's buffer (only `push` and `frameCount` are used). */
export type FrameSink = Pick<TraceBuffer, 'push' | 'frameCount'>;

/** Where the loop logs its chunks and its dry events (the console; a sink in the tests). */
export type LogSink = Pick<Console, 'info' | 'warn'>;

export class ShotLoop {
  /** The sling fires on release (the previous shot has been shown and the level goes on). */
  armed: boolean;
  /** The worker is producing frames for this loop. */
  producing = false;
  /** Settles when the worker is done with the current shot (tests await it). */
  settled: Promise<void> = Promise.resolve();

  private readonly session: LevelSession;
  private readonly buffer: FrameSink;
  private readonly playback: Playback;
  private readonly hooks: ShotLoopHooks;
  private readonly now: () => number;
  private readonly log: LogSink;
  private model = new ProductionModel();
  /** The head holds (speed 0) until `shouldStart` says so, or the worker is done. */
  private holding = false;
  private expectedTicks = 0;
  /** The head caught up with the frames while the worker is still producing (logged once per run-dry). */
  private dry = false;
  /** Run-dry events of the shots so far. */
  dryEvents = 0;
  /** A released shot whose last frame has not been shown yet. */
  private pending = false;
  private disposed = false;

  constructor(session: LevelSession, buffer: FrameSink, playback: Playback, hooks: ShotLoopHooks = {}, now = () => performance.now(), log: LogSink = console) {
    this.session = session;
    this.buffer = buffer;
    this.playback = playback;
    this.hooks = hooks;
    this.now = now;
    this.log = log;
    this.armed = session.phase === 'aiming';
  }

  /** Retry or another level may replace the stage once the worker is idle. */
  get canLeave(): boolean {
    return !this.producing;
  }

  /**
   * Fires `pull` if the sling is armed: the head jumps to the newest frame (a player who
   * scrubbed back sees the new shot at once) and plays. Returns whether the shot was fired.
   */
  release(pull: Pull): boolean {
    if (!this.armed || this.disposed || this.session.phase !== 'aiming') return false;
    this.armed = false;
    this.pending = true;
    this.producing = true;
    this.model = new ProductionModel();
    this.holding = true;
    this.dry = false;
    const info = levelInfo(this.session.level);
    this.expectedTicks = expectedShotTicks(Number(this.session.level.felts[1]), info.tickCap, 0);
    this.playback.seek(this.playback.lastFrame);
    this.playback.playing = true;
    this.playback.speed = 0;
    const fired = this.session.fire(pull, {
      onFrame: (frame: TraceFrame) => {
        if (this.disposed) return;
        this.buffer.push(frame);
      },
      onChunk: (chunk: ChunkReport) => this.onChunk(chunk),
    });
    this.hooks.released?.(pull);
    this.settled = fired.then(
      (report) => {
        this.producing = false;
        this.holding = false;
        if (!this.disposed) this.hooks.produced?.(report);
        this.check();
      },
      (error: unknown) => {
        this.producing = false;
        this.holding = false;
        this.pending = false;
        if (this.disposed) return;
        this.armed = true;
        this.hooks.failed?.(error);
      },
    );
    return true;
  }

  /**
   * One display frame: the head holds (speed 0) until the shot can be produced faster than it
   * plays, then runs at real time and never slows down; if the lead runs dry, the head waits on
   * the last frame at speed 1 (`Playback.advance` clamps) and the event is logged. Then the head
   * moves by `deltaMs` of display time, then the gate.
   */
  advance(deltaMs: number): void {
    if (this.disposed) return;
    if (this.holding && (!this.producing || this.startable())) this.holding = false;
    this.playback.speed = this.holding ? 0 : 1;
    this.playback.advance(deltaMs);
    this.watchDry();
    this.check();
  }

  /** The chunk's figures go to the log and the production model (`init` and `outputs` run no tick). */
  private onChunk(chunk: ChunkReport): void {
    if (this.disposed || !(chunk.ticks > 0)) return;
    const met = this.model.push(chunk);
    this.log.info(`chunk ${chunk.index}: ${chunk.ticks} ticks, ${chunk.steps} steps, ${chunk.ms.toFixed(1)} ms${met ? ' (contact)' : ''}`);
  }

  private startable(): boolean {
    const m = this.model;
    return shouldStart({
      produced: m.produced,
      shown: Math.floor(this.playback.position),
      expectedTicks: this.expectedTicks,
      stepsPerSecond: m.stepsPerSecond,
      flightStepsPerTick: m.flightStepsPerTick,
      postContactStepsPerTick: m.postContactStepsPerTick,
    });
  }

  /** A started head on the last frame with the worker still producing: the prediction was wrong. */
  private watchDry(): void {
    const dry = !this.holding && this.producing && this.playback.playing && this.playback.position >= this.playback.lastFrame;
    if (dry && !this.dry) {
      this.dryEvents++;
      const m = this.model;
      this.log.warn(
        `lead ran dry at ${this.now().toFixed(0)} ms: ${m.produced} ticks produced of ~${this.expectedTicks} expected, head at ${this.playback.position.toFixed(1)}, ` +
          `${(m.stepsPerSecond / 1e6).toFixed(2)}M steps/s, flight ${m.flightStepsPerTick.toFixed(0)} steps/tick, ` +
          `post-contact ${m.postContactStepsPerTick?.toFixed(0) ?? 'none'} steps/tick`,
      );
    }
    this.dry = dry;
  }

  /** Stops every hook (Retry, another level): a shot still settling changes nothing any more. */
  dispose(): void {
    this.disposed = true;
  }

  /** The shot is shown when the worker is done and the head is on the last frame. */
  private check(): void {
    if (!this.pending || this.producing || this.disposed) return;
    if (this.playback.position < this.playback.lastFrame) return;
    this.pending = false;
    if (this.session.phase === 'over') {
      this.hooks.over?.();
    } else {
      this.armed = true;
      this.hooks.armed?.();
    }
  }
}
