import { Application, Graphics } from 'pixi.js';
import './style.css';
import { AimController } from './aim/controller';
import { TraceBuffer } from './render/buffer';
import { boundsOf, fitCamera, type Camera } from './render/camera';
import { Hud, hudAt } from './render/hud';
import { Playback } from './render/playback';
import { Scene } from './render/scene';
import { RecordedTraceSource, type TraceSource } from './trace/source';

const TRACE_URL = '/traces/pile10.json';
const CONTROLS_HEIGHT = 44;

function element<T extends HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  if (!found) throw new Error(`missing ${selector} in index.html`);
  return found;
}

async function main(): Promise<void> {
  const app = new Application();
  await app.init({
    background: '#1b1d23',
    resizeTo: window,
    antialias: true,
    autoDensity: true,
    resolution: window.devicePixelRatio,
  });
  element('#app').appendChild(app.canvas);

  const source: TraceSource = new RecordedTraceSource(TRACE_URL);
  const level = await source.level();
  const buffer = new TraceBuffer(level);
  const scene = new Scene(level, buffer);
  app.stage.addChild(scene.world);

  const bounds = boundsOf(level);
  const insets = { top: 0, bottom: CONTROLS_HEIGHT };
  let camera: Camera = fitCamera(bounds, app.screen.width, app.screen.height, insets);
  scene.setCamera(camera);

  const aimLayer = new Graphics();
  scene.overlay.addChild(aimLayer);
  const aim = new AimController({
    canvas: app.canvas,
    camera: () => camera,
    graphics: aimLayer,
    level,
    onRelease: () => {
      // No simulation yet (lot G6b): the release is only logged by the controller.
    },
  });
  app.renderer.on('resize', (width: number, height: number) => {
    camera = fitCamera(bounds, width, height, insets);
    scene.setCamera(camera);
  });

  // Frames stream in behind the playback head: the source may still be producing them.
  void (async () => {
    for await (const frame of source.frames()) buffer.push(frame);
  })();

  const playback = new Playback(() => buffer.frameCount);
  const hud = new Hud(element('#hud'));
  const play = element<HTMLButtonElement>('#play');
  const scrub = element<HTMLInputElement>('#scrub');
  const refreshPlay = () => {
    play.textContent = playback.playing ? 'Pause' : 'Play';
  };
  play.addEventListener('click', () => {
    playback.toggle();
    refreshPlay();
  });
  scrub.addEventListener('input', () => playback.seek(Number(scrub.value)));
  window.addEventListener('keydown', (event) => {
    if (event.code !== 'Space') return;
    event.preventDefault();
    playback.toggle();
    refreshPlay();
  });

  let shownFrame = -1;
  app.ticker.add((ticker) => {
    playback.advance(ticker.deltaMS);
    scene.update(playback.position);

    const frame = Math.floor(playback.position);
    if (frame !== shownFrame && buffer.frameCount > 0) {
      shownFrame = frame;
      const tick = buffer.ticks[frame];
      hud.set(hudAt(source.events, level.shots, tick), tick, buffer.ticks[buffer.frameCount - 1]);
      scrub.max = String(playback.lastFrame);
      scrub.value = String(frame);
    }
  });

  import.meta.hot?.dispose(() => aim.dispose());
}

void main();
