// Smoke test of `npm run build:sepolia` (CI `client-build-sepolia`): the built page's entry script
// (the one `dist/index.html` loads; Vite inlines `VITE_*` there, not in the HTML) carries the
// contract address of deploy/sepolia.json, the Sepolia RPC and the Voyager Sepolia links.
//
//   node scripts/smoke-sepolia.mjs [dist] [base]      (from client/; base is VITE_BASE, default /)
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const client = fileURLToPath(new URL('..', import.meta.url));
const dist = process.argv[2] ?? join(client, 'dist');
const base = process.argv[3] ?? '/';
const { address } = JSON.parse(readFileSync(join(client, '..', 'deploy', 'sepolia.json'), 'utf8'));

const fail = (message) => {
  console.error(`smoke-sepolia: ${message}`);
  process.exit(1);
};

const html = readFileSync(join(dist, 'index.html'), 'utf8');
const entry = /<script[^>]*type="module"[^>]*src="([^"]+)"/.exec(html)?.[1];
if (!entry) fail('dist/index.html has no module script');
if (!entry.startsWith(`${base}assets/`)) fail(`entry ${entry} is not under ${base}assets/`);
const script = readFileSync(join(dist, entry.slice(base.length)), 'utf8');

if (!script.includes(address)) fail(`the entry script ${entry} does not contain the contract address ${address}`);
if (!script.includes('sepolia.voyager.online')) fail('no Voyager Sepolia link in the entry script');
if (!script.includes('starknet-sepolia-rpc.publicnode.com')) fail('the Sepolia RPC is not inlined in the entry script');
console.log(`smoke-sepolia: ok (${entry} carries ${address})`);
