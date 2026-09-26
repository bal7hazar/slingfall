#!/usr/bin/env bash
# P1: build stwo-cairo's `run_and_prove`, `prove` and `verify` (docs/proving.md, research 05).
#
#   tools/prove/setup.sh [--native]   # clone, patch, build (idempotent); prints the binaries' directory
#
#   --native        build with `-C target-cpu=native` (local runs; never for a cached CI build,
#                   whose restoring runner may have another CPU). Also STWO_NATIVE=1.
#   STWO_JOBS=N     cargo jobs (default 4)
#
# The clone lives in tools/prove/vendor/ (git-ignored). Its own rust-toolchain.toml selects the
# toolchain (rustup installs it on first use). A stamp file records rev + patches + flags: a second
# run with the same stamp and the three binaries present does nothing.
set -euo pipefail

REV=467d5c6
REPO=https://github.com/starkware-libs/stwo-cairo
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$HERE/vendor"
SRC="$VENDOR/stwo-cairo"
PATCHES=("$HERE/vm_utils-standalone-context.patch" "$HERE/verify-proof-format.patch")
PROVER="$SRC/stwo_cairo_prover"
BIN="$PROVER/target/release"
JOBS="${STWO_JOBS:-4}"

native="${STWO_NATIVE:-0}"
[ "${1:-}" = --native ] && native=1
flags=""
if [ "$native" = 1 ]; then
  flags="-C target-cpu=native"
fi
stamp="rev=$REV patches=$(cat "${PATCHES[@]}" | sha256sum | cut -c1-16) flags=$flags"

if [ -f "$BIN/.slingfall-stamp" ] && [ "$(cat "$BIN/.slingfall-stamp")" = "$stamp" ] \
  && [ -x "$BIN/run_and_prove" ] && [ -x "$BIN/prove" ] && [ -x "$BIN/verify" ]; then
  echo "$BIN"
  exit 0
fi

mkdir -p "$VENDOR"
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet "$REPO" "$SRC" >&2
fi
if [ "$(git -C "$SRC" rev-parse --short=7 HEAD)" != "$REV" ]; then
  git -C "$SRC" fetch --quiet origin >&2 || true
fi
# A clean tree at the rev, then the patches (docs/proving.md):
# - vm_utils-standalone-context.patch (research 05): standalone executables declare their own
#   builtins, `adapt` assumes the bootloader's 11;
# - verify-proof-format.patch: `verify --proof_format binary`, and it prints the program hash and
#   the public output it verified (`VERIFICATION_OUTPUT <json>`).
git -C "$SRC" checkout --quiet --force "$REV" >&2
git -C "$SRC" checkout --quiet -- . >&2
for p in "${PATCHES[@]}"; do
  git -C "$SRC" apply "$p"
done

(
  cd "$PROVER"
  RUSTFLAGS="$flags" cargo build --release -j "$JOBS" -p stwo-cairo-dev-utils \
    --bin run_and_prove --bin prove --bin verify >&2
)
echo "$stamp" > "$BIN/.slingfall-stamp"
echo "$BIN"
