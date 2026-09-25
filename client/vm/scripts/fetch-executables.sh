#!/usr/bin/env bash
# Copies the slingfall replay executables that the client runs into client/vm/fixtures/replay/,
# where the worker, the tests and the app build load them (lot G6b):
#   main_trace.executable.json   crates/slingfall_replay: the whole level in one run, trace lines
#   init.executable.json         crates/slingfall_replay: init(level) -> ChunkState
#   step_chunk.executable.json   crates/slingfall_replay: step_chunk(state, inputs, shot, k, trace)
#   outputs.executable.json      client/vm/fixtures/outputs: outputs(state, inputs) -> D4 outputs
#
#   client/vm/scripts/fetch-executables.sh [--build]
#
#   --build   run `scarb build` on both packages first (~3 min cold)
set -euo pipefail

VM="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$VM/../.." && pwd)"
REPLAY="$ROOT/crates/slingfall_replay"
OUTPUTS="$VM/fixtures/outputs"
DEST="$VM/fixtures/replay"

for arg in "$@"; do
  case "$arg" in
    --build)
      nice -n 10 scarb --manifest-path "$REPLAY/Scarb.toml" build
      nice -n 10 scarb --manifest-path "$OUTPUTS/Scarb.toml" build
      ;;
    *) sed -n '2,11p' "$0"; exit 64 ;;
  esac
done

mkdir -p "$DEST"
copy() {
  [ -f "$1" ] || { echo "missing $1: run with --build" >&2; exit 1; }
  cp "$1" "$DEST/"
  echo "$DEST/$(basename "$1") ($(wc -c <"$1") bytes)"
}
for name in main_trace init step_chunk; do copy "$REPLAY/target/dev/$name.executable.json"; done
copy "$OUTPUTS/target/dev/outputs.executable.json"
