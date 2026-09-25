/** Frames per second of a trace: the replay runs at 60 Hz (docs/DESIGN.md D1). */
export const TICKS_PER_SECOND = 60;

/**
 * Playback position in fractional frame indices. Frames may still be arriving from the source,
 * so the position is clamped to the frames available now (`frameCount`), and playback stalls at
 * the newest one until more come.
 */
export class Playback {
  position = 0;
  playing = true;
  speed = 1;

  private readonly frameCount: () => number;

  constructor(frameCount: () => number) {
    this.frameCount = frameCount;
  }

  get lastFrame(): number {
    return Math.max(0, this.frameCount() - 1);
  }

  get atEnd(): boolean {
    return this.position >= this.lastFrame;
  }

  advance(deltaMs: number): void {
    if (!this.playing) return;
    this.seek(this.position + (deltaMs / 1000) * TICKS_PER_SECOND * this.speed);
  }

  seek(position: number): void {
    this.position = Math.min(Math.max(position, 0), this.lastFrame);
  }

  /** Play/pause; playing again from the end restarts the trace. */
  toggle(): void {
    if (!this.playing && this.atEnd) this.position = 0;
    this.playing = !this.playing;
  }
}
