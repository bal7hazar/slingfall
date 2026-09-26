// Wallet connection of the Submit step: Cartridge Controller first, get-starknet (Argent X,
// Braavos) as the fallback (docs/DESIGN.md D9), and on a devnet the prefunded account of
// `deploy/devnet.env`. The SDKs load on demand (the Controller brings a wasm keychain client).
import { Account, RpcProvider, WalletAccount } from 'starknet';
import type { ChainConfig } from './config.ts';
import type { ChainWriter } from './slingfall.ts';

export type WalletKind = 'cartridge' | 'get-starknet' | 'devnet';

export const WALLET_LABELS: Record<WalletKind, string> = {
  cartridge: 'Cartridge Controller',
  'get-starknet': 'Browser wallet (get-starknet)',
  devnet: 'Devnet account (dev only)',
};

/** The wallets this configuration offers, in order of preference. */
export function walletKinds(config: ChainConfig): WalletKind[] {
  const kinds: WalletKind[] = ['cartridge', 'get-starknet'];
  if (config.devnetAccount) kinds.unshift('devnet');
  return kinds;
}

export function provider(config: ChainConfig): RpcProvider {
  return new RpcProvider({ nodeUrl: config.rpcUrl });
}

export async function connectWallet(kind: WalletKind, config: ChainConfig, rpc: RpcProvider): Promise<ChainWriter> {
  switch (kind) {
    case 'devnet': {
      const dev = config.devnetAccount;
      if (!dev) throw new Error('no devnet account configured');
      return new Account({ provider: rpc, address: dev.address, signer: dev.privateKey });
    }
    case 'get-starknet': {
      const { connect } = await import('@starknet-io/get-starknet');
      const wallet = await connect({ modalMode: 'alwaysAsk', modalTheme: 'dark' });
      if (!wallet) throw new Error('no wallet selected');
      // get-starknet 4 types its wallet with `@starknet-io/types-js` 0.10.2, starknet.js 10 with
      // the RPC 0.10.4 copy of the same wallet API: same object, two type packages.
      return WalletAccount.connect(rpc, wallet as unknown as Parameters<typeof WalletAccount.connect>[1]);
    }
    case 'cartridge': {
      const { default: Controller } = await import('@cartridge/controller');
      const chainId = await rpc.getChainId();
      const controller = new Controller({ chains: [{ rpcUrl: config.rpcUrl }], defaultChainId: chainId });
      const account = await controller.connect();
      if (!account) throw new Error('Cartridge Controller: not connected');
      return account;
    }
  }
}
