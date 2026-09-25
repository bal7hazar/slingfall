#!/usr/bin/env bash
# Checks out lambdaclass/cairo-vm at the pinned revision under client/vm/vendor/cairo-vm
# (git-ignored) and applies runner/cairo-vm-reserve.patch (+16 lines: `Memory::reserve_segment`,
# `Memory::segment_capacities`). runner/Cargo.toml's `[patch]` points cairo-vm there. Idempotent:
# an existing checkout at the right revision with the patch applied is left alone.
#
#   client/vm/scripts/vendor.sh
#
# CAIRO_VM_URL overrides the remote (e.g. a local clone, for offline use).
set -euo pipefail

REV=f7ac327f8f21abd05dd6e808e513010443d9742e
URL="${CAIRO_VM_URL:-https://github.com/lambdaclass/cairo-vm}"
VM="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$VM/vendor/cairo-vm"
PATCH="$VM/runner/cairo-vm-reserve.patch"

if [ -d "$DEST/.git" ]; then
  head="$(git -C "$DEST" rev-parse HEAD)"
  if [ "$head" != "$REV" ]; then
    echo "vendor.sh: $DEST is at $head, expected $REV; delete it and rerun" >&2
    exit 1
  fi
  if git -C "$DEST" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "vendor.sh: cairo-vm $REV already vendored and patched"
    exit 0
  fi
else
  mkdir -p "$DEST"
  git -C "$DEST" init -q
  git -C "$DEST" remote add origin "$URL"
  # A single commit, no history (the remote serves any reachable commit by its full hash).
  git -C "$DEST" fetch -q --depth 1 origin "$REV"
  git -C "$DEST" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
git -C "$DEST" apply "$PATCH"
echo "vendor.sh: cairo-vm $REV vendored in $DEST, reserve patch applied"
