// Chain configuration of the Submit step, from Vite env variables (`deploy/devnet.sh` writes
// them to `deploy/devnet.env`; docs/e2e.md). Without `VITE_SLINGFALL_ADDRESS` the step is hidden.

export interface ChainConfig {
  /** The deployed `Slingfall` (registry class). */
  address: string;
  rpcUrl: string;
  attestUrl: string;
  /** The prover service of the settled tier (`services/prove`); `null`: no "Settle" step. */
  proveUrl: string | null;
  /** Devnet only: a prefunded account the page signs with itself (no wallet extension). */
  devnetAccount: { address: string; privateKey: string } | null;
}

type Env = Record<string, string | boolean | undefined>;

export function chainConfig(env: Env = import.meta.env): ChainConfig | null {
  const get = (name: string) => {
    const value = env[name];
    return typeof value === 'string' && value !== '' ? value : undefined;
  };
  const address = get('VITE_SLINGFALL_ADDRESS');
  if (address === undefined) return null;
  const devAddress = get('VITE_DEVNET_ACCOUNT_ADDRESS');
  const devKey = get('VITE_DEVNET_PRIVATE_KEY');
  return {
    address,
    rpcUrl: get('VITE_RPC_URL') ?? 'http://127.0.0.1:5050/rpc',
    attestUrl: get('VITE_ATTEST_URL') ?? 'http://127.0.0.1:8547',
    proveUrl: get('VITE_PROVE_URL') ?? null,
    devnetAccount: devAddress && devKey ? { address: devAddress, privateKey: devKey } : null,
  };
}
