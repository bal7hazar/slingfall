// Web Worker entry (module worker): loads the wasm-bindgen `--target web` build of the cairo-vm
// runner and the executables once, then serves chunked runs (`serve.ts`). The wasm is imported
// at run time from `LoadRequest.pkgUrl`, so the app bundle never depends on it.
import { slingfallContactTick } from './cut.ts';
import type { Entry, SlingfallInputs, SlingfallLevel } from './program';
import { serveVm, type EngineLoader, type WorkerScope } from './serve.ts';
import { engineFromModule, type RunnerModule } from './shot.ts';

interface WebPkg extends RunnerModule {
  default: () => Promise<unknown>;
}

const text = (url: string) =>
  fetch(url).then((r) => {
    if (!r.ok) throw new Error(`cannot load ${url}: HTTP ${r.status}`);
    return r.text();
  });

const load: EngineLoader = async ({ pkgUrl, executableUrl, initExecutableUrl, outputsExecutableUrl }) => {
  const others: [Entry, string | undefined][] = [
    ['init', initExecutableUrl],
    ['outputs', outputsExecutableUrl],
  ];
  const [pkg, json, ...more] = await Promise.all([
    import(/* @vite-ignore */ pkgUrl) as Promise<WebPkg>,
    text(executableUrl),
    ...others.map(([, url]) => (url === undefined ? undefined : text(url))),
  ]);
  // Fetches and instantiates `slingfall_vm_runner_bg.wasm` next to `pkgUrl`.
  await pkg.default();
  const extra: Partial<Record<Entry, string>> = {};
  others.forEach(([entry], i) => {
    if (more[i] !== undefined) extra[entry] = more[i];
  });
  return engineFromModule(pkg, json, extra);
};

serveVm(self as unknown as WorkerScope, load, undefined, {
  // The contact cut of the chunk sizing (lot Q2): the aim arc's predicted contact tick.
  slingfall: (level, inputs, shot, state, poses) =>
    slingfallContactTick(level as SlingfallLevel, inputs as SlingfallInputs, shot, state, poses),
});
