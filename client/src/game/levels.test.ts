import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const root = (path: string) => fileURLToPath(new URL(`../../../${path}`, import.meta.url));

describe('served levels', () => {
  // `public/levels/` is what Vite serves; `fixtures/levels/` (levelc.py) is canonical.
  const served = readdirSync(root('client/public/levels')).sort();

  it('serves every level of fixtures/levels, JSON and felts', () => {
    expect(served).toEqual(readdirSync(root('fixtures/levels')).sort());
  });

  it.each(served)('%s is the canonical copy', (name) => {
    expect(readFileSync(root(`client/public/levels/${name}`), 'utf8')).toBe(
      readFileSync(root(`fixtures/levels/${name}`), 'utf8'),
    );
  });
});
