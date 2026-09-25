// Node stand-in for the browser check (lot G6b): the page side (`VmClient`, `LevelSession`) on
// the main thread, the worker side (`serveVm` on `pkg-node` and the replay executables) in a
// `worker_threads` Worker, so that frames cross threads while the VM runs, as in the browser.
// Plays pile10 with the given pulls (default: the reference shot) and prints the figures the
// page logs: release -> first frame, per-shot time, worst frame gap, the level result, outputs.
//
//   node client/vm/scripts/worker-check.mjs [px,py[;px,py...]]
import { readFileSync } from 'node:fs';
import { Worker, isMainThread, parentPort } from 'node:worker_threads';

const vm = (p) => new URL(`../${p}`, import.meta.url);

if (isMainThread) {
  const { LevelSession } = await import('../../src/game/session.ts');
  const { VmClient } = await import('../../src/vm/index.ts');
  const { OUTPUT_FIELDS } = await import('../../src/vm/program.ts');
  const pulls = (process.argv[2] ?? '-600,-392').split(';').map((s) => {
    const [x, y] = s.split(',').map(Number);
    return { x, y };
  });
  const worker = new Worker(new URL(import.meta.url));
  const port = {
    onmessage: null,
    postMessage: (m) => worker.postMessage(m),
    terminate: () => worker.terminate(),
  };
  worker.on('message', (data) => port.onmessage?.({ data }));
  const t = performance.now();
  const client = new VmClient(port, { pkgUrl: '', executableUrl: '', program: 'slingfall' });
  const loaded = await client.ready;
  console.log(`vm: loaded in ${loaded.ms.toFixed(0)} ms (page side ${(performance.now() - t).toFixed(0)} ms), wasm ${(loaded.wasmBytes / 2 ** 20).toFixed(0)} MB`);
  const felts = JSON.parse(readFileSync(vm('../../fixtures/levels/pile10.felts.json'), 'utf8')).felts;
  const t0 = performance.now();
  const session = await LevelSession.open(client, { felts });
  console.log(`level pile10: init in ${(performance.now() - t0).toFixed(0)} ms, ${session.traceLevel.bodies.length} bodies`);
  for (const pull of pulls) {
    if (session.phase !== 'aiming') break;
    let last = null;
    let maxGap = 0;
    const report = await session.fire(pull, {
      onFrame: () => {
        const now = performance.now();
        if (last !== null) maxGap = Math.max(maxGap, now - last);
        last = now;
      },
    });
    const peak = Math.max(...report.chunks.map((c) => c.wasmBytes)) / 2 ** 20;
    console.log(
      `shot ${report.shot} pull (${pull.x}, ${pull.y}): first frame ${report.firstFrameMs?.toFixed(0)} ms, ` +
        `${report.ticks} ticks, ${(report.steps / 1e6).toFixed(2)}M steps, ${(report.ms / 1000).toFixed(2)} s, ` +
        `worst frame gap ${maxGap.toFixed(0)} ms, ${report.chunks.length} chunks [${report.chunks.map((c) => c.ticks).join(' ')}], ` +
        `peak wasm ${peak.toFixed(0)} MB; score ${session.header.score}, tick ${session.header.tick}`,
    );
  }
  const result = session.result();
  if (result !== null) {
    console.log(`level over: ${result.won ? 'won' : 'lost'}, score ${result.score}, shots ${result.shotsUsed}, ticks ${result.ticks}`);
    const t1 = performance.now();
    const outputs = await session.outputs();
    console.log(`outputs (${(performance.now() - t1).toFixed(0)} ms): ${OUTPUT_FIELDS.map((f) => `${f}=${outputs[f]}`).join(' ')}`);
  }
  client.terminate();
} else {
  const { createRequire } = await import('node:module');
  const { serveVm } = await import('../../src/vm/serve.ts');
  const { engineFromModule } = await import('../../src/vm/shot.ts');
  const mod = createRequire(import.meta.url)(new URL('../pkg-node/slingfall_vm_runner.js', import.meta.url).pathname);
  const exe = (name) => readFileSync(vm(`fixtures/replay/${name}.executable.json`), 'utf8');
  const scope = { onmessage: null, postMessage: (m) => parentPort.postMessage(m) };
  parentPort.on('message', (data) => scope.onmessage?.({ data }));
  serveVm(scope, async () => engineFromModule(mod, exe('step_chunk'), { init: exe('init'), outputs: exe('outputs') }));
}
