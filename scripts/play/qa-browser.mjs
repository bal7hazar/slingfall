// Drives the page of `scripts/play.sh up` in a real browser (lot L2): the start, one shot on pile10 with the
// pull (-1022, -63) by keyboard, the provisional record, the proven path, the settled path, both boards.
//   node scripts/play/qa-browser.mjs <baseUrl> <outDir> [--headed] [--second-only] [--fixture]
// --second-only: the first attempt is already recorded on this devnet (a re-run after a failure).
// --fixture (lot L3, a machine without the wasm VM and the devnet: no full run): the real page and its real
// stylesheet from the dev server, the real `SubmitPanel` over fakes of the contract and of the services; prints
// the banner, the share of the viewport the end-of-level panel covers, and the state of the tier buttons.
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
const [base, outDir] = process.argv.slice(2).filter((a) => !a.startsWith('--'));
if (!base || !outDir) {
  console.error('usage: node scripts/play/qa-browser.mjs <baseUrl> <outDir> [--headed] [--second-only] [--fixture]');
  process.exit(2);
}
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
const waitFor = async (what, fn, timeout = process.argv.includes('--fixture') ? 20000 : 240000) => {
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

const tier = () => page.evaluate(() => document.querySelector('.submit-tier')?.textContent ?? '');

// Fixture mode (lot L3): the page without the VM (the recorded fallback keeps the banner), the panel by import.
async function fixture() {
  await page.goto(`${base}?level=pile10`);
  await waitFor('page loaded', () => page.evaluate(() => document.querySelector('#banner') !== null));
  await sleep(1500);
  const banner = await page.evaluate(() => {
    const b = document.querySelector('#banner');
    const r = b.getBoundingClientRect();
    return { text: b.textContent, hidden: b.hidden, shown: r.width > 0 && r.height > 0 };
  });
  console.log('banner:', JSON.stringify(banner));
  await shot('01-banner.png');
  await page.evaluate(async () => {
    const PLAYER = '0x706c61796572';
    const LEVEL = '0x17876831f245e0ec3d63220f2cb73c429ec93e7c888c2aa916d237cd9c114a3';
    const { SubmitPanel } = await import('/src/chain/panel.ts');
    const { SlingfallContract, feltHex } = await import('/src/chain/slingfall.ts');
    let proven = false;
    const best = (score) => [feltHex(score), '0x1', '0xabc', '0x3', '0x64', score ? '0x1' : '0x0', score ? '0xbd' : '0x0'];
    const reader = {
      callContract: async ({ entrypoint }) => {
        if (entrypoint === 'verifier') return ['0x1'];
        if (entrypoint === 'best') return best(5300);
        if (entrypoint === 'best_settled') return best(proven ? 5300 : 0);
        if (entrypoint === 'leaderboard') return proven ? ['0x1', PLAYER, '0x14b4'] : ['0x0'];
        if (entrypoint === 'leaderboard_provisional') return ['0x1', PLAYER, '0x14b4'];
        if (entrypoint === 'current_program') return ['0xc1'];
        throw new Error(`unexpected read ${entrypoint}`);
      },
    };
    const job = { id: 'f55f0fdd2eeb24d7d4ab25e6aeaaf0f2', tier: 'proven', state: 'queued', level_hash: LEVEL, inputs: [], proofs: [] };
    const json = (body, status = 200) => new Response(JSON.stringify(body), { status });
    const fetchFn = async (input) => {
      const url = String(input);
      if (url.endsWith('/health')) return json({ result: 'x', submit: true, queued: 0, program_hash: '0xc1', contract_program_hash: '0xc1', program_match: true, relay: null, proven: { available: true, prover: 'fake', chain: '0xc4a1', own_bundle_hash: '0xbd', chain_match: true } });
      if (url.endsWith('/prove')) return json(job, 202);
      proven = true;
      return json({ ...job, state: 'proven', proven: true, finalize_transaction_hash: '0xfeed' });
    };
    const config = { address: '0x5afe', network: 'devnet', rpcUrl: 'http://rpc', explorerUrl: null, attestUrl: 'http://attest', proveUrl: 'http://prove', devnetAccount: { address: PLAYER, privateKey: '0x1' }, deployBlock: 0, local: true };
    const deps = {
      contract: new SlingfallContract('0x5afe', reader),
      waitForReceipt: async () => ({}),
      connect: async () => ({ address: PLAYER, execute: async () => ({ transaction_hash: '0x1' }) }),
      events: { getEvents: async () => ({ events: [] }) },
      fetchFn,
      sleep: (ms) => new Promise((r) => setTimeout(r, Math.min(ms, 50))),
    };
    const result = document.querySelector('#result');
    const summary = document.querySelector('[data-result="summary"]');
    document.querySelector('[data-result="title"]').textContent = 'Level won';
    summary.textContent = 'Score 5300 · shots 1 · 151 ticks · the outputs a proof will carry:';
    const rows = ['version', 'level_hash', 'status', 'player', 'inputs_hash', 'score', 'shots_used', 'ticks', 'final_state_hash', 'checkpoint'];
    document.querySelector('[data-result="outputs"]').replaceChildren(
      ...rows.map((name) => Object.assign(document.createElement('tr'), { innerHTML: `<th>${name}</th><td>0x${'ab12'.repeat(8)}</td>` })),
    );
    result.querySelector('.submit')?.remove(); // the page's own panel (no devnet here): the fixture's replaces it
    const panel = new SubmitPanel(result, config, deps);
    window.__panel = panel;
    // main.ts `finish` opens the panel like this: folded (the fold helper exists since lot L3), then the offer.
    try {
      const { foldResult } = await import('/src/render/result.ts');
      foldResult(result, document.querySelector('#result-toggle'), true);
    } catch {}
    result.hidden = false;
    await new Promise((r) => setTimeout(r, 300));
    panel.offer(LEVEL, async () => ['0x1', LEVEL, '0x0', PLAYER, '0xabc', '0x14b4', '0x1', '0x97', '0x1af', '0x33'], () => [PLAYER, '0x1']);
    // The state after "Submit" in the local mode (the provisional record), without the attestation round trip.
    panel.choice = { levelHash: LEVEL, outputs: ['0x1', LEVEL], inputs: [PLAYER, '0x1'] };
    panel.outputsFor = null;
    panel.tier.textContent = 'Provisional (attested) · ask for a proof: proven (SNIP-36) or settled (Atlantic), both simulated here';
    panel.tiers.hidden = false;
  });
  await sleep(500);
  const measure = () =>
    page.evaluate(() => {
      const r = document.querySelector('#result').getBoundingClientRect();
      const w = innerWidth;
      const h = innerHeight;
      const tiers = document.querySelector('.submit-tiers');
      const visible = (el) => el.getBoundingClientRect().width > 0;
      return {
        viewport: `${w}x${h}`,
        folded: document.querySelector('#result').classList.contains('folded'),
        panel: `${Math.round(r.width)}x${Math.round(r.height)} at (${Math.round(r.left)}, ${Math.round(r.top)})`,
        coversOfViewport: `${((r.width * r.height * 100) / (w * h)).toFixed(1)} %`,
        coversOfWidth: `${((r.width * 100) / w).toFixed(1)} %`,
        tierButtons: [...tiers.querySelectorAll('button')].map((b) => ({ label: b.textContent, visible: visible(b), enabled: !b.disabled })),
      };
    });
  console.log('panel before the proof:', JSON.stringify(await measure()));
  await shot('02-panel-folded.png');
  // The details open: the buttons are there to press (the Submit step lives in the details).
  await page.evaluate(() => { const r = document.querySelector('#result'); if (r.classList.contains('folded')) document.querySelector('#result-toggle').click(); });
  await sleep(300);
  console.log('panel opened:', JSON.stringify(await measure()));
  await shot('03-panel-opened-tiers.png');
  await button('Prove (SNIP-36, simulated)').click({ force: true }).catch(() => {});
  await waitFor('proven', async () => /^Proven/.test(await tier()));
  await sleep(800);
  console.log('tier line:', JSON.stringify(await tier()));
  console.log('panel after the proof:', JSON.stringify(await measure()));
  await shot('04-after-proof.png');
  console.log('console errors:', JSON.stringify(errors));
}
if (process.argv.includes('--fixture')) {
  await fixture();
  await browser.close();
  process.exit(0);
}

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
