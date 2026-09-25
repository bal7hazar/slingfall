// The shot loop of one level (docs/DESIGN.md D1, D8), without DOM or renderer: `init` once in
// the worker, then per release the chunks of that shot from the previous shot's state, the
// inputs so far kept, until the state header says the level is over; then the D4 outputs.
import { LevelHeader, parseTraceLine, startFrame } from '../trace/lines.ts';
import type { TraceEvent, TraceFrame, TraceLevel } from '../trace/types';
import type { Pull } from '../aim/pull';
import {
  DEFAULT_PLAYER,
  decodeOutputs,
  readChunkHeader,
  type ChunkHeader,
  type Outputs,
  type ShotInput,
  type SlingfallInputs,
  type SlingfallLevel,
} from '../vm/program.ts';
import type { ShotHandlers, VmClient } from '../vm/index';
import type { ChunkReport } from '../vm/shot';

/** What the session needs from the worker (`VmClient`; a fake in the tests). */
export type GameVm = Pick<VmClient, 'init' | 'shot' | 'outputs'>;

export type Phase = 'aiming' | 'flying' | 'over';

/** Figures of one shot, from the release to its last chunk. */
export interface ShotReport {
  shot: number;
  pull: Pull;
  /** Release to the first frame, ms (budget 500 ms). */
  firstFrameMs: number | null;
  /** Release to the end of the shot, ms. */
  ms: number;
  ticks: number;
  steps: number;
  chunks: ChunkReport[];
}

/** The level's end as the state header tells it; `won` from the events (every core destroyed). */
export interface LevelResult {
  score: number;
  won: boolean;
  shotsUsed: number;
  ticks: number;
}

export interface SessionOptions {
  player?: string;
  now?: () => number;
}

/** Won: every core of the level has a `destroyed` event (D7; a core out of bounds counts). */
export function coresDestroyed(level: TraceLevel, events: readonly TraceEvent[]): boolean {
  const cores = level.bodies.filter((b) => b.kind === 'core').map((b) => b.handle);
  const destroyed = new Set(events.filter((e) => e.kind === 'destroyed').map((e) => e.handle));
  return cores.length > 0 && cores.every((h) => destroyed.has(h));
}

export class LevelSession {
  readonly level: SlingfallLevel;
  /** The level as `init` printed it: what the renderer draws and the aim reads. */
  readonly traceLevel: TraceLevel;
  /** Every event of the level so far, in order. */
  readonly events: TraceEvent[] = [];
  readonly shots: ShotInput[] = [];
  readonly reports: ShotReport[] = [];
  phase: Phase = 'aiming';
  state: string[];
  header: ChunkHeader;

  private readonly vm: GameVm;
  private readonly initState: string[];
  private readonly player: string;
  private readonly now: () => number;
  private outputsPromise: Promise<Outputs> | null = null;

  private constructor(vm: GameVm, level: SlingfallLevel, traceLevel: TraceLevel, state: string[], options: SessionOptions) {
    this.vm = vm;
    this.level = level;
    this.traceLevel = traceLevel;
    this.initState = state;
    this.state = state;
    this.header = readChunkHeader(state);
    this.player = options.player ?? DEFAULT_PLAYER;
    this.now = options.now ?? (() => performance.now());
  }

  /** Runs `init(level)` once and reads the level from its header lines. */
  static async open(vm: GameVm, level: SlingfallLevel, options: SessionOptions = {}): Promise<LevelSession> {
    const header = new LevelHeader();
    const init = await vm.init(level, {
      onLine: (line) => {
        const parsed = parseTraceLine(line);
        if (parsed !== null) header.push(parsed);
      },
    });
    return new LevelSession(vm, level, header.level(), init.state, options);
  }

  /** The tick-0 frame (every dynamic body asleep at its level pose). */
  startFrame(): TraceFrame {
    return startFrame(this.traceLevel);
  }

  /** `Inputs` of the shots played (or in flight). */
  inputs(): SlingfallInputs {
    return { player: this.player, shots: this.shots };
  }

  /**
   * Plays one shot from the current state: frames and events stream to `handlers` while the
   * chunks run. Resolves at the end of the shot.
   */
  async fire(pull: Pull, handlers: ShotHandlers = {}, delay = 0): Promise<ShotReport> {
    if (this.phase !== 'aiming') throw new Error(`cannot shoot while ${this.phase}`);
    const shot = this.header.shotsUsed;
    this.phase = 'flying';
    this.shots.push({ pull_x: pull.x, pull_y: pull.y, delay });
    const t0 = this.now();
    let firstFrameMs: number | null = null;
    let ticks = 0;
    try {
      const result = await this.vm.shot(
        { level: this.level, inputs: this.inputs(), shot, state: this.state },
        {
          ...handlers,
          onFrame: (frame) => {
            firstFrameMs ??= this.now() - t0;
            ticks++;
            handlers.onFrame?.(frame);
          },
          onEvent: (event) => {
            this.events.push(event);
            handlers.onEvent?.(event);
          },
        },
      );
      this.state = result.state;
      this.header = readChunkHeader(result.state);
      const report: ShotReport = {
        shot,
        pull,
        firstFrameMs,
        ms: this.now() - t0,
        ticks,
        steps: result.steps,
        chunks: result.chunks,
      };
      this.reports.push(report);
      this.phase = this.header.over ? 'over' : 'aiming';
      return report;
    } catch (e) {
      // The shot did not happen: back to the state before it.
      this.shots.pop();
      this.phase = 'aiming';
      throw e;
    }
  }

  /** The result once the level is over, else `null`. */
  result(): LevelResult | null {
    if (this.phase !== 'over') return null;
    const { score, shotsUsed, tick } = this.header;
    return { score, won: coresDestroyed(this.traceLevel, this.events), shotsUsed, ticks: tick };
  }

  /** The D4 outputs of the finished level (one `outputs` run, cached). */
  outputs(): Promise<Outputs> {
    if (this.phase !== 'over') return Promise.reject(new Error('the level is not over'));
    this.outputsPromise ??= this.vm.outputs(this.state, this.inputs()).then((r) => decodeOutputs(r.state));
    return this.outputsPromise;
  }

  /** Back to the state `init` returned (no new `init` run). */
  reset(): void {
    if (this.phase === 'flying') throw new Error('cannot reset while a shot is in flight');
    this.state = this.initState;
    this.header = readChunkHeader(this.initState);
    this.events.length = 0;
    this.shots.length = 0;
    this.reports.length = 0;
    this.outputsPromise = null;
    this.phase = 'aiming';
  }
}

/** The "copy inputs" document: the shots as the replay takes them (D3). */
export function inputsJson(inputs: SlingfallInputs): string {
  return JSON.stringify({ player: inputs.player, shots: inputs.shots.map((s) => ({ pull_x: s.pull_x, pull_y: s.pull_y, delay: s.delay ?? 0 })) });
}
