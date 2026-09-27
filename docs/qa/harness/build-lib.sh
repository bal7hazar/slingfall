#!/usr/bin/env bash
# Bundles the client's own aim / camera / trace code into qa-lib.mjs (git-ignored by hand: not committed),
# so that the harness computes arcs, cameras and pulls with the code under test. Needs `npm ci` in client/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT="$HERE/../../../client"
ENTRY="$CLIENT/qa-lib.entry.tmp.ts"
cat > "$ENTRY" <<'TS'
export { flightArc, arcParamsFromLevel } from './src/aim/arc';
export { pullFromDrag, pullToDrag, clampPull } from './src/aim/pull';
export { fitCamera, worldToScreen, boundsOf } from './src/render/camera';
export { LevelHeader, parseTraceLine } from './src/trace/lines';
export { fixedToNumber } from './src/trace/types';
TS
(cd "$CLIENT" && npx rolldown "$ENTRY" --format esm --file "$HERE/qa-lib.mjs" >/dev/null)
rm -f "$ENTRY"
echo "$HERE/qa-lib.mjs"
