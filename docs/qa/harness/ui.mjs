// UI checks: level selector and on-chain level hashes, Voyager links, firing a shot while the previous
// one still plays, result panel timing, Copy inputs, Play / Pause / Space / scrub, Retry, HTTP errors.
//   node docs/qa/harness/ui.mjs <chrome|firefox> <baseUrl> <outDir>
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import * as lib from './qa-lib.mjs';
const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE ?? path.join(process.env.HOME, '.npm/_npx/420ff84f11983ee5/node_modules/playwright'));
const [browserName, base, outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const HERE = path.dirname(new URL(import.meta.url).pathname);
const deploy = JSON.parse(fs.readFileSync(path.join(HERE, '../../../deploy/sepolia.json'), 'utf8'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const type = browserName === 'firefox' ? pw.firefox : pw.chromium;
const browser = await type.launch(browserName === 'chrome' ? { channel: 'chrome', headless: false } : { headless: false });
const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });
if (browserName === 'chrome') await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(base).origin });
const page = await context.newPage();
const logs = [];
const bad = [];
page.on('console', (m) => logs.push({ t: Date.now(), type: m.type(), text: m.text() }));
page.on('response', (r) => { if (r.status() >= 400) bad.push(`${r.status()} ${r.url()}`); });
page.on('requestfailed', (r) => bad.push(`failed ${r.url()} ${r.failure()?.errorText}`));
const waitLog = async (re, from = 0, timeout = 180000) => {
  const t = Date.now();
  while (Date.now() - t < timeout) {
    const f = logs.slice(from).find((l) => re.test(l.text));
    if (f) return f;
    await sleep(50);
  }
  throw new Error(`timeout ${re}`);
};
const text = (s) => page.evaluate((q) => document.querySelector(q)?.textContent, s);
const res = { browser: browserName, version: browser.version(), base };
await page.goto(`${base}?level=pile10`);
await waitLog(/^level pile10: init/);
res.favicon = await page.evaluate(() => document.querySelector('link[rel=icon]')?.href);
res.chainInfo = await page.evaluate(() => ({ text: document.querySelector('#chain-info').innerText, links: [...document.querySelectorAll('#chain-info a')].map((a) => ({ href: a.href, target: a.target, rel: a.rel })) }));
res.levelOptions = await page.evaluate(() => [...document.querySelectorAll('#level option')].map((o) => o.value));
res.levels = {};
for (const name of res.levelOptions) {
  const from = logs.length;
  const t = Date.now();
  await page.selectOption('#level', name);
  await waitLog(new RegExp(`^level ${name}: init`), from);
  await sleep(200);
  const shown = await page.evaluate(() => document.querySelector('#chain-info span')?.title);
  res.levels[name] = { shown, deployed: deploy.levels[name], match: BigInt(shown) === BigInt(deploy.levels[name]), switchMs: Date.now() - t };
}
const drag = async (dxM, dyM) => {
  const geo = await page.evaluate(() => { const r = document.querySelector('#app canvas').getBoundingClientRect(); return { w: r.width, h: r.height }; });
  const cam = lib.fitCamera({ minX: -10, minY: -10, maxX: 50, maxY: 40 }, geo.w, geo.h, { top: 0, bottom: 44 });
  const a = lib.worldToScreen(cam, 3, 2.5);
  await page.mouse.move(a.x, a.y);
  await page.mouse.down();
  await page.mouse.move(a.x + dxM * cam.scale, a.y - dyM * cam.scale, { steps: 6 });
  await page.mouse.up();
};
{
  const from = logs.length;
  await page.selectOption('#level', 'pile10');
  await waitLog(/^level pile10: init/, from);
  await sleep(300);
}
// A weak shot, then a second release as soon as the VM is done with the first, while it still plays.
let from = logs.length;
await drag(-0.45, -0.45);
const rel0 = await waitLog(/^shot 0: release/, from);
res.duringFlight = { levelSelectDisabled: await page.evaluate(() => document.querySelector('#level').disabled), retryDisabled: await page.evaluate(() => document.querySelector('#retry').disabled), hint: await text('#hint') };
const fig0 = await waitLog(/^shot 0: first frame/, from);
const hudWhenArmed = await text('[data-hud="tick"]');
from = logs.length;
await drag(-0.6, -0.6);
await sleep(400);
res.fireDuringPlayback = { firstShotSimMs: fig0.t - rel0.t, hudTickWhenSecondReleased: hudWhenArmed, secondShotAccepted: logs.slice(from).some((l) => /^shot 1: release/.test(l.text)), hudAfter: await page.evaluate(() => document.querySelector('#hud').innerText.replace(/\n/g, ' ')) };
await page.screenshot({ path: path.join(outDir, `${browserName}-ui-fire-during-playback.png`) });
await waitLog(/^shot 1: first frame/, from);
await sleep(200);
from = logs.length;
await drag(-1.8, -1.2);
const over = await waitLog(/^level over/, from);
const panelAt = Date.now();
const hudAtPanel = await text('[data-hud="tick"]');
await sleep(300);
await page.screenshot({ path: path.join(outDir, `${browserName}-ui-panel-before-playback-end.png`) });
let endAt = null;
for (let i = 0; i < 1200 && endAt === null; i++) {
  const [a, b] = (await text('[data-hud="tick"]')).split('/').map((s) => Number(s.trim()));
  if (a === b) endAt = Date.now();
  else await sleep(50);
}
res.panelTiming = { levelOver: over.text, hudTickWhenPanelShown: hudAtPanel, panelBeforePlaybackEndMs: endAt && endAt - panelAt, hudAtEnd: await page.evaluate(() => document.querySelector('#hud').innerText.replace(/\n/g, ' ')) };
await waitLog(/^outputs \(/, from);
await page.screenshot({ path: path.join(outDir, `${browserName}-ui-panel-end.png`) });
if (browserName === 'chrome') {
  await page.click('#copy-inputs');
  await sleep(200);
  res.copyInputs = { label: await text('#copy-inputs'), clipboard: await page.evaluate(() => navigator.clipboard.readText()) };
  await sleep(1600);
  res.copyInputs.labelAfter = await text('#copy-inputs');
}
res.panel = await page.evaluate(() => ({
  links: [...document.querySelectorAll('#result a')].map((a) => ({ text: a.textContent, href: a.href, target: a.target })),
  wallets: [...document.querySelectorAll('#result select option')].map((o) => o.textContent),
  buttons: [...document.querySelectorAll('#result button')].map((b) => ({ text: b.textContent, disabled: b.disabled, hidden: b.hidden })),
  status: document.querySelector('.submit-status')?.textContent,
}));
res.play = { atEnd: await text('#play') };
await page.click('#play');
res.play.afterClick = await text('#play');
await page.keyboard.press('Space');
res.play.afterSpace = await text('#play');
await page.evaluate(() => { const s = document.querySelector('#scrub'); s.value = '60'; s.dispatchEvent(new Event('input')); });
await sleep(150);
res.play.hudAfterScrub60 = await page.evaluate(() => document.querySelector('#hud').innerText.replace(/\n/g, ' '));
await page.click('#retry-result');
await sleep(300);
res.retry = { panelHidden: await page.evaluate(() => document.querySelector('#result').hidden), hud: await page.evaluate(() => document.querySelector('#hud').innerText.replace(/\n/g, ' ')), hint: await text('#hint'), play: await text('#play') };
res.httpErrors = bad;
res.consoleWarnings = [...new Set(logs.filter((l) => l.type === 'error' || l.type === 'warning').map((l) => l.text))];
fs.writeFileSync(path.join(outDir, `${browserName}-ui.json`), JSON.stringify(res, null, 2));
console.log(JSON.stringify(res, null, 2));
await browser.close();
