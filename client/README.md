# Slingfall client

Vite + TypeScript + PixiJS v8 renderer of a Slingfall replay. Today it plays a recorded trace
(`public/traces/sample.json`, a placeholder until lot G4's `main_trace` emits real ones) at 60 Hz;
lot G6 adds the aim UI and the real renderer, lot G1c the cairo-vm WASM worker, lot G6b the live
mode (docs/DESIGN.md D8). Frames come through the `TraceSource` interface (`src/trace/source.ts`):
`RecordedTraceSource` reads a JSON file, the worker source comes with G6b. Scalars stay raw
Q32.32 integers (decimal strings) and become `number` only for drawing.

## Run

Node 24. From this directory:

```sh
nice -n 10 npm ci     # install exactly package-lock.json
npm run dev           # dev server on http://localhost:5173
npm run lint          # ESLint + tsc --noEmit
npm test              # Vitest, once
npm run build         # type-check and bundle into dist/
```
