import type { RawFixed } from './types';

/** One observer line of the trace build, reduced to what the spike prints. */
export interface TickSample {
  tick: number;
  y: RawFixed;
}

/**
 * Turns a line printed by the trace build (`println!`, captured by the worker of lot G1c) into a
 * sample, or `null` for a line that is not a tick. The observer format of G4 is not fixed yet:
 * the worker source depends on this interface only, and G4 brings its own implementation.
 */
export interface TickLineParser {
  parse(line: string): TickSample | null;
}

/** The spike's format (docs/research/03-spike-wasm-vm.md): `tick <i> y <raw>`. */
export class SpikeTickLineParser implements TickLineParser {
  private static readonly PATTERN = /^tick (\d+) y (-?\d+)$/;

  parse(line: string): TickSample | null {
    const match = SpikeTickLineParser.PATTERN.exec(line.trim());
    return match ? { tick: Number(match[1]), y: match[2] } : null;
  }
}
