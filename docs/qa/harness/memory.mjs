// Tab memory over repeated play in ONE fresh tab (Chrome): load, then 3 winning shots with Retry in
// between (the persistent worker keeps its wasm), then a 3-shot game; RSS of the renderer after each.
//   node docs/qa/harness/memory.mjs <baseUrl> <outDir>
// Lot Q2: `--autoshot` plays exact pulls instead (`?autoshot=`, no mouse), one fresh tab per case,
// and records the worker's wasm peak per shot (the page's `shot N: ... wasm X MB` line):
//   node docs/qa/harness/memory.mjs <baseUrl> <outDir> --autoshot ['pile10:-1022,-63' ...]
// Env: PLAYWRIGHT_MODULE (path of playwright), QA_CHANNEL (default `chrome`; empty: Playwright's
// bundled Chromium), QA_HEADLESS=1.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE ?? path.join(process.env.HOME, '.npm/_npx/420ff84f11983ee5/node_modules/playwright'));
const [base, outDir, mode, ...autoCases] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const channel = process.env.QA_CHANNEL ?? 'chrome';
const browser = await pw.chromium.launch({ ...(channel ? { channel } : {}), headless: process.env.QA_HEADLESS === '1' });
if (mode === '--autoshot') {
  // The reference shots of the six levels, the owner's shot and the cap shot (QA M4, lot Q2).
  const cases = autoCases.length > 0 ? autoCases : [
    'pile10:-1022,-63', 'pile10:-1019,-72', 'pile10:-604,-392', 'pile10:-150,-150;-200,-200;-600,-392',
    'cores3:-653,-304', 'tower:-604,-392', 'bridge:-463,-552', 'twin:-503,-327;-543,-472', 'one_block:-150,-150',
  ];
  const rows = [];
  for (const c of cases) {
    const [level, pulls] = c.split(':');
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    await page.goto(`${base}?level=${level}&autoshot=${pulls}`);
    const shots = pulls.split(';').length;
    for (let i = 0; i < 6000 && logs.filter((l) => /^shot \d+: first frame .* wasm \d+ MB/.test(l)).length < shots; i++) await sleep(100);
    const lines = logs.filter((l) => /^shot \d+: first frame/.test(l));
    const wasm = Math.max(...lines.map((l) => Number(l.match(/wasm (\d+) MB/)?.[1] ?? NaN)));
    rows.push({ case: c, wasmMB: wasm, shots: lines, loaded: logs.find((l) => /^vm: loaded/.test(l)) });
    console.log(JSON.stringify(rows.at(-1)));
    await page.close();
  }
  fs.writeFileSync(path.join(outDir, 'memory-autoshot.json'), JSON.stringify(rows, null, 2));
  await browser.close();
  process.exit(0);
}
const lib = await import('./qa-lib.mjs');
const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });
const page = await context.newPage();
const logs = [];
page.on('console', (m) => logs.push(m.text()));
const renderers = () => {
  const out = execFileSync('ps', ['-axo', 'pid=,ppid=,rss=,command='], { encoding: 'utf8', maxBuffer: 64 << 20 });
  const rows = out.split('\n').filter((l) => /playwright_chromiumdev_profile|--type=renderer/.test(l)).map((l) => l.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/));
  const root = rows.find((m) => /playwright_chromiumdev_profile/.test(m[4]) && !/--type=/.test(m[4]));
  return rows.filter((m) => root && m[2] === root[1] && /--type=renderer/.test(m[4]) && !/extension/.test(m[4])).map((m) => Math.round(Number(m[3]) / 1024)).sort((a, b) => b - a);
};
const cdp = await context.newCDPSession(page);
await cdp.send('Performance.enable');
const heap = async () => Math.round(((await cdp.send('Performance.getMetrics')).metrics.find((x) => x.name === 'JSHeapUsedSize')?.value ?? 0) / 2 ** 20);
const wait = async (re, from) => {
  for (let i = 0; i < 3000; i++) {
    if (logs.slice(from).some((l) => re.test(l))) return;
    await sleep(100);
  }
  throw new Error(`timeout ${re}`);
};
const drag = async (pull) => {
  const geo = await page.evaluate(() => { const r = document.querySelector('#app canvas').getBoundingClientRect(); return { w: r.width, h: r.height }; });
  const cam = lib.fitCamera({ minX: -10, minY: -10, maxX: 50, maxY: 40 }, geo.w, geo.h, { top: 0, bottom: 44 });
  const a = lib.worldToScreen(cam, 3, 2.5);
  const d = lib.pullToDrag({ x: pull[0], y: pull[1] }, 1024);
  await page.mouse.move(a.x, a.y);
  await page.mouse.down();
  await page.mouse.move(a.x + d.dx * cam.scale, a.y - d.dy * cam.scale, { steps: 6 });
  await page.mouse.up();
};
const rows = [];
const note = async (what) => {
  await sleep(1500);
  const wasm = (logs.filter((l) => /wasm \d+ MB/.test(l)).at(-1) ?? '').match(/wasm (\d+) MB/)?.[1];
  rows.push({ what, rendererMB: renderers(), jsHeapMB: await heap(), wasmMB: wasm ? Number(wasm) : null });
  console.log(JSON.stringify(rows.at(-1)));
};
await page.goto(`${base}?level=pile10`);
await wait(/^level pile10: init/, 0);
await note('loaded');
for (let i = 1; i <= 3; i++) {
  const from = logs.length;
  await drag([-980, -293]); // what a mouse reaches next to the owner's direction: wins pile10 in 1 shot
  await wait(/^outputs \(/, from);
  await note(`win ${i} (${logs.slice(from).find((l) => /^level over/.test(l))})`);
  await page.click('#retry-result');
  await sleep(500);
}
{
  const from = logs.length;
  for (const p of [[-150, -150], [-200, -200], [-600, -392]]) {
    const f = logs.length;
    await drag(p);
    await wait(/^shot \d+: first frame/, f);
    await sleep(3500);
  }
  await wait(/^outputs \(/, from);
  await note(`3-shot game (${logs.slice(from).find((l) => /^level over/.test(l))})`);
}
fs.writeFileSync(path.join(outDir, 'memory.json'), JSON.stringify(rows, null, 2));
await browser.close();
