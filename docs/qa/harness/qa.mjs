// QA harness of the 2026-09-26 Mac session (docs/qa/2026-09-26-mac.md): drives the Slingfall client
// in a real browser through Playwright and records load, per-shot figures, playback smoothness,
// memory, outputs and screenshots.
//
//   node docs/qa/harness/qa.mjs <chrome|firefox|webkit> <baseUrl> <outDir> <load [n] | shots cases.json | arc arcs.json>
//
// PLAYWRIGHT_MODULE: path of a `playwright` package (default: the npx cache entry of 1.59.1 used
// here, whose browsers were already installed). `qa-lib.mjs` is the client's own aim / camera /
// trace code, bundled by `build-lib.sh`. Environment: QA_W, QA_H (viewport), QA_HEADLESS=1.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import * as lib from './qa-lib.mjs';

const require = createRequire(import.meta.url);
const pw = require(process.env.PLAYWRIGHT_MODULE ?? path.join(process.env.HOME, '.npm/_npx/420ff84f11983ee5/node_modules/playwright'));

const [browserName, baseUrl, outDir, scenario, ...args] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const VIEWPORT = { width: Number(process.env.QA_W ?? 1280), height: Number(process.env.QA_H ?? 800) };
const HEADLESS = process.env.QA_HEADLESS === '1';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Injected before the page's scripts: console, worker messages, rAF times, HUD and slow-motion changes. */
const INIT = () => {
  const qa = (window.__qa = { logs: [], raf: [], hud: [], sim: [], frames: [], lines: [], chunks: [], done: [], events: [], errors: [] });
  for (const level of ['log', 'warn', 'error', 'info']) {
    const orig = console[level].bind(console);
    console[level] = (...a) => {
      qa.logs.push({ t: performance.now(), level, text: a.map((x) => (x instanceof Error ? `${x.name}: ${x.message}` : typeof x === 'object' ? JSON.stringify(x) : String(x))).join(' ') });
      orig(...a);
    };
  }
  window.addEventListener('error', (e) => qa.errors.push({ t: performance.now(), text: String(e.message) }));
  window.addEventListener('unhandledrejection', (e) => qa.errors.push({ t: performance.now(), text: String(e.reason) }));
  const W = window.Worker;
  window.Worker = class extends W {
    constructor(u, o) {
      super(u, o);
      this.addEventListener('message', (e) => {
        const m = e.data;
        const t = performance.now();
        if (m.type === 'frame') qa.frames.push({ t, id: m.id, frame: m.frame });
        else if (m.type === 'line') qa.lines.push(m.line);
        else if (m.type === 'chunk') qa.chunks.push({ t, id: m.id, chunk: m.chunk });
        else if (m.type === 'event') qa.events.push({ t, id: m.id, event: m.event });
        else if (m.type === 'done') qa.done.push({ t, id: m.id });
        else if (m.type === 'loaded') qa.loaded = { t, ms: m.ms, wasmBytes: m.wasmBytes };
        else if (m.type === 'error') qa.errors.push({ t, text: `worker: ${m.message}` });
      });
    }
  };
  const loop = (t) => {
    qa.raf.push(t);
    requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);
  document.addEventListener('DOMContentLoaded', () => {
    const hud = document.querySelector('#hud');
    const sim = document.querySelector('#simulating');
    const result = document.querySelector('#result');
    if (hud) new MutationObserver(() => qa.hud.push({ t: performance.now(), text: hud.textContent })).observe(hud, { subtree: true, childList: true, characterData: true });
    if (sim) new MutationObserver(() => qa.sim.push({ t: performance.now(), hidden: sim.hidden })).observe(sim, { attributes: true, attributeFilter: ['hidden'] });
    if (result) new MutationObserver(() => { if (!result.hidden && qa.panelAt === undefined) qa.panelAt = performance.now(); }).observe(result, { attributes: true, attributeFilter: ['hidden'] });
  });
};

function psTree() {
  const out = execFileSync('ps', ['-axo', 'pid=,ppid=,rss=,command='], { encoding: 'utf8', maxBuffer: 64 << 20 });
  return out.split('\n').filter(Boolean).map((l) => {
    const m = l.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
    return { pid: +m[1], ppid: +m[2], rss: +m[3] * 1024, cmd: m[4] };
  });
}

/** RSS of the Playwright-launched browser's process tree (one harness at a time). */
function memory() {
  const all = psTree();
  const marker = /playwright_(chromiumdev|firefoxdev|firefox|webkit)_profile|playwright_chromium|pw_run|Playwright\.app/;
  const rootProc = all.find((p) => marker.test(p.cmd) && !/--type=/.test(p.cmd) && !/contentproc/.test(p.cmd) && !all.some((q) => q.pid === p.ppid && marker.test(q.cmd)));
  if (!rootProc) return null;
  const kids = new Map();
  for (const p of all) (kids.get(p.ppid) ?? kids.set(p.ppid, []).get(p.ppid)).push(p);
  const tree = [rootProc];
  const walk = (pid) => {
    for (const c of kids.get(pid) ?? []) {
      tree.push(c);
      walk(c.pid);
    }
  };
  walk(rootProc.pid);
  const mb = (b) => Math.round(b / 2 ** 20);
  const top = [...tree].sort((x, y) => y.rss - x.rss).slice(0, 3).map((p) => `${mb(p.rss)}MB ${p.cmd.split(' ')[0].split('/').pop()} ${(p.cmd.match(/--type=\S+|-isForBrowser|\btab\b|gpu-process|utility/g) ?? []).join(',')}`);
  return { totalMB: mb(tree.reduce((s, p) => s + p.rss, 0)), top, processes: tree.length };
}

async function launch() {
  const type = browserName === 'firefox' ? pw.firefox : browserName === 'webkit' ? pw.webkit : pw.chromium;
  const opts = { headless: HEADLESS };
  if (browserName === 'chrome') opts.channel = 'chrome';
  if (process.env.QA_DEVTOOLS === '1') opts.devtools = true; // DevTools open on every tab (Chromium)
  return type.launch(opts);
}

async function newPage(browser) {
  const context = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: 2 });
  await context.addInitScript(INIT);
  const page = await context.newPage();
  const consoleLines = [];
  page.on('console', (m) => consoleLines.push(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => consoleLines.push(`[pageerror] ${e.message}`));
  return { context, page, consoleLines };
}

async function waitFor(page, pred, timeout = 120000, what = 'condition') {
  const t = Date.now();
  while (Date.now() - t < timeout) {
    if (await page.evaluate(pred)) return;
    await sleep(100);
  }
  throw new Error(`timeout waiting for ${what}`);
}

const logsMatching = (page, re) => page.evaluate((src) => window.__qa.logs.filter((l) => new RegExp(src).test(l.text)), re);

async function waitLog(page, re, timeout = 300000) {
  const t = Date.now();
  while (Date.now() - t < timeout) {
    const found = await logsMatching(page, re);
    if (found.length > 0) return found;
    await sleep(100);
  }
  throw new Error(`timeout waiting for log ${re}`);
}

/** Playback of one shot: rAF rate, displayed ticks over time, slow-motion spans. */
function analyse(q, from, to) {
  const raf = q.raf.filter((t) => t >= from && t <= to);
  const gaps = raf.slice(1).map((t, i) => t - raf[i]).sort((a, b) => a - b);
  const pct = (p) => (gaps.length ? +gaps[Math.min(gaps.length - 1, Math.floor(p * gaps.length))].toFixed(1) : null);
  const dur = raf.length > 1 ? raf[raf.length - 1] - raf[0] : 0;
  const hud = q.hud.filter((h) => h.t >= from && h.t <= to);
  let hudStall = 0;
  for (let i = 1; i < hud.length; i++) hudStall = Math.max(hudStall, hud[i].t - hud[i - 1].t);
  let simMs = 0;
  let on = null;
  for (const s of q.sim.filter((s) => s.t >= from && s.t <= to)) {
    if (!s.hidden && on === null) on = s.t;
    if (s.hidden && on !== null) {
      simMs += s.t - on;
      on = null;
    }
  }
  if (on !== null) simMs += to - on;
  return {
    rafFps: dur > 0 ? +(((raf.length - 1) * 1000) / dur).toFixed(1) : null,
    frameMsP50: pct(0.5),
    frameMsP95: pct(0.95),
    frameMsMax: gaps.length ? +gaps[gaps.length - 1].toFixed(1) : null,
    framesOver50ms: gaps.filter((g) => g > 50).length,
    hudMaxStallMs: +hudStall.toFixed(0),
    slowMotionMs: +simMs.toFixed(0),
  };
}

async function levelHeader(page) {
  const lines = await page.evaluate(() => window.__qa.lines.slice());
  const header = new lib.LevelHeader();
  for (const l of lines) {
    const p = lib.parseTraceLine(l);
    if (p) header.push(p);
  }
  return header.level();
}

async function panel(page) {
  return page.evaluate(() => ({
    title: document.querySelector('[data-result="title"]')?.textContent,
    summary: document.querySelector('[data-result="summary"]')?.textContent,
    outputs: Object.fromEntries([...document.querySelectorAll('[data-result="outputs"] tr')].map((r) => [r.querySelector('th')?.textContent, r.querySelector('td')?.textContent])),
  }));
}

const hudTick = (text) => Number((text.match(/Tick\s*(\d+)/) ?? [])[1]);

/** Plays `pulls` through `?autoshot=` and records every shot. */
async function shots(page, name, level, pulls, opts = {}) {
  const res = { name, level, pulls, shots: [] };
  await page.goto(`${baseUrl}?level=${level}&autoshot=${pulls.map((p) => p.join(',')).join(';')}`);
  await waitLog(page, `^level ${level}: init`);
  res.init = (await logsMatching(page, '^(vm: loaded|level )')).map((l) => `${l.text} @${l.t.toFixed(0)}ms`);
  res.bodies = (await levelHeader(page)).bodies.length;
  const captures = [...(opts.captures ?? [])];
  const [rel0] = await waitLog(page, '^shot 0: release');
  for (const ms of captures) {
    const now = await page.evaluate(() => performance.now());
    if (rel0.t + ms > now) await sleep(rel0.t + ms - now);
    await page.screenshot({ path: path.join(outDir, `${name}-t${ms}.png`) });
  }
  // Wait for the level's end (all pulls, or a win earlier), then for the playback to show its last tick.
  await waitLog(page, '^outputs \\(|^level over');
  await waitLog(page, '^outputs \\(');
  const lastTick = await page.evaluate(() => { const l = window.__qa.logs.find((x) => /^level over/.test(x.text)); return l ? Number(l.text.match(/ticks (\d+)/)[1]) : null; });
  await waitFor(page, `(() => { const h = window.__qa.hud.at(-1); return (h && ${lastTick} !== null && Number((h.text.match(/Tick\\s*(\\d+)/) ?? [])[1]) >= ${lastTick}) || performance.now() - h.t > 3000; })()`, 180000, 'playback end');
  const q = await page.evaluate(() => ({ raf: window.__qa.raf, hud: window.__qa.hud, sim: window.__qa.sim, logs: window.__qa.logs, chunks: window.__qa.chunks, panelAt: window.__qa.panelAt }));
  const releases = q.logs.filter((l) => /^shot \d+: release/.test(l.text));
  const figures = q.logs.filter((l) => /^shot \d+: first frame/.test(l.text));
  for (let i = 0; i < releases.length; i++) {
    const rel = releases[i];
    const fig = figures[i];
    const shotTick = Number(fig.text.match(/tick (\d+)$/)[1]);
    const shown = q.hud.find((h) => hudTick(h.text) >= shotTick && h.t >= rel.t);
    const end = shown ? shown.t : q.hud.at(-1).t;
    res.shots.push({ release: rel.text, figures: fig.text, simulatedMs: +(fig.t - rel.t).toFixed(0), playbackMs: +(end - rel.t).toFixed(0), ...analyse(q, rel.t, end) });
  }
  const over = q.logs.find((l) => /^level over/.test(l.text));
  res.levelOver = over?.text;
  res.outputsLog = q.logs.find((l) => /^outputs \(/.test(l.text))?.text;
  res.panel = await panel(page);
  res.panelShownBeforePlaybackEndMs = q.panelAt !== undefined ? +(q.hud.at(-1).t - q.panelAt).toFixed(0) : null;
  res.chunks = q.chunks.map((c) => ({ id: c.id, ...c.chunk, mb: Math.round(c.chunk.wasmBytes / 2 ** 20) }));
  return res;
}

/** Aims with the mouse like a player, screenshots the arc, releases, then compares arc and flight. */
async function arcCheck(page, level, pull, name) {
  await page.goto(`${baseUrl}?level=${level}`);
  await waitLog(page, `^level ${level}: init`);
  await waitFor(page, `document.querySelector('#hint')?.textContent.startsWith('Drag')`, 30000, 'hint');
  const lvl = await levelHeader(page);
  const geo = await page.evaluate(() => {
    const r = document.querySelector('#app canvas').getBoundingClientRect();
    return { left: r.left, top: r.top, width: r.width, height: r.height };
  });
  const camera = lib.fitCamera(lib.boundsOf(lvl), geo.width, geo.height, { top: 0, bottom: 44 });
  const ax = lib.fixedToNumber(lvl.sling_anchor.x);
  const ay = lib.fixedToNumber(lvl.sling_anchor.y);
  const a = lib.worldToScreen(camera, ax, ay);
  const drag = lib.pullToDrag({ x: pull[0], y: pull[1] }, lvl.pull_radius);
  const target = lib.worldToScreen(camera, ax + drag.dx, ay + drag.dy);
  const px = Math.round(target.x);
  const py = Math.round(target.y);
  const w = { x: (px - camera.offsetX) / camera.scale, y: (camera.offsetY - py) / camera.scale };
  const predicted = lib.pullFromDrag(w.x - ax, w.y - ay, lvl.pull_radius);
  await page.mouse.move(geo.left + a.x, geo.top + a.y);
  await page.mouse.down();
  await page.mouse.move(geo.left + px, geo.top + py, { steps: 8 });
  await sleep(250);
  const aim = path.join(outDir, `${name}-aim.png`);
  await page.screenshot({ path: aim });
  await page.mouse.up();
  const [rel] = await waitLog(page, '^release: pull');
  const [fig] = await waitLog(page, '^shot 0: first frame');
  const released = rel.text.match(/\((-?\d+), (-?\d+)\)/).slice(1).map(Number);
  const q = await page.evaluate(() => ({ frames: window.__qa.frames, events: window.__qa.events }));
  const pebble = lvl.bodies.length; // shot 0's pebble handle
  const params = lib.arcParamsFromLevel(lvl);
  const dots = lib.flightArc(params, { x: released[0], y: released[1] });
  const free = lib.flightArc({ ...params, obstacles: [] }, { x: released[0], y: released[1] });
  const flight = q.frames.map((f) => ({ tick: f.frame.tick, b: f.frame.bodies.find((b) => b.handle === pebble) })).filter((f) => f.b);
  let exact = 0;
  let firstDivergence = null;
  for (let i = 0; i < free.length && i < flight.length; i++) {
    const f = flight[i];
    const p = free[i];
    if (f.tick === i + 1 && BigInt(f.b.x) === p.x && BigInt(f.b.y) === p.y) exact++;
    else {
      firstDivergence = { tick: f.tick, dx: +(lib.fixedToNumber(f.b.x) - lib.fixedToNumber(p.x.toString())).toFixed(3), dy: +(lib.fixedToNumber(f.b.y) - lib.fixedToNumber(p.y.toString())).toFixed(3) };
      break;
    }
  }
  const firstHit = q.events.find((e) => e.event.kind === 'damage' || e.event.kind === 'destroyed');
  await waitFor(page, `(() => { const h = window.__qa.hud.at(-1); return h && performance.now() - h.t > 1500; })()`, 120000, 'playback idle');
  if ((await page.evaluate(() => document.querySelector('#play').textContent)) === 'Pause') await page.click('#play');
  const frames = [];
  for (let tick = 2; tick <= Math.min(dots.length + 4, flight.length); tick += 2) {
    await page.evaluate((v) => {
      const s = document.querySelector('#scrub');
      s.value = String(v);
      s.dispatchEvent(new Event('input'));
    }, tick);
    await sleep(60);
    const f = path.join(outDir, `${name}-f${tick}.png`);
    await page.screenshot({ path: f });
    frames.push(f);
  }
  return {
    level, wantedPull: pull, predictedPull: predicted, releasedPull: released, figures: fig.text,
    pointer: { anchor: a, target: { x: px, y: py }, pxPerMetre: +camera.scale.toFixed(2), pullUnitsPerPx: +(lvl.pull_radius / 3 / camera.scale).toFixed(1) },
    arcDots: dots.length, freeFlightTicksBitExact: exact, firstDivergence, firstHitTick: firstHit?.event.tick ?? null, aim, frames,
  };
}

async function main() {
  const browser = await launch();
  const results = { browser: browserName, version: browser.version(), viewport: VIEWPORT, headless: HEADLESS, baseUrl, scenario, started: new Date().toISOString() };
  try {
    if (scenario === 'load') {
      results.loads = [];
      for (let i = 0; i < Number(args[0] ?? 3); i++) {
        const { context, page, consoleLines } = await newPage(browser); // fresh context: cold cache
        const t0 = Date.now();
        await page.goto(baseUrl);
        await waitLog(page, '^level pile10: init');
        await waitFor(page, `document.querySelector('#hint')?.textContent.startsWith('Drag')`, 30000, 'hint');
        const r = await page.evaluate(() => {
          const n = performance.getEntriesByType('navigation')[0];
          return { nav: { ttfb: Math.round(n.responseStart), dcl: Math.round(n.domContentLoadedEventEnd) }, loaded: window.__qa.loaded, ready: window.__qa.hud.at(-1)?.t, logs: window.__qa.logs.map((l) => `@${l.t.toFixed(0)}ms ${l.text}`) };
        });
        results.loads.push({ wallMs: Date.now() - t0, nav: r.nav, vmLoadedAtMs: Math.round(r.loaded.t), vmLoadMs: Math.round(r.loaded.ms), playableAtMs: Math.round(r.ready), logs: r.logs, console: consoleLines.filter((l) => !l.startsWith('[log]') && !l.includes('[vite]')), memory: memory() });
        if (i === 0) await page.screenshot({ path: path.join(outDir, `${browserName}-load.png`) });
        await context.close();
      }
    } else if (scenario === 'shots') {
      const cases = JSON.parse(fs.readFileSync(args[0], 'utf8'));
      const { context, page, consoleLines } = await newPage(browser);
      results.cases = [];
      for (const c of cases) {
        const r = await shots(page, `${browserName}-${c.name}`, c.level, c.pulls, { captures: c.captures });
        r.memory = memory();
        if (c.screenshot) await page.screenshot({ path: path.join(outDir, `${browserName}-${c.name}-end.png`) });
        results.cases.push(r);
        console.error(`${c.name}: ${r.levelOver} | ${r.shots.map((s) => s.figures).join(' || ')}`);
      }
      results.errors = await page.evaluate(() => window.__qa.errors);
      results.console = [...new Set(consoleLines.filter((l) => !l.startsWith('[log]') && !l.includes('[vite]')))];
      await context.close();
    } else if (scenario === 'arc') {
      const cases = JSON.parse(fs.readFileSync(args[0], 'utf8'));
      const { context, page, consoleLines } = await newPage(browser);
      results.arcs = [];
      for (const c of cases) {
        const r = await arcCheck(page, c.level, c.pull, `${browserName}-arc-${c.name}`);
        results.arcs.push({ name: c.name, ...r });
        console.error(c.name, JSON.stringify({ ...r, frames: r.frames.length }));
      }
      results.console = [...new Set(consoleLines.filter((l) => !l.startsWith('[log]') && !l.includes('[vite]')))];
      await context.close();
    } else {
      throw new Error(`unknown scenario ${scenario}`);
    }
  } finally {
    results.finished = new Date().toISOString();
    fs.writeFileSync(path.join(outDir, `${browserName}-${scenario}.json`), JSON.stringify(results, null, 2));
    await browser.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
