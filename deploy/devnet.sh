#!/usr/bin/env bash
# Local devnet of Slingfall (lot G9, docs/e2e.md).
#
#   deploy/devnet.sh [all]     install starknet-devnet if needed, start it, deploy (default)
#   deploy/devnet.sh up        install if needed and start the devnet (reused when already up)
#   deploy/devnet.sh deploy    build the class and deploy on the running devnet
#   deploy/devnet.sh down      stop the devnet this script started
#
# The devnet runs `--seed 0` (deterministic prefunded accounts); account #0 is the admin. `deploy`
# declares `Slingfall` (not `SlingfallSim`), deploys it, sets `verifier = Stub` and the attestation
# key, registers the six fixture levels and writes:
#   deploy/devnet.json   network, RPC, class hash, address, admin, attestation key, level hashes, gas
#   deploy/devnet.env    VITE_* variables of the client (docs/e2e.md), with the devnet account
#
# Environment:
#   DEVNET_PORT (5050)   DEVNET_VERSION (the latest release when unset)
#   DEVNET_ATTEST_KEY    attestation secret of the devnet (default 'slingfall-devnet': a public
#                        test key, never a real one)
#   DEVNET_OUT           deploy/devnet.json      DEVNET_ENV   deploy/devnet.env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${DEVNET_PORT:-5050}"
RPC="http://127.0.0.1:${PORT}/rpc"
BIN_DIR="$ROOT/deploy/.devnet/bin"
RUN="$ROOT/deploy/out"
PID_FILE="$RUN/devnet-${PORT}.pid"
OUT="${DEVNET_OUT:-$ROOT/deploy/devnet.json}"
ENV_OUT="${DEVNET_ENV:-$ROOT/deploy/devnet.env}"
ATTEST_KEY="${DEVNET_ATTEST_KEY:-0x736c696e6766616c6c2d6465766e6574}" # 'slingfall-devnet'
ASSET="starknet-devnet-x86_64-unknown-linux-gnu.tar.gz"
export PATH="$BIN_DIR:$HOME/.cargo/bin:$PATH"
mkdir -p "$RUN"

alive() {
  python3 - "$PORT" <<'EOF'
import sys, urllib.request
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/is_alive", timeout=2)
except Exception:
    sys.exit(1)
EOF
}

install_devnet() {
  if command -v starknet-devnet >/dev/null; then return; fi
  # The release binary (seconds) when the platform has one, else cargo (minutes, 2 jobs).
  local url
  if [ -n "${DEVNET_VERSION:-}" ]; then
    url="https://github.com/0xSpaceShard/starknet-devnet/releases/download/v${DEVNET_VERSION}/${ASSET}"
  else
    url="https://github.com/0xSpaceShard/starknet-devnet/releases/latest/download/${ASSET}"
  fi
  mkdir -p "$BIN_DIR"
  if [ "$(uname -sm)" = "Linux x86_64" ] && curl -fsSL "$url" | tar -xz -C "$BIN_DIR"; then
    echo "devnet: installed $url" >&2
  else
    echo "devnet: no release binary; cargo install starknet-devnet ${DEVNET_VERSION:-(latest)}" >&2
    cargo install -j 2 --locked starknet-devnet ${DEVNET_VERSION:+--version "$DEVNET_VERSION"}
  fi
  command -v starknet-devnet >/dev/null
}

up() {
  if alive; then
    echo "devnet: already up on $RPC" >&2
    return
  fi
  install_devnet
  echo "devnet: $(starknet-devnet --version) on $RPC (log $RUN/devnet-${PORT}.log)" >&2
  starknet-devnet --seed 0 --accounts 2 --host 127.0.0.1 --port "$PORT" >"$RUN/devnet-${PORT}.log" 2>&1 &
  echo $! >"$PID_FILE"
  for _ in $(seq 1 100); do
    if alive; then return; fi
    sleep 0.2
  done
  echo "devnet: did not start; see $RUN/devnet-${PORT}.log" >&2
  exit 1
}

down() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "devnet: stopped (port $PORT)" >&2
  fi
}

deploy() {
  [ -d "$ROOT/client/node_modules/starknet" ] || npm --prefix "$ROOT/client" ci --no-audit --no-fund
  scarb --manifest-path "$ROOT/deploy/contract/Scarb.toml" build
  local pubkey
  pubkey="$(python3 "$ROOT/services/attest/attest.py" pubkey --key "$ATTEST_KEY")"
  node "$ROOT/deploy/slingfall.ts" deploy --devnet --rpc "$RPC" --network devnet \
    --attestation-key "$pubkey" --out "$OUT"
  # The client's configuration: the devnet account signs in the page (dev only).
  node "$ROOT/deploy/slingfall.ts" account --rpc "$RPC" --with-key >"$RUN/account-${PORT}.json"
  python3 - "$RUN/account-${PORT}.json" "$OUT" >"$ENV_OUT" <<'EOF'
import json, sys
account, config = (json.load(open(path)) for path in sys.argv[1:])
print(f"VITE_SLINGFALL_ADDRESS={config['address']}")
print(f"VITE_RPC_URL={config['rpc_url']}")
print("VITE_ATTEST_URL=http://127.0.0.1:8547")
print(f"VITE_DEVNET_ACCOUNT_ADDRESS={account['address']}")
print(f"VITE_DEVNET_PRIVATE_KEY={account['private_key']}")
EOF
  echo "devnet: wrote $OUT and $ENV_OUT" >&2
}

case "${1:-all}" in
  up) up ;;
  deploy) deploy ;;
  down) down ;;
  all) up && deploy ;;
  *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
