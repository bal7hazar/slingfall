// The client's dev server of `scripts/play.sh` (lot L1, docs/play-local.md): `client/vite.config.ts`
// plus a proxy, so that the page reaches the devnet and both services on its own origin. They stay
// on 127.0.0.1 whatever `PLAY_HOST` is (only this server listens there), and neither CORS nor a
// browser's local-network rules apply (Safari, a phone on the same network).
//   /rpc               -> the devnet            (PLAY_DEVNET_PORT, 5050)
//   /attest-service/*  -> the attestation service (PLAY_ATTEST_PORT, 8547)
//   /prove-service/*   -> the prover service      (PLAY_PROVE_PORT, 8549)
import client from '../../client/vite.config.ts';

const port = (name: string, fallback: number) => Number(process.env[name] ?? fallback);
const local = (p: number) => `http://127.0.0.1:${p}`;
const strip = (prefix: string) => (path: string) => path.slice(prefix.length) || '/';

export default {
  ...client,
  server: {
    proxy: {
      '/rpc': { target: local(port('PLAY_DEVNET_PORT', 5050)) },
      '/attest-service': { target: local(port('PLAY_ATTEST_PORT', 8547)), rewrite: strip('/attest-service') },
      '/prove-service': { target: local(port('PLAY_PROVE_PORT', 8549)), rewrite: strip('/prove-service') },
    },
  },
};
