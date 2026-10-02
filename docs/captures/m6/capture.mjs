// Captures of the M6 skin (docs/briefs/m6-art-kenney.md), on desktop and one narrow mobile-width viewport, plus the
// frame times of the reference trace's playback, flat skin against Kenney skin. Against a dev server of `client/`
// (no VM: the page plays the recorded pile10 trace, `client/public/traces/pile10.json`, 160 frames):
//   (cd client && npm run dev -- --port 5199 &)
//   PLAYWRIGHT_MODULE=~/.npm/_npx/6bcb61ec6d5aea22/node_modules/playwright node docs/captures/m6/capture.mjs http://localhost:5199 docs/captures/m6
// Each frame is a fixed tick of the trace, chosen through the scrub range (frame index = tick):
//   rest:   tick 0   (the sling armed: the recorded page leaves it unarmed, so this load alone patches
//                     `stage.armed = false` to `true` in the served main.ts, a capture-only change)
//   flight: tick 30  (the pebble in the air, before the first damage at tick 60)
//   impact: tick 140 (after the destroyed slab at tick 122 and its 450 ms fade, 700 ms of display time)
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE ?? 'playwright');
const [base, outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await pw.chromium.launch({ headless: true });

async function open(viewport, skin, armed) {
  const context = await browser.newContext({ viewport, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  if (armed) {
    await page.route('**/src/main.ts*', async (route) => {
      const res = await route.fetch();
      await route.fulfill({ response: res, body: (await res.text()).replace('stage.armed = false;', 'stage.armed = true;') });
    });
  }
  await page.goto(`${base}/?level=pile10&skin=${skin}`);
  await page.waitForFunction(() => Number(document.querySelector('#scrub')?.max) >= 159, null, { timeout: 30000 });
  await page.click('#play'); // pause
  return { context, page, errors };
}
async function seek(page, tick) {
  await page.evaluate((t) => {
    const s = document.querySelector('#scrub');
    s.value = String(t);
    s.dispatchEvent(new Event('input'));
  }, tick);
}

const out = [];
for (const [name, viewport, tick, armed, wait] of [
  ['rest-desktop', { width: 1280, height: 800 }, 0, true, 400],
  ['rest-mobile', { width: 412, height: 915 }, 0, true, 400],
  ['flight-desktop', { width: 1280, height: 800 }, 30, false, 400],
  ['impact-desktop', { width: 1280, height: 800 }, 140, false, 700],
]) {
  const { context, page, errors } = await open(viewport, 'kenney', armed);
  await seek(page, tick);
  await page.evaluate(() => (document.querySelector('#banner').hidden = true)); // 'VM not built'
  await sleep(wait);
  await page.screenshot({ path: path.join(outDir, `pile10-${name}.png`) });
  out.push(`${name}: tick ${tick}, ${viewport.width}x${viewport.height}, errors: ${errors.length ? errors.join('; ') : 'none'}`);
  await context.close();
}
console.log(out.join('\n'));

// Frame times: the recorded playback from tick 0 to its end (160 frames, ~2.7 s), per skin. The main thread's task time
// per rendered frame (CDP Performance.TaskDuration) and the mean requestAnimationFrame interval. Software GL in headless.
const times = {};
for (const skin of ['flat', 'kenney']) {
  const { context, page } = await open({ width: 1280, height: 800 }, skin, false);
  const cdp = await context.newCDPSession(page);
  await cdp.send('Performance.enable');
  const task = async () => (await cdp.send('Performance.getMetrics')).metrics.find((m) => m.name === 'TaskDuration').value;
  await seek(page, 0);
  await sleep(300);
  await page.evaluate(() => {
    window.__raf = [];
    const tick = (t) => (window.__raf.push(t), window.__stop || requestAnimationFrame(tick));
    requestAnimationFrame(tick);
  });
  const t0 = await task();
  await page.click('#play');
  await page.waitForFunction(() => document.querySelector('[data-hud="tick"]')?.textContent?.startsWith('159'), null, { timeout: 20000 });
  const t1 = await task();
  const raf = await page.evaluate(() => ((window.__stop = true), window.__raf));
  const dts = raf.slice(1).map((t, i) => t - raf[i]);
  times[skin] = {
    frames: dts.length,
    taskMsPerFrame: ((t1 - t0) * 1000) / dts.length,
    rafMeanMs: dts.reduce((a, b) => a + b, 0) / dts.length,
  };
  await context.close();
}
console.log(JSON.stringify(times, null, 2));
fs.writeFileSync(path.join(outDir, 'frame-times.json'), JSON.stringify(times, null, 2) + '\n');
await browser.close();
