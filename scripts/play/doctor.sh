#!/usr/bin/env bash
# `scripts/play.sh doctor` (lot L1, docs/play-local.md): checks what `scripts/play.sh up` needs and
# says how to install what is missing. Installs nothing. Exit status 1 when something required is
# missing. Supported: macOS arm64 (Apple silicon) and Linux x86_64.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAY="$ROOT/target/play"
missing=0
ok() { printf '  ok    %-16s %s\n' "$1" "$2"; }
warn() { printf '  note  %-16s %s\n' "$1" "$2"; }
bad() {
  printf '  MISS  %-16s %s\n' "$1" "$2"
  missing=1
}
want() { awk -v t="$1" '$1 == t { print $2 }' "$ROOT/.tool-versions"; }
OS="$(uname -s)" ARCH="$(uname -m)"

echo "scripts/play.sh doctor ($OS $ARCH)"
case "$OS $ARCH" in
  "Darwin arm64" | "Linux x86_64") ok platform "$OS $ARCH" ;;
  *) warn platform "$OS $ARCH: untested (macOS arm64 and Linux x86_64 are)" ;;
esac
if [ "$OS" = Darwin ]; then
  asdf_hint="brew install asdf (https://asdf-vm.com), then from the repository: asdf install"
else
  asdf_hint="asdf (https://asdf-vm.com), then from the repository: asdf install"
fi

# Node: the major version of .tool-versions (Vite 8, starknet.js 10, `node deploy/slingfall.ts`).
node_want="$(want nodejs)"
# shellcheck source=node24.sh
. "$ROOT/scripts/play/node24.sh"
use_asdf_node_major "${node_want%%.*}"
[ -n "$NODE_NOTE" ] && warn node "$NODE_NOTE (play.sh does the same)"
if command -v node >/dev/null; then
  node_have="$(node --version | sed 's/^v//')"
  if [ "${node_have%%.*}" = "${node_want%%.*}" ]; then
    [ "$node_have" = "$node_want" ] && ok node "$node_have" || ok node "$node_have (.tool-versions pins $node_want)"
  else
    bad node "$node_have, needs $node_want (major ${node_want%%.*}): asdf plugin add nodejs && asdf install nodejs $node_want"
  fi
  command -v npm >/dev/null || bad npm "missing (it ships with Node)"
else
  bad node "missing, needs $node_want: asdf plugin add nodejs && asdf install nodejs $node_want ($asdf_hint)"
fi

# scarb (the replay, the contract, the split classes); snforge only for the tests.
for tool in scarb:scarb snforge:starknet-foundry; do
  name="${tool%%:*}" plugin="${tool#*:}" version="$(want "${tool#*:}")"
  if command -v "$name" >/dev/null; then
    have="$("$name" --version 2>/dev/null | head -n1 | awk '{ print $2 }')"
    if [ "$have" = "$version" ]; then ok "$name" "$have"; else bad "$name" "$have, needs $version: asdf install $plugin $version"; fi
  elif [ "$name" = snforge ]; then
    warn snforge "missing (only the Cairo tests need it): asdf plugin add $plugin && asdf install $plugin $version"
  else
    bad "$name" "missing, needs $version: asdf plugin add $plugin && asdf install $plugin $version ($asdf_hint)"
  fi
done

# Python 3.10+, standard library only (both services, the helpers).
if command -v python3 >/dev/null && python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
  ok python3 "$(python3 --version | awk '{ print $2 }')"
else
  hint="apt install python3"
  [ "$OS" = Darwin ] && hint="brew install python"
  bad python3 "$(python3 --version 2>/dev/null || echo missing), needs 3.10 or later: $hint"
fi

for tool in curl tar; do
  command -v "$tool" >/dev/null && ok "$tool" "$(command -v "$tool")" || bad "$tool" "missing"
done

# starknet-devnet 0.10.0: installed by deploy/devnet.sh on first `up` (a release binary for both platforms).
# Same test as deploy/devnet.sh: a binary counts only if it runs (an asdf shim with no version it accepts does not).
if (PATH="$ROOT/deploy/.devnet/bin:$PATH" starknet-devnet --version >/dev/null 2>&1); then
  ok starknet-devnet "present (deploy/devnet.sh pins 0.10.0)"
else
  warn starknet-devnet "not installed, or the one on PATH does not run: the first 'up' downloads the 0.10.0 release binary into deploy/.devnet/bin/"
fi

# Rust: only while the wasm runner is not built (client/vm/pkg/, once).
if [ -f "$ROOT/client/vm/pkg/slingfall_vm_runner_bg.wasm" ]; then
  ok "wasm runner" "built (client/vm/pkg/)"
elif [ "${PLAY_NO_VM:-}" = 1 ]; then
  warn "wasm runner" "not built, PLAY_NO_VM=1: the page replays a recorded trace (no live play)"
elif command -v cargo >/dev/null && command -v rustup >/dev/null; then
  note=""
  [ "$OS" = Darwin ] && note="; on macOS wasm-bindgen-cli is compiled once too (cargo install, minutes)"
  ok rust "$(cargo --version | awk '{ print $2 }'): the first 'up' builds the wasm runner (a few minutes$note)"
else
  bad rust "needed once to build the wasm runner: https://rustup.rs (the toolchain of client/vm/runner/rust-toolchain.toml installs itself); or PLAY_NO_VM=1 (no live play)"
fi

# Ports: free, or held by a running `scripts/play.sh up`.
for pair in "PLAY_PORT:${PLAY_PORT:-5173}:client" "PLAY_DEVNET_PORT:${PLAY_DEVNET_PORT:-5050}:devnet" \
  "PLAY_ATTEST_PORT:${PLAY_ATTEST_PORT:-8547}:attest" "PLAY_PROVE_PORT:${PLAY_PROVE_PORT:-8549}:prove"; do
  var="${pair%%:*}" rest="${pair#*:}"
  port="${rest%%:*}" name="${rest#*:}"
  if python3 -c 'import socket, sys; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1])))' "$port" 2>/dev/null; then
    ok "port $port" "free ($name)"
  elif [ -f "$PLAY/$name.pid" ] || [ -f "$PLAY/devnet-$port.pid" ]; then
    ok "port $port" "held by scripts/play.sh ($name): scripts/play.sh status"
  else
    bad "port $port" "taken by another process ($name): stop it, or set $var"
  fi
done

# The local mode ignores these (scripts/play.sh "Environment").
names="$(env | grep -E '^(STARKNET|SLINGFALL|ATLANTIC|VITE|DEVNET)_[A-Za-z0-9_]*=' | cut -d= -f1 | sort -u | tr '\n' ' ')"
[ -n "$names" ] && warn environment "the local mode ignores your ${names% }"

# What is built already (a second `up` skips it).
for item in "crates/slingfall_replay/target/dev/main.executable.json:replay executables" \
  "target/dev/slingfall_split_SplitChain.contract_class.json:split classes" \
  "target/play/devnet-state.json:saved devnet state"; do
  [ -f "$ROOT/${item%%:*}" ] && ok cache "${item#*:}" || warn cache "${item#*:}: not yet (the first 'up' makes it)"
done

if [ "$missing" = 1 ]; then
  echo "doctor: something required is missing (MISS above)"
  exit 1
fi
echo "doctor: ready: scripts/play.sh up"
