// The client's dev server of `scripts/play.sh` (lot L1, docs/play-local.md): `client/vite.config.ts`
// plus a proxy, so that the page reaches the devnet and both services on its own origin. They stay
// on 127.0.0.1 whatever `PLAY_HOST` is (only this server listens there), and neither CORS nor a
// browser's local-network rules apply (Safari, a phone on the same network).
//   /rpc               -> the devnet            (PLAY_DEVNET_PORT, 5050)
//   /attest-service/*  -> the attestation service (PLAY_ATTEST_PORT, 8547)
//   /prove-service/*   -> the prover service      (PLAY_PROVE_PORT, 8549)
import { readFileSync } from 'node:fs';
import { resolve, sep } from 'node:path';
import { gzipSync } from 'node:zlib';
import client from '../../client/vite.config.ts';

const port = (name: string, fallback: number) => Number(process.env[name] ?? fallback);
const local = (p: number) => `http://127.0.0.1:${p}`;
const strip = (prefix: string) => (path: string) => path.slice(prefix.length) || '/';

// `vite preview` (PLAY_BUILT=1) gzips JS and JSON but not the 1.5 MB wasm runner: its compression filter
// does not know `application/wasm`. This answers `*.wasm` itself, gzipped (cached), before the static files.
const gzipWasm = {
  name: 'play-gzip-wasm',
  configurePreviewServer(server: any) {
    const dist = resolve(server.config.root, server.config.build.outDir);
    const cache = new Map<string, Buffer>();
    server.middlewares.use((req: any, res: any, next: () => void) => {
      const path = decodeURIComponent((req.url ?? '').split('?')[0]);
      const file = resolve(dist, `.${path}`);
      if (!path.endsWith('.wasm') || !file.startsWith(dist + sep) || !/\bgzip\b/.test(req.headers['accept-encoding'] ?? '')) {
        return next();
      }
      try {
        let body = cache.get(file);
        if (!body) cache.set(file, (body = gzipSync(readFileSync(file))));
        res.setHeader('Content-Type', 'application/wasm');
        res.setHeader('Content-Encoding', 'gzip');
        res.setHeader('Vary', 'Accept-Encoding');
        res.setHeader('Content-Length', body.length);
        res.end(body);
      } catch {
        next();
      }
    });
  },
};

export default {
  ...client,
  plugins: [...(client.plugins ?? []), gzipWasm],
  server: {
    proxy: {
      '/rpc': { target: local(port('PLAY_DEVNET_PORT', 5050)) },
      '/attest-service': { target: local(port('PLAY_ATTEST_PORT', 8547)), rewrite: strip('/attest-service') },
      '/prove-service': { target: local(port('PLAY_PROVE_PORT', 8549)), rewrite: strip('/prove-service') },
    },
  },
};
