#!/usr/bin/env bash
# Publishes the client's Sepolia build for slingfall.bal7hazar.com (docs/hosting.md "The client on
# slingfall.bal7hazar.com"). Caddy serves $SITE_ROOT/current. Same layout as Grim World's
# tools/site/deploy-site.sh: releases/<sha>-<UTC time>/, a `current` symlink, `deployed`, `deploy.lock`,
# `deploy.log`. It installs no timer and no service: it runs by hand.
#
#   scripts/site-deploy.sh [<commit>]
#
#   <commit>   what to publish; default: origin/main (fetched first). Any commit the repository has.
#
# The build is made from a clean `git archive` export of that commit (never the working tree), with the
# base path `/` (VITE_BASE is unset). The wasm runner is not committed: client/vm/scripts/build.sh builds it
# in the export (a Rust build, no Cairo, so no heavy-build lock), and the script fails before the copy if
# dist/vm/pkg/*.wasm is missing. client/scripts/smoke-sepolia.mjs then checks the build as CI does.
# A failed run leaves `current` untouched.
#
# Files in $SITE_ROOT: current -> releases/<sha>-<UTC time>; deployed (the sha of `current`);
# deploy.lock; deploy.log (one line per run: time, sha, result, duration). Overrides, for tests:
# SLINGFALL_SITE_ROOT (default ~/site/slingfall), SLINGFALL_SITE_KEEP (releases kept, default 5).
set -euo pipefail

SITE_ROOT=$(realpath -m -- "${SLINGFALL_SITE_ROOT:-$HOME/site/slingfall}")
KEEP=${SLINGFALL_SITE_KEEP:-5}
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ref=${1:-}

case "$KEEP" in '' | *[!0-9]* | 0) echo "SLINGFALL_SITE_KEEP must be a positive integer" >&2; exit 2 ;; esac
[ $# -le 1 ] || { echo "usage: scripts/site-deploy.sh [<commit>]" >&2; exit 2; }
mkdir -p "$SITE_ROOT/releases"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$SITE_ROOT/deploy.log"; }

# One run at a time.
exec 9>"$SITE_ROOT/deploy.lock"
flock -n 9 || { log "skip: another run holds the lock"; echo "another run holds the lock" >&2; exit 75; }

start=$(date +%s)
sha=-
step=start
work=
rel=
trap 'rc=$?
  [ -z "$work" ] || rm -rf -- "$work"
  [ -z "$rel" ] || rm -rf -- "$rel.tmp"
  if [ $rc -ne 0 ]; then log "sha=$sha result=FAILED(step=$step,rc=$rc) duration=$(($(date +%s) - start))s"; fi' EXIT

t() { # t <label> <command...>: run one step and print its duration
  local label=$1 s
  shift
  step=$label
  s=$(date +%s)
  "$@"
  echo "step $label: $(($(date +%s) - s)) s"
}

step=resolve
cd "$REPO"
if [ -z "$ref" ]; then
  git fetch --quiet origin main
  ref=FETCH_HEAD
fi
commit=$(git rev-parse --verify --quiet "$ref^{commit}") || { echo "no such commit: $ref" >&2; exit 2; }
sha=$commit

# The export, in a directory of this run's own (removed by its exact name on exit).
step=export
work=$(mktemp -d "$SITE_ROOT/build.XXXXXX")
git archive "$sha" | tar -x -C "$work"
client=$work/client

t wasm "$client/vm/scripts/build.sh"
# The public build takes nothing from the caller's shell: a VITE_* variable there wins over client/.env.sepolia
# (docs/testers.md has people export VITE_ATTEST_URL=127.0.0.1:...), and would be inlined in the public bundle.
clean_env=(env -i PATH="$PATH" HOME="$HOME")
t install "${clean_env[@]}" npm --prefix "$client" ci --no-audit --no-fund
t build "${clean_env[@]}" npm --prefix "$client" run build:sepolia
dist=$client/dist
[ -f "$dist/index.html" ] || { echo "no $dist/index.html" >&2; exit 1; }
# vite build only warns when client/vm/pkg is missing: the hosted page would say "VM not built".
step=check
compgen -G "$dist/vm/pkg/*.wasm" >/dev/null || { echo "no dist/vm/pkg/*.wasm: the wasm runner is not in the build" >&2; exit 1; }
(cd "$client" && node scripts/smoke-sepolia.mjs "$dist" /)
# The bundle inlines the hosted attestation URL of .env.sepolia as VITE_ATTEST_URL (the bundles also hold
# loopback literals, the devnet defaults of src/chain/config.ts, so the value is checked, not the absence).
attest=$(sed -n 's/^VITE_ATTEST_URL=//p' "$client/.env.sepolia")
[ -n "$attest" ] || { echo "client/.env.sepolia has no VITE_ATTEST_URL" >&2; exit 1; }
grep -lF -- "VITE_ATTEST_URL:\`$attest\`" "$dist"/assets/*.js >/dev/null || { echo "no bundle inlines VITE_ATTEST_URL=$attest" >&2; exit 1; }

step=publish
# A release has a unique name, <sha>-<UTC time>: a redeploy of the same sha never touches the release
# `current` points at, so `current` never points at a missing or half-written directory.
name=$sha-$(date -u +%Y%m%dT%H%M%SZ)
rel=$SITE_ROOT/releases/$name
rm -rf -- "$rel.tmp"
cp -r "$dist" "$rel.tmp"
chmod -R a+rX "$rel.tmp"
mv -T "$rel.tmp" "$rel"
ln -sfn "releases/$name" "$SITE_ROOT/current.tmp"
mv -T "$SITE_ROOT/current.tmp" "$SITE_ROOT/current"
echo "$sha" >"$SITE_ROOT/deployed"

# Prune after the switch: keep the newest $KEEP releases, never the one `current` points at (a rollback
# may have moved it), and only
# directories named <sha>-<UTC time> (each removed by its exact name).
step=prune
cd "$SITE_ROOT/releases"
ls -1t | grep -E '^[0-9a-f]{40}-[0-9]{8}T[0-9]{6}Z$' | tail -n +$((KEEP + 1)) | while read -r old; do
  [ "$old" = "$name" ] || [ "$old" = "$(basename -- "$(readlink "$SITE_ROOT/current")")" ] || rm -rf -- "$old"
done

step=done
log "sha=$sha result=ok duration=$(($(date +%s) - start))s"
echo "published $name"
