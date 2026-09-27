// Lot Q1 evidence (docs/qa/2026-09-26-mac.md M2, M3, M5, m1-m4): the result panel and the sling wait
// for the playback, the pull by keyboard and by touch, the framing, and the narrow layouts.
//
//   bash docs/qa/harness/build-lib.sh                   # qa-lib.mjs: the client's own camera / pull code
//   (cd client && npx vite build --mode sepolia)        # the Sepolia build shows the chain strip (m1)
//   node docs/qa/harness/q1.mjs <outDir>                # serves client/dist with `vite preview` itself
//
// Headless Chromium from PLAYWRIGHT_MODULE (a `playwright` package; its browsers installed with
// `npx playwright install chromium`). Writes <outDir>/q1.json and the screenshots.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as lib from './qa-lib.mjs';

const require = createRequire(import.meta.url);
/** PLAYWRIGHT_MODULE, else the first `playwright` in the npx cache (`npx playwright install chromium` puts one there). */
function playwrightPath() {
  if (process.env.PLAYWRIGHT_MODULE) return process.env.PLAYWRIGHT_MODULE;
  const npx = path.join(process.env.HOME, '.npm/_npx');
  for (const entry of fs.existsSync(npx) ? fs.readdirSync(npx) : []) {
    const candidate = path.join(npx, entry, 'node_modules/playwright');
    if (fs.existsSync(candidate)) return candidate;
  }
  return 'playwright';
}
const pw = require(playwrightPath());
const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLIENT = path.join(HERE, '../../../client');
const [outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const PORT = 4173;
const BASE = `http://127.0.0.1:${PORT}/`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Before the page's scripts: timestamped console lines, and the UI state at every animation frame it changes. */
const INIT = () => {
  const qa = (window.__q1 = { logs: [], states: [] });
  const orig = console.log.bind(console);
  console.log = (...a) => {
    qa.logs.push({ t: performance.now(), text: a.map(String).join(' ') });
    orig(...a);
  };
  let last = '';
  const sample = (t) => {
    const q = (s) => document.querySelector(s);
    const result = q('#result');
    if (q('#hud') && result) {
      const state = {
        tick: q('[data-hud="tick"]').textContent,
        shots: q('[data-hud="shots"]').textContent,
        pull: q('[data-hud="pull"]').textContent,
        play: q('#play').textContent,
        hint: q('#hint').textContent,
        result: !result.hidden,
      };
      const key = JSON.stringify(state);
      if (key !== last) {
        last = key;
        qa.states.push({ t, ...state });
      }
    }
    requestAnimationFrame(sample);
  };
  requestAnimationFrame(sample);
};

const browser = await pw.chromium.launch({ headless: true });
const server = spawn('npx', ['vite', 'preview', '--host', '127.0.0.1', '--port', String(PORT), '--strictPort'], { cwd: CLIENT, stdio: 'ignore' });
for (let i = 0; i < 100; i++) {
  try {
    if ((await fetch(BASE)).ok) break;
  } catch {
    await sleep(200);
  }
}

async function open(device, query) {
  const context = await browser.newContext(device);
  await context.addInitScript(INIT);
  const page = await context.newPage();
  const console_ = [];
  page.on('console', (m) => console_.push(m.text()));
  page.on('pageerror', (e) => console_.push(`[pageerror] ${e.message}`));
  await page.goto(`${BASE}${query}`);
  await waitLog(page, /^level \w+: init/, 60000);
  await sleep(600);
  return { context, page, console: console_ };
}

async function waitLog(page, re, timeout = 180000) {
  const t = Date.now();
  while (Date.now() - t < timeout) {
    const hit = await page.evaluate((src) => window.__q1.logs.find((l) => new RegExp(src).test(l.text)) ?? null, re.source);
    if (hit) return hit;
    await sleep(100);
  }
  throw new Error(`timeout waiting for ${re}`);
}

const q1 = (page) => page.evaluate(() => window.__q1);
const tickOf = (s) => s.tick.split(' / ').map(Number);

/** When the panel opened, and what the HUD said then; when each shot re-armed against its worker's end. */
function gate(data) {
  const at = (re) => data.logs.filter((l) => re.test(l.text)).map((l) => l.t);
  const produced = at(/^shot \d+: first frame/);
  const shown = at(/^shot \d+: shown/);
  const panel = data.states.find((s) => s.result);
  const lastState = data.states.at(-1);
  const releases = at(/^shot \d+: release/);
  // Shots left right after each release (the first state sampled after it).
  const shotsAfterRelease = releases.map((t) => data.states.find((s) => s.t >= t)?.shots ?? null);
  return {
    releases: releases.map((t) => Math.round(t)),
    workerDoneMs: produced.map((t) => Math.round(t)),
    rearmedMs: shown.map((t) => Math.round(t)),
    rearmAfterWorkerMs: shown.map((t, i) => Math.round(t - produced[i])),
    panel: panel ? { t: Math.round(panel.t), afterWorkerMs: Math.round(panel.t - produced.at(-1)), hudTick: panel.tick, atLastTick: tickOf(panel)[0] === tickOf(panel)[1] } : null,
    shotsAfterRelease,
    endPlayLabel: lastState.play,
  };
}

const out = {};

// A. Desktop, the M2 repro: three weak shots by `autoshot`; the panel and each re-arm against the worker.
{
  const { context, page, console: lines } = await open({ viewport: { width: 1280, height: 800 } }, '?level=pile10&autoshot=-150,-150;-200,-200;-600,-392');
  await waitLog(page, /^level over/);
  await sleep(4000);
  await page.screenshot({ path: path.join(outDir, 'desktop-3shots-end.png') });
  out.threeShots = { ...gate(await q1(page)), outputs: lines.filter((l) => /^outputs|^level over/.test(l)) };
  await context.close();
}

// B. Desktop, keyboard: the owner's pile10 pull (-1022, -63), a release attempt during the playback, the end.
{
  const { context, page, console: lines } = await open({ viewport: { width: 1280, height: 800 } }, '?level=pile10');
  await page.screenshot({ path: path.join(outDir, 'desktop-start.png') });
  await page.mouse.click(640, 300); // focus the page, not a control
  for (let i = 0; i < 102; i++) await page.keyboard.press('Shift+ArrowLeft');
  for (let i = 0; i < 2; i++) await page.keyboard.press('ArrowLeft');
  for (let i = 0; i < 6; i++) await page.keyboard.press('Shift+ArrowDown');
  for (let i = 0; i < 3; i++) await page.keyboard.press('ArrowDown');
  const shownPull = await page.textContent('[data-hud="pull"]');
  await page.screenshot({ path: path.join(outDir, 'desktop-keyboard-aim.png') });
  await page.keyboard.press('Enter');
  await waitLog(page, /^shot 0: first frame/);
  // The worker is done, the playback is not: a second aim and Enter must do nothing (M3).
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('Enter');
  await sleep(400);
  await waitLog(page, /^outputs/);
  await sleep(1500);
  await page.screenshot({ path: path.join(outDir, 'desktop-owner-end.png') });
  const data = await q1(page);
  out.keyboard = {
    shownPull,
    released: lines.filter((l) => /release/.test(l)),
    extraReleases: lines.filter((l) => /^shot 1: release/.test(l)).length,
    ...gate(data),
    outputs: lines.filter((l) => /^outputs|^level over|^shot 0: first/.test(l)),
  };
  await context.close();
}

// C. Phones: layout, touch grab and drag, the result panel folded.
for (const [name, viewport] of [
  ['portrait-390x844', { width: 390, height: 844 }],
  ['landscape-844x390', { width: 844, height: 390 }],
]) {
  const device = { viewport, isMobile: true, hasTouch: true, deviceScaleFactor: 2 };
  const { context, page, console: lines } = await open(device, '?level=pile10');
  await page.screenshot({ path: path.join(outDir, `${name}-start.png`) });
  const layout = await page.evaluate(() => {
    const r = (s) => {
      const b = document.querySelector(s).getBoundingClientRect();
      return { left: Math.round(b.left), top: Math.round(b.top), right: Math.round(b.right), bottom: Math.round(b.bottom) };
    };
    const hint = document.querySelector('#hint');
    return {
      hint: { ...r('#hint'), text: hint.textContent, lines: Math.round(hint.getBoundingClientRect().height / parseFloat(getComputedStyle(hint).lineHeight)) },
      hud: r('#hud'),
      chainInfo: r('#chain-info'),
      controls: r('#controls'),
      scrollWidth: document.documentElement.scrollWidth,
    };
  });
  layout.hudOverChain = layout.hud.bottom > layout.chainInfo.top && layout.hud.right > layout.chainInfo.left;
  // The sling on screen, from the client's own camera code.
  const level = JSON.parse(fs.readFileSync(path.join(CLIENT, 'public/levels/pile10.json'), 'utf8'));
  const header = new lib.LevelHeader();
  for (const l of fs.readFileSync(path.join(CLIENT, 'vm/fixtures/pile10-reference.main_trace.txt'), 'utf8').split('\n')) {
    const p = /^(trace|level|material|body) /.test(l) ? lib.parseTraceLine(l) : null;
    if (p) header.push(p);
  }
  const traceLevel = header.level();
  const full = lib.fullPullPixels(viewport.width, viewport.height);
  const cam = lib.frameCamera(lib.frameRect(traceLevel), level.sling_anchor, full, viewport.width, viewport.height, { top: 0, bottom: 44 });
  const a = lib.worldToScreen(cam, level.sling_anchor.x, level.sling_anchor.y);
  const cdp = await context.newCDPSession(page);
  const touch = (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }] });
  // Grab 30 px off the pebble (inside the 44 px touch area), drag a full pull back and slightly down.
  const g = { x: a.x + 30, y: a.y };
  await touch('touchStart', g.x, g.y);
  for (let k = 1; k <= 8; k++) await touch('touchMove', g.x - (full * 0.99 * k) / 8, g.y + (full * 0.06 * k) / 8);
  await sleep(200);
  const touchPull = await page.textContent('[data-hud="pull"]');
  await page.screenshot({ path: path.join(outDir, `${name}-aim.png`) });
  await touch('touchEnd');
  await waitLog(page, /^shot 0: shown|^level over/);
  await sleep(1200);
  await page.screenshot({ path: path.join(outDir, `${name}-after.png`) });
  await context.close();

  // The result panel: the owner's shot by autoshot, folded, then unfolded.
  const second = await open(device, '?level=pile10&autoshot=-1022,-63');
  await waitLog(second.page, /^outputs/);
  await sleep(800);
  await second.page.screenshot({ path: path.join(outDir, `${name}-result-folded.png`) });
  const panel = async () =>
    second.page.evaluate(() => {
      const b = document.querySelector('#result').getBoundingClientRect();
      const c = document.querySelector('#controls').getBoundingClientRect();
      return { top: Math.round(b.top), bottom: Math.round(b.bottom), height: Math.round(b.height), overlapsControls: b.bottom > c.top, scrolls: document.querySelector('#result').scrollHeight > document.querySelector('#result').clientHeight };
    });
  const folded = await panel();
  await second.page.click('#result-toggle');
  await sleep(300);
  await second.page.screenshot({ path: path.join(outDir, `${name}-result-open.png`) });
  const opened = await panel();
  out[name] = {
    layout,
    fullPullPx: +full.toFixed(1),
    pxPerMetre: +cam.scale.toFixed(2),
    pullUnitsPerPx: +(1024 / full).toFixed(2),
    anchor: { x: Math.round(a.x), y: Math.round(a.y) },
    touchPull,
    touchLog: lines.filter((l) => /release|shot 0|level over/.test(l)),
    panel: { folded, opened },
    ownerShot: second.console.filter((l) => /^level over/.test(l)),
  };
  await second.context.close();
}

fs.writeFileSync(path.join(outDir, 'q1.json'), JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
await browser.close();
server.kill();
