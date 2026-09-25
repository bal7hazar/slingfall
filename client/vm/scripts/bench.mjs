// Node benchmark of the wasm runner (pkg-node) on the ball_drop stand-in, reproducing the spike
// G1b figures (docs/research/04). One scenario per process, so that the wasm memory reported
// (it only grows) is the peak of that scenario. Imports the TypeScript chunk loop directly
// (Node >= 23.6 strips types).
//
//   node client/vm/scripts/bench.mjs first-chunk [rounds=5]   pile12 init + first 10 ticks, reserve 7M cells
//   node client/vm/scripts/bench.mjs shot [K|rule=rule] [ticks=120] [reserveFactor]
//                                    a whole pile12 shot, warmed-up engine
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { ballDropProgram } from '../../src/vm/program.ts';
import { engineFromModule, runShot } from '../../src/vm/shot.ts';
import { DEFAULT_SIZING } from '../../src/vm/sizing.ts';

const vm = (p) => fileURLToPath(new URL(`../${p}`, import.meta.url));
const MB = 2 ** 20;
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const [scenario = 'shot', a1, a2, a3] = process.argv.slice(2);

let t = performance.now();
const mod = createRequire(import.meta.url)(vm('pkg-node/slingfall_vm_runner.js'));
const json = readFileSync(vm('fixtures/ball_drop.executable.json'), 'utf8');
const engine = engineFromModule(mod, json);
console.log(`load (wasm + JSON parse + program) ${(performance.now() - t).toFixed(0)} ms, wasm ${(engine.memoryBytes() / MB).toFixed(0)} MB`);

// Page-load warm-up, as the spike: ball_drop 60 ticks (1.3M steps), so that the JIT's optimising
// tier is in place before the shot.
t = performance.now();
const warm = engine.run('0 0 60 0 0', {});
console.log(`warm-up ${warm.steps} steps in ${(performance.now() - t).toFixed(0)} ms, wasm ${(engine.memoryBytes() / MB).toFixed(0)} MB`);

if (scenario === 'first-chunk') {
  const rounds = Number(a1 ?? 5);
  const init = engine.run(ballDropProgram.initArgs({ scene: 3, ticks: 120 }), {}).returned;
  const args = ballDropProgram.chunkArgs({ scene: 3, ticks: 120 }, init, null, 10);
  const rates = [];
  for (let i = 0; i < rounds; i++) {
    t = performance.now();
    const r = engine.run(args, { reserveCells: 7_000_000 });
    const ms = performance.now() - t;
    rates.push(r.steps / ms / 1000);
    console.log(`round ${i}: ${r.steps} steps, ${ms.toFixed(0)} ms, ${(r.steps / ms / 1000).toFixed(2)} M steps/s, exec cells ${r.execCells}`);
  }
  console.log(`first chunk: median ${median(rates).toFixed(2)} M steps/s (min ${Math.min(...rates).toFixed(2)}, max ${Math.max(...rates).toFixed(2)}), peak wasm ${(engine.memoryBytes() / MB).toFixed(0)} MB`);
} else if (scenario === 'shot') {
  const k = a1 === undefined || a1 === 'rule' ? undefined : Number(a1);
  const level = { scene: 3, ticks: Number(a2 ?? 120) };
  let first = null;
  let last = null;
  let maxGap = 0;
  // First tick: from the shot request (init chunk included) to the first streamed frame.
  const t0 = performance.now();
  const sizing = { ...DEFAULT_SIZING, ...(a3 === undefined ? {} : { reserveFactor: Number(a3) }) };
  console.log(`sizing ${JSON.stringify(sizing)}`);
  const shot = runShot(engine, ballDropProgram, level, null, {
    sizing,
    fixedTicks: k,
    onFrame: () => {
      const now = performance.now() - t0;
      if (first === null) first = now;
      if (last !== null) maxGap = Math.max(maxGap, now - last);
      last = now;
    },
  });
  const runMs = shot.chunks.reduce((a, c) => a + c.ms, 0);
  console.log(
    `shot K=${k ?? 'rule'}: ${shot.chunks.length - 1} chunks, total ${(shot.ms / 1000).toFixed(2)} s, ` +
      `${(shot.steps / 1e6).toFixed(2)}M steps, ${(shot.steps / runMs / 1000).toFixed(2)} M steps/s, ` +
      `first tick ${first?.toFixed(0)} ms, worst tick gap ${maxGap.toFixed(0)} ms, peak wasm ${(engine.memoryBytes() / MB).toFixed(0)} MB`,
  );
  console.log(`  K per chunk [${shot.chunks.slice(1).map((c) => c.ticks).join(' ')}]`);
  console.log(`  M steps per chunk [${shot.chunks.slice(1).map((c) => (c.steps / 1e6).toFixed(1)).join(' ')}]`);
  console.log(`  wasm MB after chunk [${shot.chunks.map((c) => (c.wasmBytes / MB).toFixed(0)).join(' ')}]`);
} else {
  throw new Error(`unknown scenario ${scenario}`);
}
console.log(`process max RSS ${(process.resourceUsage().maxRSS / 1024).toFixed(0)} MB`);
