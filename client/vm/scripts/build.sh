#!/usr/bin/env bash
# Builds the cairo-vm runner to wasm32 and binds it with wasm-bindgen:
#   client/vm/pkg/       --target web     (the Web Worker imports it)
#   client/vm/pkg-node/  --target nodejs  (Vitest and scripts/bench.mjs)
# Both are git-ignored. Runs scripts/vendor.sh first.
#
#   client/vm/scripts/build.sh [--native] [--wasm-opt]
#
#   --native    also build the native `slingfall-run` binary (runner/target/release/)
#   --wasm-opt  run `wasm-opt -O3` on both outputs (needs binaryen's wasm-opt on PATH; measured
#               as no speed gain in docs/research/04, it only shrinks the .wasm 1.55 -> 1.27 MB)
#
# wasm-bindgen-cli must match the `wasm-bindgen` crate exactly (0.2.100): taken from $WASM_BINDGEN,
# else PATH, else client/vm/tools/bin (downloaded there from the GitHub release on first use).
set -euo pipefail

WB_VERSION=0.2.100
VM="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE=0 WASM_OPT=0
for arg in "$@"; do
  case "$arg" in
    --native) NATIVE=1 ;;
    --wasm-opt) WASM_OPT=1 ;;
    *) sed -n '2,15p' "$0"; exit 64 ;;
  esac
done

"$VM/scripts/vendor.sh"

find_wasm_bindgen() {
  local c
  for c in "${WASM_BINDGEN:-}" "$(command -v wasm-bindgen || true)" "$VM/tools/bin/wasm-bindgen"; do
    if [ -n "$c" ] && [ -x "$c" ] && [ "$("$c" --version 2>/dev/null)" = "wasm-bindgen $WB_VERSION" ]; then
      echo "$c"
      return
    fi
  done
  mkdir -p "$VM/tools/bin"
  if [ "$(uname -sm)" = "Linux x86_64" ]; then
    local name="wasm-bindgen-$WB_VERSION-x86_64-unknown-linux-musl"
    curl -fsSL "https://github.com/rustwasm/wasm-bindgen/releases/download/$WB_VERSION/$name.tar.gz" \
      | tar -xz -C "$VM/tools" "$name/wasm-bindgen" >&2
    mv "$VM/tools/$name/wasm-bindgen" "$VM/tools/bin/wasm-bindgen"
    rmdir "$VM/tools/$name"
  else
    cargo install wasm-bindgen-cli --version "$WB_VERSION" --locked --root "$VM/tools" >&2
  fi
  echo "$VM/tools/bin/wasm-bindgen"
}
WB="$(find_wasm_bindgen)"

# From runner/ so that its rust-toolchain.toml (1.89.0 + wasm32 target) applies.
cd "$VM/runner"
nice -n 10 cargo build --release -j 4 --lib --target wasm32-unknown-unknown
if [ "$NATIVE" = 1 ]; then
  nice -n 10 cargo build --release -j 4 --bin slingfall-run
fi

WASM="$VM/runner/target/wasm32-unknown-unknown/release/slingfall_vm_runner.wasm"
for pair in web:pkg nodejs:pkg-node; do
  target="${pair%%:*}" out="$VM/${pair#*:}"
  rm -rf "$out"
  "$WB" --target "$target" --out-dir "$out" "$WASM"
  if [ "$WASM_OPT" = 1 ]; then
    wasm-opt -O3 --enable-bulk-memory --enable-sign-ext --enable-nontrapping-float-to-int \
      --enable-mutable-globals --enable-multivalue --enable-reference-types \
      "$out/slingfall_vm_runner_bg.wasm" -o "$out/slingfall_vm_runner_bg.wasm"
  fi
done
# pkg-node is CommonJS; the client package is `"type": "module"`.
echo '{ "type": "commonjs" }' > "$VM/pkg-node/package.json"
ls -l "$VM/pkg/slingfall_vm_runner_bg.wasm" "$VM/pkg-node/slingfall_vm_runner_bg.wasm"
