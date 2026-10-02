#!/usr/bin/env bash
# Test of `deploy/devnet.sh`'s install_devnet (lot L4): an asdf shim of starknet-devnet that fails (no version
# set) must not stop the first `scripts/play.sh up` silently. No network: the download is a local stub.
#   scripts/play/test_devnet_shim.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failed=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got '$2', want '$3'"; failed=1; fi; }

mkdir -p "$TMP/shim" "$TMP/home"
# The shim: fails on its exit code alone (asdf's message differs from case to case), runs nothing.
printf '#!/bin/sh\necho "shim: whatever asdf says"\nexit 126\n' >"$TMP/shim/starknet-devnet"
chmod +x "$TMP/shim/starknet-devnet"

# Runs install_devnet in a fresh shell: the shim first in PATH, a temporary HOME, an empty BIN_DIR.
# $1 the body of fetch_devnet; $2 the stub cargo's exit code (cargo is the fallback when the download fails).
run() {
  rm -rf "$TMP/bin" "$TMP/run"
  printf '#!/bin/sh\nexit %s\n' "$2" >"$TMP/shim/cargo"
  chmod +x "$TMP/shim/cargo"
  OUT="$(env -i HOME="$TMP/home" PATH="$TMP/shim:/usr/bin:/bin:/usr/sbin" TMP="$TMP" ROOT="$ROOT" FETCH="$1" bash -c '
    set -euo pipefail
    export DEVNET_SOURCED=1 DEVNET_BIN_DIR="$TMP/bin" DEVNET_RUN="$TMP/run"
    . "$ROOT/deploy/devnet.sh"
    eval "fetch_devnet() { $FETCH; }"
    # The first lookup caches the shim, as `up` does before installing.
    starknet-devnet --version >/dev/null 2>&1 || true
    echo "hash: $(hash | grep -c "$TMP/shim/starknet-devnet")"
    install_devnet
    echo "version: $(starknet-devnet --version)"
  ' 2>&1)"
  RC=$?
}

GOOD='printf "#!/bin/sh\necho starknet-devnet 0.10.0\n" >"$BIN_DIR/starknet-devnet"; chmod +x "$BIN_DIR/starknet-devnet"'
BAD='printf "#!/bin/sh\nexit 3\n" >"$BIN_DIR/starknet-devnet"; chmod +x "$BIN_DIR/starknet-devnet"'

run "$GOOD" 1
check "shim then download: install_devnet succeeds" "$RC" 0
check "the shim was cached before the install" "$(grep -c '^hash: 1' <<<"$OUT")" 1
check "the installed binary runs afterwards" "$(grep -c '^version: starknet-devnet 0.10.0' <<<"$OUT")" 1

run 'return 1' 1
check "download fails, cargo fails: non-zero" "$([ "$RC" -ne 0 ] && echo yes)" yes
check "it names the failed command" "$(grep -c 'cargo install starknet-devnet .* failed' <<<"$OUT")" 1

run "$BAD" 1
check "installed binary does not run: non-zero" "$([ "$RC" -ne 0 ] && echo yes)" yes
check "it names the command and its output" "$(grep -c "'starknet-devnet --version' failed" <<<"$OUT")" 1

run 'return 1' 0
check "download fails, cargo installs nothing usable: non-zero" "$([ "$RC" -ne 0 ] && echo yes)" yes

[ "$failed" = 0 ] && echo "test_devnet_shim: ok" || { echo "test_devnet_shim: FAILED"; exit 1; }
