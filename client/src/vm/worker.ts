// Web Worker entry (module worker): loads the wasm-bindgen `--target web` build of the cairo-vm
// runner and the executable once, then serves chunked shots (`serve.ts`). The wasm is imported
// at run time from `LoadRequest.pkgUrl`, so the app bundle never depends on it.
import { serveVm, type WorkerScope } from './serve.ts';
import { engineFromModule, type RunnerModule } from './shot.ts';

interface WebPkg extends RunnerModule {
  default: () => Promise<unknown>;
}

serveVm(self as unknown as WorkerScope, async ({ pkgUrl, executableUrl }) => {
  const [pkg, json] = await Promise.all([
    import(/* @vite-ignore */ pkgUrl) as Promise<WebPkg>,
    fetch(executableUrl).then((r) => {
      if (!r.ok) throw new Error(`cannot load ${executableUrl}: HTTP ${r.status}`);
      return r.text();
    }),
  ]);
  // Fetches and instantiates `slingfall_vm_runner_bg.wasm` next to `pkgUrl`.
  await pkg.default();
  return engineFromModule(pkg, json);
});
