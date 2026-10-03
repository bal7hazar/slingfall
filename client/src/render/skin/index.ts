import { loadKenneySkin } from './kenney';
import { flatSkin } from './flat';
import type { Skin } from './types';

export type { Backdrop, Palette, Skin } from './types';
export { flatSkin } from './flat';
export { kenneySkin } from './kenney';

export const SKIN_NAMES = ['kenney', 'flat'] as const;
export type SkinName = (typeof SKIN_NAMES)[number];
/** The skin of the page without a `?skin=` query. */
export const DEFAULT_SKIN: SkinName = 'kenney';

/** The skin a query string selects (`?skin=flat|kenney`). */
export function skinName(search: string): SkinName {
  const wanted = new URLSearchParams(search).get('skin');
  return SKIN_NAMES.find((n) => n === wanted) ?? DEFAULT_SKIN;
}

/** Builds a skin, loading its textures first (`base`: the app's base URL, ending in a slash). */
export function loadSkin(name: SkinName, base: string): Promise<Skin> {
  return name === 'flat' ? Promise.resolve(flatSkin()) : loadKenneySkin(base);
}
