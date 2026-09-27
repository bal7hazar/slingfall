// The live shot loop of one stage, without DOM or renderer: a release fires the shot in the
// worker, its frames stream into the buffer, the playback head follows them (slow motion when
// they lag, `render/live.ts`), and only once the head has SHOWN the shot's last frame, with the
// worker done, does the sling re-arm or the level's result come (QA 2026-09-26 M2, M3).
import type { Pull } from '../aim/pull';
import type { TraceBuffer } from '../render/buffer';
import { ArrivalRate, liveSpeed } from '../render/live';
import type { Playback } from '../render/playback';
import type { TraceFrame } from '../trace/types';
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
  private readonly rate = new ArrivalRate();
  /** A released shot whose last frame has not been shown yet. */
  private pending = false;
  private disposed = false;

  constructor(session: LevelSession, buffer: FrameSink, playback: Playback, hooks: ShotLoopHooks = {}, now = () => performance.now()) {
    this.session = session;
    this.buffer = buffer;
    this.playback = playback;
    this.hooks = hooks;
    this.now = now;
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
    this.rate.reset();
    this.playback.seek(this.playback.lastFrame);
    this.playback.playing = true;
    const fired = this.session.fire(pull, {
      onFrame: (frame: TraceFrame) => {
        if (this.disposed) return;
        this.rate.push(this.now());
        this.buffer.push(frame);
      },
    });
    this.hooks.released?.(pull);
    this.settled = fired.then(
      (report) => {
        this.producing = false;
        if (!this.disposed) this.hooks.produced?.(report);
        this.check();
      },
      (error: unknown) => {
        this.producing = false;
        this.pending = false;
        if (this.disposed) return;
        this.armed = true;
        this.hooks.failed?.(error);
      },
    );
    return true;
  }

  /**
   * One display frame: the head's speed from the lead and the arrival rate, the head moved by
   * `deltaMs` of display time, then the gate.
   */
  advance(deltaMs: number): void {
    if (this.disposed) return;
    const lead = this.buffer.frameCount - 1 - this.playback.position;
    this.playback.speed = liveSpeed(lead, this.producing, this.rate.fps(this.now()));
    this.playback.advance(deltaMs);
    this.check();
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
