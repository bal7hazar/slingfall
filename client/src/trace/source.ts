import type { Trace, TraceFrame } from './types';

/**
 * Where the renderer gets its frames from: a recorded trace (a JSON file emitted from
 * `main_trace` through `scarb execute`), or, from lot G6b on, the cairo-vm worker running the
 * chunked replay live (docs/DESIGN.md D8). Frames arrive in tick order.
 */
export interface TraceSource {
  readonly kind: 'recorded' | 'worker';
  frames(): AsyncIterable<TraceFrame>;
}

/** Fetches a JSON document; injectable so that tests read fixtures without a browser. */
export type JsonLoader = (url: string) => Promise<unknown>;

const fetchJson: JsonLoader = async (url) => {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`cannot load trace ${url}: HTTP ${response.status}`);
  }
  return response.json();
};

/** A trace recorded ahead of time and served as a JSON file. */
export class RecordedTraceSource implements TraceSource {
  readonly kind = 'recorded';
  private readonly url: string;
  private readonly load: JsonLoader;

  constructor(url: string, load: JsonLoader = fetchJson) {
    this.url = url;
    this.load = load;
  }

  async *frames(): AsyncIterable<TraceFrame> {
    const trace = parseTrace(await this.load(this.url));
    yield* trace.frames;
  }
}

/** Checks the shape of a trace document (not the values: they come from the Cairo replay). */
export function parseTrace(doc: unknown): Trace {
  const trace = doc as Trace;
  if (typeof trace?.version !== 'number' || !Array.isArray(trace.frames)) {
    throw new Error('not a trace: expected { version: number, frames: [] }');
  }
  return trace;
}
