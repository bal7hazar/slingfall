// The VM worker loads the wasm runner (`vm/pkg/`, built by `vm/scripts/build.sh`, git-ignored)
// and the replay executables (`vm/fixtures/replay/`, committed) at run time from `/vm/...`
// (`src/vm/index.ts` `DEFAULT_LOAD`). `vite` serves them from the client root as they are;
// `vite build` copies them into `dist/vm/`. Without `vm/pkg/` the build still succeeds and the
// app says "VM not built".
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { defineConfig, type Plugin } from 'vite';

const here = (path: string) => fileURLToPath(new URL(path, import.meta.url));
/** Executables the app runs (`main_trace` is for tests and tools only). */
const EXECUTABLES = ['init', 'step_chunk', 'outputs'];

function vmAssets(): Plugin {
  return {
    name: 'slingfall-vm-assets',
    apply: 'build',
    generateBundle() {
      const emit = (from: string, fileName: string) =>
        this.emitFile({ type: 'asset', fileName, source: readFileSync(here(from)) });
      for (const name of EXECUTABLES) {
        emit(`vm/fixtures/replay/${name}.executable.json`, `vm/fixtures/replay/${name}.executable.json`);
      }
      if (!existsSync(here('vm/pkg'))) {
        this.warn('client/vm/pkg/ is not built (vm/scripts/build.sh): the app will say "VM not built"');
        return;
      }
      for (const file of readdirSync(here('vm/pkg'))) {
        if (file.endsWith('.js') || file.endsWith('.wasm')) emit(`vm/pkg/${file}`, `vm/pkg/${file}`);
      }
    },
  };
}

export default defineConfig({
  plugins: [vmAssets()],
  worker: { format: 'es' },
});
