// Phone viewports (Chrome device emulation, touch): layout, aim geometry, a touch shot on pile10.
//   node docs/qa/harness/mobile.mjs <baseUrl> <outDir>
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import * as lib from './qa-lib.mjs';
const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE ?? path.join(process.env.HOME, '.npm/_npx/420ff84f11983ee5/node_modules/playwright'));
const [base, outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await pw.chromium.launch({ channel: 'chrome', headless: false });
const out = {};
for (const dev of ['iPhone 13', 'Pixel 7', 'iPhone 13 landscape']) {
  const context = await browser.newContext({ ...pw.devices[dev] });
  const page = await context.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));
  await page.goto(`${base}?level=pile10`);
  for (let i = 0; i < 100 && !logs.some((l) => l.startsWith('level pile10: init')); i++) await sleep(100);
  await sleep(500);
  const tag = dev.replace(/\s+/g, '-');
  await page.screenshot({ path: path.join(outDir, `mobile-${tag}-start.png`) });
  const geo = await page.evaluate(() => {
    const rect = (s) => { const r = document.querySelector(s).getBoundingClientRect(); return { left: Math.round(r.left), top: Math.round(r.top), right: Math.round(r.right), bottom: Math.round(r.bottom) }; };
    const c = document.querySelector('#app canvas').getBoundingClientRect();
    const hint = document.querySelector('#hint');
    return { vw: innerWidth, vh: innerHeight, canvas: { w: c.width, h: c.height }, controls: rect('#controls'), hint: { ...rect('#hint'), lines: Math.round(hint.getBoundingClientRect().height / parseFloat(getComputedStyle(hint).lineHeight || '16')) }, hudLastSpan: rect('#hud span:nth-child(3)'), chainInfo: rect('#chain-info'), docScrollW: document.documentElement.scrollWidth };
  });
  const cam = lib.fitCamera({ minX: -10, minY: -10, maxX: 50, maxY: 40 }, geo.canvas.w, geo.canvas.h, { top: 0, bottom: 44 });
  const a = lib.worldToScreen(cam, 3, 2.5);
  const full = 3 * cam.scale;
  const cdp = await context.newCDPSession(page);
  const tp = (x, y) => [{ x, y, id: 1 }];
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: tp(a.x, a.y) });
  for (let k = 1; k <= 6; k++) await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: tp(a.x - (full * 1.05 * k) / 6, a.y + (full * 0.3 * k) / 6) });
  await sleep(200);
  await page.screenshot({ path: path.join(outDir, `mobile-${tag}-aim.png`) });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  for (let i = 0; i < 300 && !logs.some((l) => l.startsWith('outputs (')); i++) await sleep(100);
  await sleep(1500);
  await page.screenshot({ path: path.join(outDir, `mobile-${tag}-after.png`) });
  const after = await page.evaluate(() => {
    const h = document.querySelector('#hud span:nth-child(3)').getBoundingClientRect();
    const c = document.querySelector('#chain-info').getBoundingClientRect();
    const r = document.querySelector('#result');
    const rr = r.getBoundingClientRect();
    const ctl = document.querySelector('#controls').getBoundingClientRect();
    return { hudTickRight: Math.round(h.right), chainInfoLeft: Math.round(c.left), hudOverlapsChainInfo: h.right > c.left && h.top < c.bottom, result: { top: Math.round(rr.top), bottom: Math.round(rr.bottom), scrollH: r.scrollHeight, clientH: r.clientHeight, overlapsControls: rr.bottom > ctl.top } };
  });
  out[dev] = { geo, after, pxPerMetre: +cam.scale.toFixed(2), anchor: a, fullPullPx: +full.toFixed(1), grabRadiusPx: +(1.5 * cam.scale).toFixed(1), pullUnitsPerPx: +(1024 / 3 / cam.scale).toFixed(1), logs: logs.filter((l) => /release|shot 0|level over/.test(l)) };
  await context.close();
}
fs.writeFileSync(path.join(outDir, 'mobile.json'), JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
await browser.close();
