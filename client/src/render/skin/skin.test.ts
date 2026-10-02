import { Container, Texture } from 'pixi.js';
import { describe, expect, it } from 'vitest';
import { flatSkin, kenneySkin, skinName, type Skin } from '.';
import { KENNEY_FILES, type KenneyTextures } from './kenney';
import type { LevelBody } from '../../trace/types';

const Q = (m: number) => String(Math.round(m * 2 ** 32));
const textures = Object.fromEntries(Object.keys(KENNEY_FILES).map((k) => [k, Texture.EMPTY])) as KenneyTextures;
const skins: Skin[] = [flatSkin(), kenneySkin(textures)];
const pose = { x: '0', y: '0', re: Q(1), im: '0' };
const body = (material: string, shape: LevelBody['shape']): LevelBody =>
  ({ handle: 1, kind: 'block', shape, material, pose }) as LevelBody;

const bodies: LevelBody[] = [
  body('timber', { type: 'cuboid', hx: Q(0.5), hy: Q(0.5) }),
  body('slate', { type: 'cuboid', hx: Q(3.5), hy: Q(0.2) }),
  body('frost', { type: 'cuboid', hx: Q(0.2), hy: Q(1) }),
  body('core', { type: 'ball', radius: Q(0.4) }),
  body('ground', { type: 'halfspace', normal: { x: '0', y: Q(1) } }),
  body('slate', { type: 'polygon', vertices: [{ x: '0', y: '0' }, { x: Q(1), y: '0' }, { x: '0', y: Q(1) }] }),
];

/** Puts the view in the y-flipped world of `Scene.setCamera`; whether its image-up point is above its image-down point. */
function upright(view: Container, up: number, down: number): boolean {
  const root = new Container();
  const world = new Container();
  world.scale.set(1, -1);
  root.addChild(world);
  world.addChild(view);
  return view.toGlobal({ x: 0, y: up }).y < view.toGlobal({ x: 0, y: down }).y;
}

describe.each(skins)('skin $name', (skin) => {
  it('builds a view for every body shape and the pebble', () => {
    for (const b of bodies) expect(skin.body(b, 10000)).toBeInstanceOf(Container);
    expect(skin.pebble(0.25)).toBeInstanceOf(Container);
    expect(skin.palette.page).toMatch(/^#[0-9a-f]{6}$/);
  });
});

describe('kenney skin', () => {
  const skin = kenneySkin(textures);

  it('counter-flips its sprites: images stay upright in the y-flipped world', () => {
    for (const b of bodies.slice(0, 4)) expect(skin.body(b, 10000).scale.y).toBeLessThan(0);
    // Image-up is -y in a sprite's own pixels.
    expect(upright(skin.body(bodies[0], 10000), -35, 35)).toBe(true);
    expect(upright(skin.body(bodies[3], 10000), -1, 1)).toBe(true);
  });

  it('sizes a block to its box: 1 m is 100 scene units', () => {
    const view = skin.body(bodies[1], 10000);
    expect(view.getLocalBounds().width * view.scale.x).toBeCloseTo(700, 0);
  });

  it('puts the grass edge on top of the ground in the y-flipped world', () => {
    const frame = skin.body(bodies[4], 10000).children[0];
    expect(frame.scale.y).toBeLessThan(0);
    expect(upright(frame, -100, 100)).toBe(true);
  });

  it('has a backdrop; the flat skin has none', () => {
    expect(skin.background()).toBeDefined();
    expect(flatSkin().background()).toBeUndefined();
  });
});

describe('skinName', () => {
  it('reads ?skin=, defaulting to kenney', () => {
    expect(skinName('?skin=flat')).toBe('flat');
    expect(skinName('?skin=kenney&level=pile10')).toBe('kenney');
    expect(skinName('')).toBe('kenney');
    expect(skinName('?skin=nope')).toBe('kenney');
  });
});
