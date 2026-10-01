import { Application } from 'pixi.js';
import './style.css';
import type { Pull } from './aim/pull';
import { chainConfig, explorerLink } from './chain/config';
import { SubmitPanel } from './chain/panel';
import { inputsFelts, shortFelt } from './chain/slingfall';
import { ShotLoop } from './game/play';
import { LevelSession, inputsJson } from './game/session';
import { Stage } from './game/stage';
import { Hud, hudAt } from './render/hud';
import { Playback } from './render/playback';
import { foldResult, toggleResult } from './render/result';
import { RecordedTraceSource } from './trace/source';
import type { TraceEvent } from './trace/types';
import { OUTPUT_FIELDS, decodeOutputs, type Outputs } from './vm/program';
import { VmClient } from './vm/index';

/** Levels served from `public/levels/` (copies of `fixtures/levels/`). */
const LEVELS = ['pile10', 'cores3', 'tower', 'bridge', 'twin', 'one_block'];
const BASE = import.meta.env.BASE_URL;
const TRACE_URL = `${BASE}traces/pile10.json`;
const CONTROLS_HEIGHT = 44;
const INSETS = { top: 0, bottom: CONTROLS_HEIGHT };
/** The outputs a proof binds the player to (highlighted). */
const PROOF_FIELDS = new Set(['inputs_hash', 'final_state_hash']);
/** Phones, portrait or landscape: short hints, a compact layout (style.css has the same query). */
const NARROW = window.matchMedia('(max-width: 600px), (max-height: 500px)');

/** Hints of the controls bar: [wide screen, narrow screen]. */
const HINTS = {
  aim: ['Drag the pebble to aim · arrow keys fine-tune (Shift ×10), Enter shoots', 'Drag the pebble'],
  simulating: ['Simulating in Cairo…', 'Simulating…'],
  showing: ['Playing the shot…', 'Playing…'],
  over: ['Level over', 'Level over'],
  recorded: ['Recorded trace: aiming does not shoot', 'Recorded trace'],
} as const;

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
  resultToggle: element<HTMLButtonElement>('#result-toggle'),
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

/** `?level=<name>` picks the level; `?autoshot=px,py;px,py` releases those pulls by itself (headless checks). */
const params = new URLSearchParams(location.search);

let hint: readonly [string, string] = HINTS.aim;
const setHint = (next: readonly [string, string]) => {
  hint = next;
  ui.hint.textContent = next[NARROW.matches ? 1 : 0];
};
NARROW.addEventListener('change', () => setHint(hint));

ui.resultToggle.addEventListener('click', () => toggleResult(ui.result, ui.resultToggle));

/** The banner: the local mode's standing notice, replaced by a failure's message (`error`). */
const LOCAL_BANNER = 'local devnet: proofs are simulated';
const showBanner = (text: string, error: boolean) => {
  ui.banner.textContent = error && chainConfig()?.local ? `${LOCAL_BANNER} · ${text}` : text; // the notice stands beside a failure
  ui.banner.classList.toggle('notice', !error);
  ui.banner.hidden = false;
};

/** The page's playback of one stage: live (a `ShotLoop` over the worker) or recorded. */
interface View {
  stage: Stage;
  events: readonly TraceEvent[];
  shots: number;
  /** Ticks the shots were released at (the HUD counts a released shot as spent). */
  releases: readonly number[];
  loop: ShotLoop | null;
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
  if (config?.local) showBanner(LOCAL_BANNER, false); // `scripts/play.sh`: nothing is proven for real (docs/play-local.md)
  const submit = config ? new SubmitPanel(ui.result, config) : null;
  /** m11: the connected account; the outputs table shows the outputs a proof will carry for it. */
  let connected: string | null = null;
  /** The finished level whose outputs the table shows. */
  let finished: { s: LevelSession; gen: number; summary: string } | null = null;
  /** The network, the contract (Voyager) and the on-chain hash of the level being played. */
  const showChainInfo = (levelHash: string) => {
    if (config === null) return;
    const contractUrl = explorerLink(config, 'contract', config.address);
    const contract = contractUrl
      ? Object.assign(document.createElement('a'), { href: contractUrl, target: '_blank', rel: 'noopener', textContent: shortFelt(config.address), title: config.address })
      : shortFelt(config.address);
    const hash = Object.assign(document.createElement('span'), { textContent: shortFelt(levelHash), title: levelHash });
    // `scripts/play.sh` (docs/play-local.md): nothing here is proven for real.
    const local = config.local ? [Object.assign(document.createElement('b'), { textContent: 'local devnet: proofs are simulated' }), ' · '] : [];
    ui.chainInfo.replaceChildren(...local, `${config.network} · contract `, contract, ' · level hash ', hash);
    ui.chainInfo.hidden = false;
  };
  const playback = new Playback(() => view?.stage.buffer.frameCount ?? 0);
  let view: View | null = null;
  const producing = () => view?.loop?.producing ?? false;

  /** Play / Pause from the real state: "Pause" only while the head moves or waits for frames. */
  const refreshPlay = () => {
    const label = playback.running(producing()) ? 'Pause' : 'Play';
    if (ui.play.textContent !== label) ui.play.textContent = label;
  };
  const togglePlay = () => {
    playback.toggle(producing());
    refreshPlay();
  };
  ui.play.addEventListener('click', togglePlay);
  ui.scrub.addEventListener('input', () => playback.seek(Number(ui.scrub.value)));
  window.addEventListener('keydown', (event) => {
    if (event.code !== 'Space' || (event.target as HTMLElement | null)?.tagName === 'INPUT') return;
    event.preventDefault();
    togglePlay();
  });

  let shownFrame = -1;
  let shownReleases = -1;
  app.ticker.add((ticker) => {
    if (view === null) return;
    const { stage } = view;
    const { buffer } = stage;
    if (view.loop !== null) {
      view.loop.advance(ticker.deltaMS);
    } else {
      playback.speed = 1;
      playback.advance(ticker.deltaMS);
    }
    const now = performance.now();
    stage.update(playback.position, ticker.deltaMS, now);
    ui.simulating.hidden = !(producing() && playback.speed < 1);
    refreshPlay();
    const frame = Math.floor(playback.position);
    if ((frame !== shownFrame || view.releases.length !== shownReleases) && buffer.frameCount > 0) {
      shownFrame = frame;
      shownReleases = view.releases.length;
      const tick = buffer.ticks[frame];
      hud.set(hudAt(view.events, view.shots, tick, view.releases), tick, buffer.ticks[buffer.frameCount - 1]);
      ui.scrub.max = String(playback.lastFrame);
      ui.scrub.value = String(frame);
    }
  });

  const show = (next: View) => {
    view?.loop?.dispose();
    view?.stage.destroy();
    view = next;
    playback.position = 0;
    playback.playing = true;
    shownFrame = -1;
    refreshPlay();
  };

  let vm: VmClient;
  try {
    vm = new VmClient();
    const loaded = await vm.ready;
    console.log(`vm: loaded in ${loaded.ms.toFixed(0)} ms, wasm ${(loaded.wasmBytes / 2 ** 20).toFixed(0)} MB`);
  } catch (e) {
    // The app builds and runs without the wasm (client/vm/scripts/build.sh): recorded mode.
    showBanner(`VM not built (${e instanceof Error ? e.message : e}): run client/vm/scripts/build.sh. Playing the recorded pile10 trace.`, true);
    ui.level.disabled = ui.retry.disabled = true;
    setHint(HINTS.recorded);
    const source = new RecordedTraceSource(TRACE_URL);
    const level = await source.level(); // loads the whole trace: `source.events` is complete
    const stage = new Stage(app, level, source.events, { insets: INSETS, onAim: (p) => hud.setPull(p), onRelease: () => {} });
    stage.armed = false;
    show({ stage, events: source.events, shots: level.shots, releases: [], loop: null });
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
  /** The last pull released: the arrow keys start from it after a Retry. */
  let lastPull: Pull | undefined;
  const setLeaving = (allowed: boolean) => (ui.retry.disabled = ui.level.disabled = !allowed);

  const begin = (s: LevelSession) => {
    generation++;
    const gen = generation;
    s.reset();
    ui.result.hidden = true;
    submit?.hide();
    let loop: ShotLoop | null = null;
    const stage = new Stage(app, s.traceLevel, s.events, {
      insets: INSETS,
      keys: window,
      initialPull: lastPull,
      onAim: (pull) => hud.setPull(pull),
      onRelease: (pull) => {
        if (loop?.release(pull)) lastPull = pull;
      },
    });
    stage.buffer.push(s.startFrame());
    loop = new ShotLoop(s, stage.buffer, playback, {
      released: (pull) => {
        stage.armed = false;
        setLeaving(false);
        setHint(HINTS.simulating);
        hud.setPull(pull);
        console.log(`shot ${s.shots.length - 1}: release, pull (${pull.x}, ${pull.y})`);
      },
      produced: (report) => {
        const worst = Math.max(...report.chunks.map((c) => c.wasmBytes)) / 2 ** 20;
        console.log(
          `shot ${report.shot}: first frame ${report.firstFrameMs?.toFixed(0)} ms, ${report.ticks} ticks, ` +
            `${(report.steps / 1e6).toFixed(2)}M steps, ${(report.ms / 1000).toFixed(2)} s, ` +
            `${report.chunks.length} chunks [${report.chunks.map((c) => c.ticks).join(' ')}], wasm ${worst.toFixed(0)} MB; ` +
            `score ${s.header.score}, tick ${s.header.tick}`,
        );
        setLeaving(true);
        setHint(HINTS.showing);
        // The outputs run while the playback catches up; the panel shows them once it has.
        if (s.phase === 'over') void s.outputs().catch(() => {});
      },
      failed: (e) => {
        console.error(e);
        showBanner(`shot failed: ${e instanceof Error ? e.message : e}`, true);
        setLeaving(true);
        stage.armed = true;
        setHint(HINTS.aim);
      },
      armed: () => {
        stage.armed = true;
        hud.setPull(undefined);
        setHint(HINTS.aim);
        console.log(`shot ${s.shots.length - 1}: shown`);
        if (autoshots.length > 0) loop?.release(autoshots.shift()!);
      },
      over: () => {
        setHint(HINTS.over);
        void finish(s, gen);
      },
    });
    show({ stage, events: s.events, shots: s.traceLevel.shots, releases: s.releases, loop });
    hud.setPull(undefined);
    setHint(HINTS.aim);
    if (autoshots.length > 0) loop.release(autoshots.shift()!);
  };

  /** The outputs table for `player` (m11: recomputed when a wallet connects after the level ended). */
  const showOutputsFor = async (player: string) => {
    const done = finished;
    if (done === null || done.gen !== generation) return;
    try {
      const felts = await done.s.outputsFor(player);
      if (done.gen !== generation) return;
      ui.resultSummary.textContent = `${done.summary} · the outputs a proof will carry for ${shortFelt(player)}:`;
      showOutputs(decodeOutputs(felts));
    } catch (e) {
      console.warn('outputs for the connected account', e);
    }
  };
  if (submit) {
    submit.onAccount = (player) => {
      connected = player;
      void showOutputsFor(player);
    };
    // The local mode connects the devnet account by itself, perhaps before this line.
    if (submit.player !== null) submit.onAccount(submit.player);
  }

  const finish = async (s: LevelSession, gen: number) => {
    const r = s.result()!;
    console.log(`level over: ${r.won ? 'won' : 'lost'}, score ${r.score}, shots ${r.shotsUsed}, ticks ${r.ticks}`);
    ui.resultTitle.textContent = r.won ? 'Level won' : 'Level lost';
    ui.resultSummary.textContent = `Score ${r.score} · shots ${r.shotsUsed} · ${r.ticks} ticks · outputs: computing…`;
    ui.resultOutputs.replaceChildren();
    foldResult(ui.result, ui.resultToggle, true);
    ui.result.hidden = false;
    try {
      const t = performance.now();
      const outputs = await s.outputs();
      if (gen !== generation) return;
      console.log(`outputs (${(performance.now() - t).toFixed(0)} ms): ${OUTPUT_FIELDS.map((f) => outputs[f]).join(' ')}`);
      const summary = `Score ${r.score} · shots ${r.shotsUsed} · ${r.ticks} ticks`;
      ui.resultSummary.textContent = `${summary} · the outputs a proof will carry:`;
      showOutputs(outputs);
      finished = { s, gen, summary };
      if (connected !== null) void showOutputsFor(connected);
      submit?.offer(outputs.level_hash, (player) => s.outputsFor(player), (player) => inputsFelts(player, s.shots));
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
  /** Retry: allowed once the worker is idle, even while the playback still shows the last shot. */
  const retry = () => {
    if (session !== null && (view?.loop?.canLeave ?? true) && session.phase !== 'flying') begin(session);
  };
  ui.retry.addEventListener('click', retry);
  ui.retryResult.addEventListener('click', retry);

  const open = async (name: string) => {
    setLeaving(false);
    setHint([`Loading ${name}…`, `Loading ${name}…`]);
    const doc = (await (await fetch(`${BASE}levels/${name}.felts.json`)).json()) as { felts: string[]; level_hash: string };
    showChainInfo(doc.level_hash);
    const t = performance.now();
    session = await LevelSession.open(vm, { felts: doc.felts });
    console.log(`level ${name}: init in ${(performance.now() - t).toFixed(0)} ms, ${session.traceLevel.bodies.length} bodies`);
    ui.level.value = name;
    setLeaving(true);
    lastPull = undefined;
    begin(session);
  };
  ui.level.addEventListener('change', () => void open(ui.level.value));

  const first = params.get('level') ?? LEVELS[0];
  await open(LEVELS.includes(first) ? first : LEVELS[0]);
}

void main();
