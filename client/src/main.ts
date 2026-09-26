import { Application } from 'pixi.js';
import './style.css';
import type { Pull } from './aim/pull';
import { chainConfig, explorerLink } from './chain/config';
import { SubmitPanel } from './chain/panel';
import { inputsFelts, shortFelt } from './chain/slingfall';
import { LevelSession, inputsJson } from './game/session';
import { Stage } from './game/stage';
import { Hud, hudAt } from './render/hud';
import { ArrivalRate, liveSpeed } from './render/live';
import { Playback } from './render/playback';
import { RecordedTraceSource } from './trace/source';
import type { TraceEvent } from './trace/types';
import { OUTPUT_FIELDS, type Outputs } from './vm/program';
import { VmClient } from './vm/index';

/** Levels served from `public/levels/` (copies of `fixtures/levels/`). */
const LEVELS = ['pile10', 'cores3', 'tower', 'bridge', 'twin', 'one_block'];
const BASE = import.meta.env.BASE_URL;
const TRACE_URL = `${BASE}traces/pile10.json`;
const CONTROLS_HEIGHT = 44;
const INSETS = { top: 0, bottom: CONTROLS_HEIGHT };
/** The outputs a proof binds the player to (highlighted). */
const PROOF_FIELDS = new Set(['inputs_hash', 'final_state_hash']);

function element<T extends HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  if (!found) throw new Error(`missing ${selector} in index.html`);
  return found;
}

const ui = {
  hud: () => new Hud(element('#hud')),
  simulating: element('#simulating'),
  banner: element('#banner'),
  result: element('#result'),
  resultTitle: element('[data-result="title"]'),
  resultSummary: element('[data-result="summary"]'),
  resultOutputs: element<HTMLTableElement>('[data-result="outputs"]'),
  copyInputs: element<HTMLButtonElement>('#copy-inputs'),
  retryResult: element<HTMLButtonElement>('#retry-result'),
  level: element<HTMLSelectElement>('#level'),
  retry: element<HTMLButtonElement>('#retry'),
  play: element<HTMLButtonElement>('#play'),
  scrub: element<HTMLInputElement>('#scrub'),
  hint: element('#hint'),
  chainInfo: element('#chain-info'),
};

/** `?level=<name>` picks the level; `?autoshot=px,py;px,py` releases those pulls (headless checks). */
const params = new URLSearchParams(location.search);

/** The page's playback of one stage: live (frames arriving from the worker) or recorded. */
interface View {
  stage: Stage;
  events: readonly TraceEvent[];
  shots: number;
  /** The worker is producing frames for this view. */
  producing: () => boolean;
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

  const hud = ui.hud();
  // The Submit step (lot G9) when a deployed contract is configured (docs/e2e.md).
  const config = chainConfig();
  const submit = config ? new SubmitPanel(ui.result, config) : null;
  /** The network, the contract (Voyager) and the on-chain hash of the level being played. */
  const showChainInfo = (levelHash: string) => {
    if (config === null) return;
    const contractUrl = explorerLink(config, 'contract', config.address);
    const contract = contractUrl
      ? Object.assign(document.createElement('a'), { href: contractUrl, target: '_blank', rel: 'noopener', textContent: shortFelt(config.address), title: config.address })
      : shortFelt(config.address);
    const hash = Object.assign(document.createElement('span'), { textContent: shortFelt(levelHash), title: levelHash });
    ui.chainInfo.replaceChildren(`${config.network} · contract `, contract, ' · level hash ', hash);
    ui.chainInfo.hidden = false;
  };
  const playback = new Playback(() => view?.stage.buffer.frameCount ?? 0);
  const rate = new ArrivalRate();
  let view: View | null = null;

  const refreshPlay = () => (ui.play.textContent = playback.playing ? 'Pause' : 'Play');
  ui.play.addEventListener('click', () => {
    playback.toggle();
    refreshPlay();
  });
  ui.scrub.addEventListener('input', () => playback.seek(Number(ui.scrub.value)));
  window.addEventListener('keydown', (event) => {
    if (event.code !== 'Space') return;
    event.preventDefault();
    playback.toggle();
    refreshPlay();
  });

  let shownFrame = -1;
  app.ticker.add((ticker) => {
    if (view === null) return;
    const { buffer, scene, effects } = view.stage;
    const now = performance.now();
    const producing = view.producing();
    playback.speed = liveSpeed(buffer.frameCount - 1 - playback.position, producing, rate.fps(now));
    playback.advance(ticker.deltaMS);
    const frame = Math.floor(playback.position);
    if (buffer.frameCount > 0) effects.advance(buffer.ticks[frame], frame, now);
    scene.update(playback.position, effects, now);
    ui.simulating.hidden = !(producing && playback.speed < 1);
    if (frame !== shownFrame && buffer.frameCount > 0) {
      shownFrame = frame;
      const tick = buffer.ticks[frame];
      hud.set(hudAt(view.events, view.shots, tick), tick, buffer.ticks[buffer.frameCount - 1]);
      ui.scrub.max = String(playback.lastFrame);
      ui.scrub.value = String(frame);
    }
  });

  const show = (next: View) => {
    view?.stage.destroy();
    view = next;
    playback.position = 0;
    playback.playing = true;
    shownFrame = -1;
    rate.reset();
    refreshPlay();
  };

  let vm: VmClient;
  try {
    vm = new VmClient();
    const loaded = await vm.ready;
    console.log(`vm: loaded in ${loaded.ms.toFixed(0)} ms, wasm ${(loaded.wasmBytes / 2 ** 20).toFixed(0)} MB`);
  } catch (e) {
    // The app builds and runs without the wasm (client/vm/scripts/build.sh): recorded mode.
    ui.banner.textContent = `VM not built (${e instanceof Error ? e.message : e}): run client/vm/scripts/build.sh. Playing the recorded pile10 trace.`;
    ui.banner.hidden = false;
    ui.level.disabled = ui.retry.disabled = true;
    ui.hint.textContent = 'Recorded trace: aiming does not shoot';
    const source = new RecordedTraceSource(TRACE_URL);
    const level = await source.level(); // loads the whole trace: `source.events` is complete
    const stage = new Stage(app, level, source.events, INSETS, () => {});
    show({ stage, events: source.events, shots: level.shots, producing: () => false });
    for await (const frame of source.frames()) stage.buffer.push(frame);
    return;
  }

  for (const name of LEVELS) ui.level.add(new Option(name, name));
  const autoshots = (params.get('autoshot') ?? '')
    .split(';')
    .filter((s) => s !== '')
    .map((s) => {
      const [x, y] = s.split(',').map(Number);
      return { x, y };
    });

  let session: LevelSession | null = null;
  let generation = 0;

  const begin = (s: LevelSession) => {
    generation++;
    s.reset();
    ui.result.hidden = true;
    submit?.hide();
    const stage = new Stage(app, s.traceLevel, s.events, INSETS, (pull) => void fire(s, pull));
    stage.buffer.push(s.startFrame());
    show({ stage, events: s.events, shots: s.traceLevel.shots, producing: () => s.phase === 'flying' });
    ui.hint.textContent = 'Drag from the sling to aim';
    if (autoshots.length > 0) void fire(s, autoshots.shift()!);
  };

  const fire = async (s: LevelSession, pull: Pull) => {
    const stage = view!.stage;
    const gen = generation;
    stage.armed = false;
    ui.retry.disabled = ui.level.disabled = true;
    ui.hint.textContent = 'Simulating in Cairo…';
    console.log(`shot ${s.shots.length}: release, pull (${pull.x}, ${pull.y})`);
    try {
      const report = await s.fire(pull, {
        onFrame: (frame) => {
          rate.push(performance.now());
          if (gen === generation) stage.buffer.push(frame);
        },
      });
      const worst = Math.max(...report.chunks.map((c) => c.wasmBytes)) / 2 ** 20;
      console.log(
        `shot ${report.shot}: first frame ${report.firstFrameMs?.toFixed(0)} ms, ${report.ticks} ticks, ` +
          `${(report.steps / 1e6).toFixed(2)}M steps, ${(report.ms / 1000).toFixed(2)} s, ` +
          `${report.chunks.length} chunks [${report.chunks.map((c) => c.ticks).join(' ')}], wasm ${worst.toFixed(0)} MB; ` +
          `score ${s.header.score}, tick ${s.header.tick}`,
      );
    } catch (e) {
      console.error(e);
      ui.banner.textContent = `shot failed: ${e instanceof Error ? e.message : e}`;
      ui.banner.hidden = false;
    }
    ui.retry.disabled = ui.level.disabled = false;
    if (gen !== generation) return;
    if (s.phase === 'over') {
      ui.hint.textContent = 'Level over';
      void finish(s, gen);
    } else {
      stage.armed = true;
      ui.hint.textContent = 'Drag from the sling to aim';
      if (autoshots.length > 0) void fire(s, autoshots.shift()!);
    }
  };

  const finish = async (s: LevelSession, gen: number) => {
    const r = s.result()!;
    console.log(`level over: ${r.won ? 'won' : 'lost'}, score ${r.score}, shots ${r.shotsUsed}, ticks ${r.ticks}`);
    ui.resultTitle.textContent = r.won ? 'Level won' : 'Level lost';
    ui.resultSummary.textContent = `Score ${r.score} · shots ${r.shotsUsed} · ${r.ticks} ticks · outputs: computing…`;
    ui.resultOutputs.replaceChildren();
    ui.result.hidden = false;
    try {
      const t = performance.now();
      const outputs = await s.outputs();
      if (gen !== generation) return;
      console.log(`outputs (${(performance.now() - t).toFixed(0)} ms): ${OUTPUT_FIELDS.map((f) => outputs[f]).join(' ')}`);
      ui.resultSummary.textContent = `Score ${r.score} · shots ${r.shotsUsed} · ${r.ticks} ticks · the outputs a proof will carry:`;
      showOutputs(outputs);
      submit?.offer((player) => s.outputsFor(player), (player) => inputsFelts(player, s.shots));
    } catch (e) {
      ui.resultSummary.textContent = `Score ${r.score} · outputs failed: ${e instanceof Error ? e.message : e}`;
    }
  };

  const showOutputs = (outputs: Outputs) => {
    const rows = OUTPUT_FIELDS.map((field) => {
      const row = document.createElement('tr');
      if (PROOF_FIELDS.has(field)) row.className = 'proof';
      const th = document.createElement('th');
      th.textContent = field;
      const td = document.createElement('td');
      const value = outputs[field];
      td.textContent = value.length > 12 ? `0x${BigInt(value).toString(16)}` : value;
      row.append(th, td);
      return row;
    });
    ui.resultOutputs.replaceChildren(...rows);
  };

  ui.copyInputs.addEventListener('click', () => {
    if (session === null) return;
    const text = inputsJson(session.inputs());
    void navigator.clipboard?.writeText(text).then(
      () => (ui.copyInputs.textContent = 'Copied'),
      () => console.log(`inputs: ${text}`),
    );
    setTimeout(() => (ui.copyInputs.textContent = 'Copy inputs'), 1500);
  });
  const retry = () => {
    if (session !== null && session.phase !== 'flying') begin(session);
  };
  ui.retry.addEventListener('click', retry);
  ui.retryResult.addEventListener('click', retry);

  const open = async (name: string) => {
    ui.level.disabled = ui.retry.disabled = true;
    ui.hint.textContent = `Loading ${name}…`;
    const doc = (await (await fetch(`${BASE}levels/${name}.felts.json`)).json()) as { felts: string[]; level_hash: string };
    showChainInfo(doc.level_hash);
    const t = performance.now();
    session = await LevelSession.open(vm, { felts: doc.felts });
    console.log(`level ${name}: init in ${(performance.now() - t).toFixed(0)} ms, ${session.traceLevel.bodies.length} bodies`);
    ui.level.value = name;
    ui.level.disabled = ui.retry.disabled = false;
    begin(session);
  };
  ui.level.addEventListener('change', () => void open(ui.level.value));

  const first = params.get('level') ?? LEVELS[0];
  await open(LEVELS.includes(first) ? first : LEVELS[0]);
}

void main();
