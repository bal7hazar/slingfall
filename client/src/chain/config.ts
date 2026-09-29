// Chain configuration of the Submit step, from Vite env variables (`deploy/devnet.sh` writes
// them to `deploy/devnet.env`, `client/.env.sepolia` is the Sepolia one; docs/e2e.md,
// docs/testers.md; `scripts/play.sh` passes its own, docs/play-local.md). Without
// `VITE_SLINGFALL_ADDRESS` the step is hidden.

export interface ChainConfig {
  /** The deployed `Slingfall` (registry class). */
  address: string;
  /** `VITE_NETWORK`: `sepolia`, `mainnet` or (default) `devnet`. */
  network: string;
  rpcUrl: string;
  /** The block explorer of the network (Voyager); `null` on a devnet. */
  explorerUrl: string | null;
  attestUrl: string;
  /** The prover service of the settled tier (`services/prove`); `null`: no "Settle" step. */
  proveUrl: string | null;
  /** Devnet only (never offered on a public network): a prefunded account the page signs with itself. */
  devnetAccount: { address: string; privateKey: string } | null;
  /**
   * `VITE_DEPLOY_BLOCK`: the block of the contract's deployment transaction, so that `getEvents`
   * (the player's `LevelValidated` history) pages from there instead of genesis (m10: the public
   * RPC takes ~26 s, or fails, scanning from block 0). `0` when unset (devnet: genesis is cheap).
   */
  deployBlock: number;
  /**
   * `VITE_PLAY_LOCAL` (`scripts/play.sh`, devnet only): the proofs are simulated (the fake SNIP-36
   * prover, the devnet's `FakeSatellite`). The page says so, signs with the devnet account without a
   * Connect, and lets the player pick the tier of each attempt's proof.
   */
  local: boolean;
}

type Env = Record<string, string | boolean | undefined>;

/** Voyager, per public network. */
const EXPLORERS: Record<string, string> = {
  sepolia: 'https://sepolia.voyager.online',
  mainnet: 'https://voyager.online',
};
/**
 * A service URL as given, or resolved against the page's origin when it is a path (`scripts/play.sh`
 * serves the devnet and the services behind the dev server's proxy: `/rpc`, `/attest-service`, ...).
 */
function absolute(url: string): string {
  if (!url.startsWith('/')) return url;
  const origin = globalThis.location?.origin;
  return origin ? new URL(url, origin).href.replace(/\/$/, '') : url;
}

/** The RPC of a public network when no URL is given. */
const PUBLIC_RPC: Record<string, string> = {
  sepolia: 'https://starknet-sepolia-rpc.publicnode.com',
};

export function chainConfig(env: Env = import.meta.env): ChainConfig | null {
  const get = (name: string) => {
    const value = env[name];
    return typeof value === 'string' && value !== '' ? value : undefined;
  };
  const address = get('VITE_SLINGFALL_ADDRESS');
  if (address === undefined) return null;
  const network = get('VITE_NETWORK') ?? 'devnet';
  const devAddress = get('VITE_DEVNET_ACCOUNT_ADDRESS');
  const devKey = get('VITE_DEVNET_PRIVATE_KEY');
  const proveUrl = get('VITE_PROVE_URL');
  return {
    address,
    network,
    // `VITE_RPC_URL` is the name `deploy/devnet.sh` writes; `VITE_STARKNET_RPC_URL` wins.
    rpcUrl: absolute(get('VITE_STARKNET_RPC_URL') ?? get('VITE_RPC_URL') ?? PUBLIC_RPC[network] ?? 'http://127.0.0.1:5050/rpc'),
    explorerUrl: EXPLORERS[network] ?? null,
    attestUrl: absolute(get('VITE_ATTEST_URL') ?? 'http://127.0.0.1:8547'),
    proveUrl: proveUrl === undefined ? null : absolute(proveUrl),
    devnetAccount: network === 'devnet' && devAddress && devKey ? { address: devAddress, privateKey: devKey } : null,
    deployBlock: Number(get('VITE_DEPLOY_BLOCK') ?? 0),
    local: network === 'devnet' && get('VITE_PLAY_LOCAL') === '1',
  };
}

/** The explorer page of a contract / account (`contract`) or a transaction (`tx`); `null` on a devnet. */
export function explorerLink(config: ChainConfig, kind: 'contract' | 'tx', hash: string): string | null {
  return config.explorerUrl === null ? null : `${config.explorerUrl}/${kind}/${hash}`;
}
