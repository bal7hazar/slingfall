import { Application, Graphics } from 'pixi.js';
import './style.css';
import { RecordedTraceSource, type TraceSource } from './trace/source';
import { fixedToNumber, type TraceFrame } from './trace/types';

// Skeleton renderer: plays a recorded trace at 60 Hz, one circle per body. Lot G6 replaces it.
const PIXELS_PER_METRE = 40;

async function main(): Promise<void> {
  const app = new Application();
  await app.init({ background: '#1b1d23', resizeTo: window, antialias: true });
  document.querySelector<HTMLDivElement>('#app')!.appendChild(app.canvas);

  const source: TraceSource = new RecordedTraceSource('/traces/sample.json');
  const frames: TraceFrame[] = [];
  for await (const frame of source.frames()) frames.push(frame);

  const bodies = new Map<number, Graphics>();
  let index = 0;
  app.ticker.maxFPS = 60;
  app.ticker.add(() => {
    const frame = frames[index];
    if (!frame) return;
    for (const body of frame.bodies) {
      let sprite = bodies.get(body.handle);
      if (!sprite) {
        sprite = new Graphics().circle(0, 0, 0.25 * PIXELS_PER_METRE).fill('#e0a458');
        bodies.set(body.handle, sprite);
        app.stage.addChild(sprite);
      }
      // World y points up, screen y points down; the origin sits at the bottom centre.
      sprite.x = app.screen.width / 2 + fixedToNumber(body.x) * PIXELS_PER_METRE;
      sprite.y = app.screen.height - fixedToNumber(body.y) * PIXELS_PER_METRE;
      sprite.rotation = -Math.atan2(fixedToNumber(body.im), fixedToNumber(body.re));
    }
    index = Math.min(index + 1, frames.length - 1);
  });
}

void main();
