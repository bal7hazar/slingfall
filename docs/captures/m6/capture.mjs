// Captures of the M6 skin (docs/briefs/m6-art-kenney.md): every level after a shot, the interface, one scene at rest
// per orientation, on desktop (1280x800) and at a narrow mobile width (412x915), and the frame times of a shot's
// playback, flat skin against Kenney skin. Headless Chromium against a dev server of `client/` with the wasm runner
// built (`client/vm/scripts/build.sh`, under the heavy lock): the real replay runs in the page's worker.
//   (cd client && npm run dev -- --port 5199 &)
//   PLAYWRIGHT_MODULE=~/.npm/_npx/<id>/node_modules/playwright node docs/captures/m6/capture.mjs http://localhost:5199 docs/captures/m6
// A shot is fired by the page's own `?autoshot=x,y` (src/main.ts). The frame is chosen deterministically: the moment the page
// logs `shot 0: shown`, or `level over` when the shot ends the level (the playback has shown the shot's last frame; the tick is
// printed in captures.txt), plus 900 ms of display time for the flash and fade of the last damage.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE ?? 'playwright');
const [base, outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await pw.chromium.launch({ headless: true });

const DESKTOP = { width: 1280, height: 800 };
const MOBILE = { width: 412, height: 915 };
/** The pull of the reference shot (scripts/play/qa-browser.mjs) and the shots tried per level until one scores. */
const PULLS = ['-1022,-63', '-900,-200', '-1000,-330', '-800,-100'];
// WORN=level:pull;pull;pull takes one extra desktop capture (`<level>-worn-1280x800.png`, after the last shot) and only that.
// INTERFACE=1 redoes the interface captures alone.
// ONLY=cores3,tower redoes the after-shot captures of those levels alone (a fix to one skin path).
const ONLY = process.env.ONLY?.split(',');
const WORN = process.env.WORN;
const INTERFACE = process.env.INTERFACE;
const LEVELS = ['pile10', 'cores3', 'tower', 'bridge', 'twin', 'one_block'].filter((l) => !ONLY || ONLY.includes(l));

async function open(viewport, query) {
  const context = await browser.newContext({ viewport, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const log = { errors: [], lines: [] };
  page.on('pageerror', (e) => log.errors.push(e.message));
  page.on('console', (m) => {
    if (m.type() === 'error') log.errors.push(m.text());
    log.lines.push(m.text());
  });
  await page.goto(`${base}/?${query}`);
  await page.waitForFunction(() => !document.querySelector('#level')?.disabled || document.querySelector('#banner')?.textContent?.includes('VM not built'), null, { timeout: 120000 });
  if (await page.evaluate(() => document.querySelector('#banner')?.textContent?.includes('VM not built'))) throw new Error('the wasm runner is not built');
  await waitLine(log, /^level \w+: init in/, 120000); // the level is loaded and framed
  return { context, page, log };
}
const waitLine = (log, re, timeout = 180000) =>
  new Promise(async (resolve, reject) => {
    const t = Date.now();
    while (Date.now() - t < timeout) {
      if (log.lines.some((l) => re.test(l))) return resolve();
      await sleep(100);
    }
    reject(new Error(`timeout: ${re}`));
  });
const text = (page, sel) => page.evaluate((s) => document.querySelector(s)?.textContent ?? '', sel);
const shotName = (kind, level, vp) => `${level}-${kind}-${vp.width}x${vp.height}.png`;
const report = [];
if (WORN) {
  const [level, shots] = WORN.split(':');
  const { context, page, log } = await open(DESKTOP, `level=${level}&skin=kenney&autoshot=${shots}`);
  await waitLine(log, /^level over/, 400000).catch(() => {});
  await page.waitForFunction(() => !document.querySelector('#result')?.hidden, null, { timeout: 60000 }).catch(() => {});
  await page.evaluate(() => (document.querySelector('#result').hidden = true)); // the panel would hide the blocks
  await sleep(900);
  await page.screenshot({ path: path.join(outDir, `${level}-worn-1280x800.png`) });
  console.log(`${level}-worn-1280x800.png: shots ${shots}, ${await text(page, '[data-hud="tick"]')}`);
  await browser.close();
  process.exit(0);
}

// 1. Rest: the sling armed, before any shot (one per orientation), pile10.
for (const vp of ONLY || INTERFACE ? [] : [DESKTOP, MOBILE]) {
  const { context, page, log } = await open(vp, 'level=pile10&skin=kenney');
  await sleep(1200);
  const file = shotName('rest', 'pile10', vp);
  await page.screenshot({ path: path.join(outDir, file) });
  report.push(`${file}: at rest, errors: ${log.errors.join('; ') || 'none'}`);
  await context.close();
}

// 2. After a shot, every level, both viewports: the first pull of PULLS that scores (HUD score > 0), else the last one.
for (const vp of INTERFACE ? [] : [DESKTOP, MOBILE]) {
  for (const level of LEVELS) {
    let used = '';
    for (const pull of PULLS) {
      const { context, page, log } = await open(vp, `level=${level}&skin=kenney&autoshot=${pull}`);
      await waitLine(log, /shot 0: shown|^level over/); // a shot that ends the level logs `level over` instead
      await sleep(900);
      const score = Number(await text(page, '[data-hud="score"]'));
      used = `pull ${pull}, score ${score}, ${await text(page, '[data-hud="tick"]')}`;
      if (score > 0 || pull === PULLS[PULLS.length - 1]) {
        const file = shotName('impact', level, vp);
        await page.screenshot({ path: path.join(outDir, file) });
        report.push(`${file}: ${used}, errors: ${log.errors.join('; ') || 'none'}`);
        await context.close();
        break;
      }
      await context.close();
    }
  }
}

// 3. The interface: the page with the result panel open (a level lost after three shots), both viewports.
for (const vp of ONLY ? [] : [DESKTOP, MOBILE]) {
  const { context, page, log } = await open(vp, 'level=one_block&skin=kenney&autoshot=-300,-50;-300,-50;-300,-50');
  await waitLine(log, /^level over/, 240000).catch(() => {});
  await page.waitForFunction(() => !document.querySelector('#result')?.hidden, null, { timeout: 120000 }).catch(() => {});
  await sleep(900);
  const file = shotName('interface', 'one_block', vp);
  await page.screenshot({ path: path.join(outDir, file) });
  report.push(`${file}: result panel ${(await page.evaluate(() => !document.querySelector('#result')?.hidden)) ? 'open' : 'NOT open'}, errors: ${log.errors.join('; ') || 'none'}`);
  await context.close();
}
console.log(report.join('\n'));
if (ONLY || INTERFACE) {
  await browser.close();
  process.exit(0);
}
fs.writeFileSync(path.join(outDir, 'captures.txt'), report.join('\n') + '\n');

// 4. Frame times: the playback of the reference shot (pull -1022,-63 on pile10), from the end of the compute (`shot 0: first frame`) to `shot 0: shown`, per skin.
// Main-thread task time per rendered frame (CDP Performance.TaskDuration; the VM runs in a worker, so its time is not counted)
// and the mean requestAnimationFrame interval. Three runs per skin, software GL in headless Chromium.
const times = {};
for (const skin of ['flat', 'kenney']) {
  times[skin] = [];
  for (let run = 0; run < 3; run++) {
    const context = await browser.newContext({ viewport: DESKTOP, deviceScaleFactor: 1 });
    const page = await context.newPage();
    const lines = [];
    page.on('console', (m) => lines.push(m.text()));
    const cdp = await context.newCDPSession(page);
    await cdp.send('Performance.enable');
    const task = async () => (await cdp.send('Performance.getMetrics')).metrics.find((m) => m.name === 'TaskDuration').value;
    await page.addInitScript(() => {
      window.__raf = [];
      const tick = (t) => (window.__raf.push(t), requestAnimationFrame(tick));
      requestAnimationFrame(tick);
    });
    await page.goto(`${base}/?level=pile10&skin=${skin}&autoshot=-1022,-63`);
    const t = Date.now();
    // The shot is computed ahead (the worker), then played: measure from `produced` to the playback's last frame.
    while (!lines.some((l) => /^shot 0: first frame/.test(l)) && Date.now() - t < 240000) await sleep(20);
    const t0 = await task();
    const r0 = await page.evaluate(() => window.__raf.length);
    while (!lines.some((l) => /shot 0: shown|^level over/.test(l)) && Date.now() - t < 240000) await sleep(50);
    const t1 = await task();
    const raf = await page.evaluate((from) => window.__raf.slice(from), r0);
    const dts = raf.slice(1).map((v, i) => v - raf[i]);
    times[skin].push({
      frames: dts.length,
      taskMsPerFrame: Math.round(((t1 - t0) * 1000 * 10) / dts.length) / 10,
      rafMeanMs: Math.round((dts.reduce((a, b) => a + b, 0) / dts.length) * 10) / 10,
    });
    await context.close();
  }
}
console.log(JSON.stringify(times, null, 2));
fs.writeFileSync(path.join(outDir, 'frame-times.json'), JSON.stringify(times, null, 2) + '\n');
await browser.close();
