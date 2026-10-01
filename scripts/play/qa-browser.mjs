// Drives the page of `scripts/play.sh up` in a real browser (lot L2): the start, one shot on pile10 with the
// pull (-1022, -63) by keyboard, the provisional record, the proven path, the settled path, both boards.
//   node scripts/play/qa-browser.mjs <baseUrl> <outDir> [--headed]
// Playwright comes from PLAYWRIGHT_MODULE (a directory), else from `playwright` resolved from here.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const require = createRequire(import.meta.url);
const load = () => {
  for (const m of [process.env.PLAYWRIGHT_MODULE, 'playwright']) {
    try {
      if (m) return require(m);
    } catch {}
  }
  throw new Error('playwright not found: set PLAYWRIGHT_MODULE');
};
const pw = load();
const [base, outDir] = process.argv.slice(2);
const headed = process.argv.includes('--headed');
fs.mkdirSync(outDir, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await pw.chromium.launch({ headless: !headed });
const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });
const page = await context.newPage();
const logs = [];
const errors = [];
const bad = [];
page.on('console', (m) => {
  logs.push(m.text());
  if (m.type() === 'error') errors.push(m.text());
});
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
page.on('response', (r) => {
  if (r.status() >= 400) bad.push(`${r.status()} ${r.url()}`);
});
page.on('requestfailed', (r) => bad.push(`failed ${r.url()} ${r.failure()?.errorText}`));

const t0 = Date.now();
const steps = [];
const mark = (name, since) => {
  const ms = Date.now() - since;
  steps.push({ step: name, ms });
  console.log(`${name}: ${ms} ms`);
};
const shot = (name) => page.screenshot({ path: path.join(outDir, name) });
const status = () => page.evaluate(() => document.querySelector('.submit-status')?.textContent ?? '');
const waitFor = async (what, fn, timeout = 240000) => {
  const t = Date.now();
  while (Date.now() - t < timeout) {
    const v = await fn();
    if (v) return v;
    await sleep(100);
  }
  throw new Error(`timeout: ${what}; status: ${await status()}`);
};
const waitStatus = (what, re) => waitFor(what, async () => ((await status()).match(re) ? status() : null));
const button = (name) => page.getByRole('button', { name });

// 1. the start
let t = Date.now();
await page.goto(`${base}?level=pile10`);
await waitFor('level init', () => logs.some((l) => /^level pile10: init/.test(l)));
await waitFor('the account is connected', async () => (await page.evaluate(() => document.querySelector('.submit h3')?.textContent)) !== null);
mark('page load to level init', t);
await sleep(500);
console.log('banner:', JSON.stringify(await page.evaluate(() => document.querySelector('#banner')?.textContent)));
console.log('chain-info:', JSON.stringify(await page.evaluate(() => document.querySelector('#chain-info')?.innerText)));
await shot('01-start.png');

async function shoot(label, left, down) {
  // 2. the pull by the arrow keys: Shift = 10 units, then single steps (the aim starts at (0, 0)).
  t = Date.now();
  await page.locator('#app canvas').click({ position: { x: 5, y: 5 } }).catch(() => {});
  await page.keyboard.down('Shift');
  for (let i = 0; i < Math.floor(left / 10); i++) await page.keyboard.press('ArrowLeft');
  for (let i = 0; i < Math.floor(down / 10); i++) await page.keyboard.press('ArrowDown');
  await page.keyboard.up('Shift');
  for (let i = 0; i < left % 10; i++) await page.keyboard.press('ArrowLeft');
  for (let i = 0; i < down % 10; i++) await page.keyboard.press('ArrowDown');
  mark(`${label}: keyboard aim (-${left}, -${down})`, t);
  await sleep(300);
  await shot(`02-${label}-aimed.png`);
  t = Date.now();
  await page.keyboard.press('Enter');
  await waitFor('result panel', () => page.evaluate(() => { const r = document.querySelector('#result'); return r && !r.hidden; }));
  await waitFor('Submit enabled', () => button('Submit').isEnabled().catch(() => false));
  mark(`${label}: shot to result panel`, t);
}
const tier = () => page.evaluate(() => document.querySelector('.submit-tier')?.textContent ?? '');
const boards = () => page.evaluate(() => document.querySelector('.submit-boards')?.innerText);
/** Logs each distinct text of the tier line while waiting for `re`. */
async function followTier(what, re) {
  let last = '';
  return waitFor(what, async () => {
    const v = await tier();
    if (v !== last) {
      last = v;
      console.log(`  [${((Date.now() - t0) / 1000).toFixed(1)} s] tier: ${v}`);
    }
    return re.test(v) ? v : null;
  }, 420000);
}
const submit = async (label) => {
  t = Date.now();
  await button('Submit').click();
  await waitFor('provisional record', async () => /^Provisional record/.test(await status()));
  mark(`${label}: Submit to the provisional record`, t);
  console.log('status:', await status());
};

// --second-only: the first attempt is already recorded on this devnet (a re-run after a failure).
if (!process.argv.includes('--second-only')) {
await shoot('first', 1022, 63);
await shot('03-result-panel.png');
console.log('result:', JSON.stringify(await page.evaluate(() => document.querySelector('#result')?.innerText)));

// 3. the provisional record
await submit('first');
await sleep(1000);
await shot('04-provisional-record.png');

// 4. the proven path
t = Date.now();
await button('Prove (SNIP-36, simulated)').click();
await followTier('proven', /^(Proven|.*(failed|error|refused))/i);
mark('Prove (SNIP-36, simulated) to its end', t);
await sleep(1500);
await shot('05-proven-path.png');
console.log('boards:', JSON.stringify(await boards()));
}

// 5. the settled path: the contract records an attempt proven or settled, not both, and refuses the same
// attempt twice: reload and play another pull (-1020, -63). (The pull is clamped to a radius of 1024:
// (-1022, -64) would be the first attempt again.)
await page.goto(`${base}?level=pile10`);
await waitFor('level init', () => logs.filter((l) => /^level pile10: init/.test(l)).length >= 2);
await sleep(500);
await shoot('second', 1020, 63);
console.log('result:', JSON.stringify(await page.evaluate(() => document.querySelector('#result')?.innerText.split('\n').slice(0, 3))));
await submit('second');
t = Date.now();
await button('Settle (Atlantic, simulated)').click();
await followTier('settled', /^(Settled|.*(failed|error|refused))/i);
mark('Settle (Atlantic, simulated) to its end', t);
await sleep(1500);
await shot('06-settled-path.png');
console.log('boards:', JSON.stringify(await boards()));
await page.locator('.submit-boards').scrollIntoViewIfNeeded().catch(() => {});
await shot('07-boards.png');

mark('whole run', t0);
console.log('console errors:', JSON.stringify(errors));
console.log('bad responses:', JSON.stringify(bad));
fs.writeFileSync(path.join(outDir, 'run.json'), JSON.stringify({ steps, errors, bad, logs: logs.slice(-40) }, null, 2));
await browser.close();
