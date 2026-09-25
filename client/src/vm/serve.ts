// The worker side of the protocol, independent of the Worker global so that tests can serve it
// in-process: loads the engine once, then runs the shots it receives one after the other,
// streaming frames while the VM runs (`println!` -> `postMessage`, synchronously).
import { PROGRAMS, type ChunkProgram } from './program.ts';
import type { FromWorker, LoadRequest, ToWorker } from './protocol';
import { runShot, type VmEngine } from './shot.ts';

/** What `serveVm` needs from the worker global (`self` in a Web Worker). */
export interface WorkerScope {
  postMessage(message: FromWorker): void;
  onmessage: ((event: { data: ToWorker }) => void) | null;
}

export type EngineLoader = (request: LoadRequest) => Promise<VmEngine>;

const describe = (e: unknown) => (e instanceof Error ? e.message : String(e));

export function serveVm(scope: WorkerScope, loadEngine: EngineLoader, now = () => performance.now()) {
  let loaded: { engine: VmEngine; program: ChunkProgram } | null = null;
  const handle = async (msg: ToWorker) => {
    if (msg.type === 'load') {
      const t = now();
      try {
        const program = PROGRAMS[msg.program];
        if (program === undefined) throw new Error(`unknown program ${msg.program}`);
        const engine = await loadEngine(msg);
        loaded = { engine, program };
        scope.postMessage({ type: 'loaded', ms: now() - t, wasmBytes: engine.memoryBytes() });
      } catch (e) {
        scope.postMessage({ type: 'error', message: `load failed: ${describe(e)}` });
      }
      return;
    }
    const { id } = msg;
    if (loaded === null) {
      scope.postMessage({ type: 'error', id, message: 'shot before load' });
      return;
    }
    try {
      const result = runShot(loaded.engine, loaded.program, msg.level, msg.inputs, {
        sizing: msg.sizing,
        fixedTicks: msg.fixedTicks,
        onFrame: (frame) => scope.postMessage({ type: 'frame', id, frame }),
        onLine: (line) => scope.postMessage({ type: 'line', id, line }),
        onChunk: (chunk) => scope.postMessage({ type: 'chunk', id, chunk }),
        now,
      });
      scope.postMessage({ type: 'done', id, result });
    } catch (e) {
      scope.postMessage({ type: 'error', id, message: describe(e) });
    }
  };
  // One message at a time, in arrival order (a load is async, shots are not).
  let queue = Promise.resolve();
  scope.onmessage = ({ data }) => {
    queue = queue.then(() => handle(data));
  };
}
