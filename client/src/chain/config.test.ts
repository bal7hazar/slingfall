import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, vi } from 'vitest';
import { chainConfig, explorerLink } from './config';
import { LEVEL_VALIDATED, SlingfallContract, VERIFIER, feltHex, playerValidations, shortFelt } from './slingfall';
import { walletKinds } from './wallet';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));
const json = (path: string) => JSON.parse(readFileSync(root(path), 'utf8'));

/** `KEY=value` lines of a dotenv file (comments and blanks skipped). */
function dotenv(path: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const line of readFileSync(root(path), 'utf8').split('\n')) {
    const m = /^([A-Z_]+)=(.*)$/.exec(line);
    if (m) env[m[1]] = m[2];
  }
  return env;
}

const SEPOLIA = json('deploy/sepolia.json');

describe('client/.env.sepolia', () => {
  const env = dotenv('client/.env.sepolia');
  const config = chainConfig(env)!;

  it('points at the deployed contract of deploy/sepolia.json', () => {
    expect(BigInt(env.VITE_SLINGFALL_ADDRESS)).toBe(BigInt(SEPOLIA.address));
    expect(config.network).toBe('sepolia');
    expect(SEPOLIA.chain_id).toBe('0x534e5f5345504f4c4941'); // SN_SEPOLIA
  });

  it('is the contract v2 deployment (lot D2), both tiers open, v1 kept under "v1"', () => {
    expect(SEPOLIA.contract_version).toBe(2);
    expect(SEPOLIA.verifier).toBe('Stub');
    expect(BigInt(SEPOLIA.program.current)).toBe(0x5dc8c8e25ea0b022da820ca7c14ce16cc228f24677a6c8a3c46bb0f9d41360n); // c1main on Scarb 2.20.1 (TC)
    expect(BigInt(SEPOLIA.v1.address)).toBe(0x4b645fe7cf06775c99c61148097b3aecabb67eacfd2937e0431affef5000ae2n);
    expect(BigInt(SEPOLIA.v1.address)).not.toBe(BigInt(SEPOLIA.address));
    expect(Number(env.VITE_DEPLOY_BLOCK)).toBe(SEPOLIA.deploy_block);
  });

  it('uses the public RPC and Voyager Sepolia, no service by default', () => {
    expect(config.rpcUrl).toBe('https://starknet-sepolia-rpc.publicnode.com');
    expect(config.explorerUrl).toBe('https://sepolia.voyager.online');
    expect(config.proveUrl).toBeNull();
    expect(explorerLink(config, 'contract', config.address)).toBe(`https://sepolia.voyager.online/contract/${config.address}`);
    expect(explorerLink(config, 'tx', '0x1')).toBe('https://sepolia.voyager.online/tx/0x1');
  });

  it('holds no secret', () => {
    expect(Object.keys(env).sort()).toEqual([
      'VITE_ATTEST_URL', 'VITE_DEPLOY_BLOCK', 'VITE_NETWORK', 'VITE_PROVE_URL', 'VITE_SLINGFALL_ADDRESS', 'VITE_STARKNET_RPC_URL',
    ]);
  });

  it('pins the deployment block for getEvents paging (m10)', () => {
    expect(Number(env.VITE_DEPLOY_BLOCK)).toBeGreaterThan(0);
    expect(config.deployBlock).toBe(Number(env.VITE_DEPLOY_BLOCK));
  });

  it('serves the levels registered on Sepolia, under the hashes it registered', () => {
    for (const [name, hash] of Object.entries<string>(SEPOLIA.levels)) {
      const doc = json(`client/public/levels/${name}.felts.json`);
      expect(BigInt(doc.level_hash), name).toBe(BigInt(hash));
    }
  });

  it('never offers the devnet account on Sepolia', () => {
    const withKey = chainConfig({ ...env, VITE_DEVNET_ACCOUNT_ADDRESS: '0x1', VITE_DEVNET_PRIVATE_KEY: '0x2' })!;
    expect(withKey.devnetAccount).toBeNull();
    expect(walletKinds(withKey)).toEqual(['cartridge', 'get-starknet']);
  });

  it('matches deploy/sepolia.env.example on the address', () => {
    const example = dotenv('deploy/sepolia.env.example');
    expect(chainConfig(example)!.address).toBe(config.address);
  });
});

describe('chainConfig', () => {
  const base = { VITE_SLINGFALL_ADDRESS: '0xabc' };

  it('is null without a contract', () => {
    expect(chainConfig({})).toBeNull();
  });

  it('keeps the devnet defaults and its account', () => {
    const config = chainConfig({ ...base, VITE_DEVNET_ACCOUNT_ADDRESS: '0x1', VITE_DEVNET_PRIVATE_KEY: '0x2' })!;
    expect(config.network).toBe('devnet');
    expect(config.rpcUrl).toBe('http://127.0.0.1:5050/rpc');
    expect(config.explorerUrl).toBeNull();
    expect(config.devnetAccount).toEqual({ address: '0x1', privateKey: '0x2' });
    expect(config.deployBlock).toBe(0);
    expect(walletKinds(config)).toEqual(['devnet', 'cartridge', 'get-starknet']);
    expect(explorerLink(config, 'tx', '0x1')).toBeNull();
  });

  it('reads VITE_DEPLOY_BLOCK when given', () => {
    expect(chainConfig({ ...base, VITE_DEPLOY_BLOCK: '15666652' })!.deployBlock).toBe(15666652);
  });

  it('prefers VITE_STARKNET_RPC_URL to VITE_RPC_URL (the devnet.sh name)', () => {
    expect(chainConfig({ ...base, VITE_RPC_URL: 'http://a' })!.rpcUrl).toBe('http://a');
    expect(chainConfig({ ...base, VITE_RPC_URL: 'http://a', VITE_STARKNET_RPC_URL: 'http://b' })!.rpcUrl).toBe('http://b');
    expect(chainConfig({ ...base, VITE_NETWORK: 'sepolia', VITE_STARKNET_RPC_URL: '' })!.rpcUrl).toBe('https://starknet-sepolia-rpc.publicnode.com');
  });

  it('local mode (scripts/play.sh): devnet only, service paths on the page origin', () => {
    const env = { ...base, VITE_PLAY_LOCAL: '1', VITE_STARKNET_RPC_URL: '/rpc', VITE_ATTEST_URL: '/attest-service', VITE_PROVE_URL: '/prove-service' };
    vi.stubGlobal('location', { origin: 'http://192.168.1.20:5173' });
    try {
      const config = chainConfig(env)!;
      expect(config.local).toBe(true);
      expect(config.rpcUrl).toBe('http://192.168.1.20:5173/rpc');
      expect(config.attestUrl).toBe('http://192.168.1.20:5173/attest-service');
      expect(config.proveUrl).toBe('http://192.168.1.20:5173/prove-service');
      expect(chainConfig({ ...env, VITE_NETWORK: 'sepolia' })!.local).toBe(false);
    } finally {
      vi.unstubAllGlobals();
    }
    expect(chainConfig(base)!.local).toBe(false);
    expect(chainConfig({ ...base, VITE_PROVE_URL: 'http://127.0.0.1:8549' })!.proveUrl).toBe('http://127.0.0.1:8549');
  });
});

describe('reads for the Sepolia panel', () => {
  it('reads the verifier kind', async () => {
    const calls: unknown[] = [];
    const contract = new SlingfallContract('0x5afe', {
      callContract: async (call) => {
        calls.push(call);
        return ['0x2'];
      },
    });
    expect(await contract.verifier()).toBe(VERIFIER.satellite);
    expect(calls).toEqual([{ contractAddress: '0x5afe', entrypoint: 'verifier', calldata: [] }]);
  });

  it('lists the LevelValidated transactions of a player across chunks', async () => {
    const filters: unknown[] = [];
    const pages = [
      { events: [{ transaction_hash: '0x1', block_number: 7 }], continuation_token: 'next' },
      { events: [{ transaction_hash: '0x2' }] },
    ];
    const found = await playerValidations(
      {
        getEvents: async (filter) => {
          filters.push(filter);
          return pages[filters.length - 1];
        },
      },
      '0x5afe',
      '0x59b',
    );
    expect(found).toEqual([
      { transactionHash: '0x1', blockNumber: 7 },
      { transactionHash: '0x2', blockNumber: null },
    ]);
    expect(filters).toHaveLength(2);
    expect(filters[0]).toMatchObject({ address: '0x5afe', keys: [[LEVEL_VALIDATED], [feltHex('0x59b')]] });
    expect(filters[0]).toMatchObject({ from_block: { block_number: 0 } });
    expect(filters[1]).toMatchObject({ continuation_token: 'next' });
  });

  it('pages from fromBlock (m10), not genesis, when given', async () => {
    const found = await playerValidations({ getEvents: async () => ({ events: [] }) }, '0x5afe', '0x59b', { fromBlock: 15666652 });
    expect(found).toEqual([]);
  });

  it('retries a failed page once before giving up (m10)', async () => {
    let calls = 0;
    const reader = {
      getEvents: async () => {
        calls++;
        if (calls === 1) throw new Error('-32701 broker: node error');
        return { events: [{ transaction_hash: '0x1' }] };
      },
    };
    const found = await playerValidations(reader, '0x5afe', '0x59b');
    expect(found).toEqual([{ transactionHash: '0x1', blockNumber: null }]);
    expect(calls).toBe(2);
  });

  it('gives up after the retry and throws (m10: the "unavailable" state)', async () => {
    const reader = { getEvents: async () => { throw new Error('-32701 broker: node error'); } };
    await expect(playerValidations(reader, '0x5afe', '0x59b')).rejects.toThrow('broker: node error');
  });

  it('shortens a felt for display', () => {
    expect(shortFelt('0x4b645fe7cf06775c99c61148097b3aecabb67eacfd2937e0431affef5000ae2')).toBe('0x4b645f…0ae2');
    expect(shortFelt('0x12')).toBe('0x12');
  });
});
