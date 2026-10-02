#!/usr/bin/env bash
# install.sh: installs slingfall-attest (services/attest, the provisional tier) on this machine.
# The owner reads it and runs it AS ROOT from a root-owned checkout fetched by hash from GitHub,
# never from an agent's clone (docs/hosting.md "Install"):
#
#   deploy/hosting/install.sh [--user NAME] [--yes]
#
#   --user NAME   the dedicated system user the owner created (default slingfall-attest)
#   --yes         do not ask before acting (the plan is printed either way)
#
# What it does, in order (each step is skipped when already done, so it can be run again):
#   1. checks: root; this checkout is root-owned, not group/other-writable, clean, and at a commit;
#      the service user exists; the key file exists with that owner and mode 0600 (stat only: the
#      key is never read, copied or printed);
#   2. scarb $SCARB_VERSION, the official release tarball, sha256-checked, into
#      /opt/slingfall/scarb (root-owned);
#   3. the release /opt/slingfall/releases/<sha>: the files the service runs (git archive of this
#      commit) plus the prebuilt replay (crates/slingfall_replay/target), compiled by the
#      unprivileged user `nobody` in a scratch copy under /var/tmp (never as root), then checked
#      on the pile10 reference shot, then made root-owned and read-only; /opt/slingfall/current
#      points at it; REVISION holds the sha;
#   4. /etc/slingfall/attest.env from attest.env.example when it does not exist (never overwritten);
#   5. /etc/systemd/system/slingfall-attest.service, daemon-reload, enable.
# It never starts or restarts the service: that is the owner's command at the end.
set -euo pipefail

SCARB_VERSION=2.19.4
SCARB_NAME="scarb-v$SCARB_VERSION-x86_64-unknown-linux-gnu"
# checksums.sha256 of the GitHub release v2.19.4 of software-mansion/scarb.
SCARB_SHA256=3832b9d79640e5385372025be53b5a7dbdbee5ca1b2c7ab5d5c21e090dc9e108
SCARB_URL="https://github.com/software-mansion/scarb/releases/download/v$SCARB_VERSION/$SCARB_NAME.tar.gz"
PREFIX=/opt/slingfall
ETC=/etc/slingfall
KEY="$ETC/attest.key"
UNIT=/etc/systemd/system/slingfall-attest.service
BUILD_USER=nobody
MEMORY_MAX=2G # docs/hosting.md "Resources": one pile10 replay measured at 0.3 GB peak
# What the release holds (paths of this commit): the service, the modules it imports, the replay's
# sources and level fixtures, the note.
RELEASE_PATHS=(services/attest tools crates fixtures Scarb.toml Scarb.lock .tool-versions docs/hosting.md
  deploy/hosting)

ATTEST_USER=slingfall-attest
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) ATTEST_USER="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

die() { echo "install.sh: $*" >&2; exit 1; }
say() { echo "install.sh: $*"; }

# ------------------------------------------------------------------ 1. checks (nothing changes)
[ "$(id -u)" = 0 ] || die "run as root (the tree it installs must be root-owned)"
SRC="$(cd "$(dirname "$0")/../.." && pwd -P)"
case "$SRC" in /home/*) die "$SRC is under /home: fetch the revision as root elsewhere (docs/hosting.md)" ;; esac
dir="$SRC"
while :; do
  [ "$(stat -c %u "$dir")" = 0 ] || die "$dir is not owned by root"
  [ $(( 0$(stat -c %a "$dir") & 022 )) = 0 ] || die "$dir is group- or other-writable"
  [ "$dir" = / ] && break
  dir="$(dirname "$dir")"
done
bad="$(find "$SRC" ! -type l \( ! -uid 0 -o -perm /022 \) -print -quit)"
[ -z "$bad" ] || die "$bad is not root-owned or is group/other-writable: fetch the revision as root"
SHA="$(git -C "$SRC" rev-parse --verify 'HEAD^{commit}')"
[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] || die "$SRC has local changes"
grep -qx "scarb $SCARB_VERSION" "$SRC/.tool-versions" || die ".tool-versions does not pin scarb $SCARB_VERSION: update install.sh"
id -u "$ATTEST_USER" >/dev/null 2>&1 || die "no user $ATTEST_USER: create it first (docs/hosting.md)"
id -u "$BUILD_USER" >/dev/null 2>&1 || die "no user $BUILD_USER"
[ -f "$KEY" ] || die "no key file $KEY (docs/hosting.md: the owner writes it)"
[ "$(stat -c '%U %a' "$KEY")" = "$ATTEST_USER 600" ] || die "$KEY must be owned by $ATTEST_USER with mode 0600"
REL="$PREFIX/releases/$SHA"

# ------------------------------------------------------------------ plan
say "installing slingfall-attest at revision $SHA from $SRC"
say "  service user: $ATTEST_USER; build user: $BUILD_USER; key file: $KEY (not read)"
if [ -x "$PREFIX/scarb/$SCARB_NAME/bin/scarb" ]; then
  say "  scarb: $PREFIX/scarb/$SCARB_NAME present, kept"
else
  say "  scarb: download $SCARB_URL, check sha256 $SCARB_SHA256, extract to $PREFIX/scarb/$SCARB_NAME"
fi
if [ -d "$REL" ]; then
  say "  release: $REL present, kept"
else
  say "  release: git archive $SHA (${RELEASE_PATHS[*]}) into $REL;"
  say "           build the replay as $BUILD_USER in a scratch copy under /var/tmp, check pile10, then root-owned, read-only"
fi
say "  link: $PREFIX/current -> releases/$SHA (now: $(readlink "$PREFIX/current" 2>/dev/null || echo none))"
if [ -e "$ETC/attest.env" ]; then
  say "  env: $ETC/attest.env present, kept"
else
  say "  env: $ETC/attest.env from deploy/hosting/attest.env.example (root:$ATTEST_USER 0640): edit it before the start"
fi
say "  unit: $UNIT (User=$ATTEST_USER, MemoryMax=$MEMORY_MAX), daemon-reload, enable (no start, no restart)"
if [ "$YES" != 1 ]; then
  read -r -p "install.sh: proceed? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || die "nothing done"
fi
umask 022

# ------------------------------------------------------------------ 2. scarb
install -d -o root -g root -m 0755 "$PREFIX" "$PREFIX/releases" "$PREFIX/scarb" "$ETC"
if [ ! -x "$PREFIX/scarb/$SCARB_NAME/bin/scarb" ]; then
  tmp="$(mktemp -d "$PREFIX/scarb/.download.XXXXXX")"
  curl -fsSL --proto '=https' -o "$tmp/scarb.tar.gz" "$SCARB_URL"
  echo "$SCARB_SHA256  $tmp/scarb.tar.gz" | sha256sum -c --quiet || die "scarb tarball: sha256 mismatch"
  tar -xzf "$tmp/scarb.tar.gz" -C "$tmp" --no-same-owner
  chown -R root:root "$tmp/$SCARB_NAME"
  chmod -R go-w "$tmp/$SCARB_NAME"
  mv -T "$tmp/$SCARB_NAME" "$PREFIX/scarb/$SCARB_NAME"
  rm -rf "$tmp"
  say "scarb $SCARB_VERSION installed"
fi
ln -sfn "$SCARB_NAME" "$PREFIX/scarb/current.new" && mv -T "$PREFIX/scarb/current.new" "$PREFIX/scarb/current"
SCARB_PATH="$PREFIX/scarb/current/bin:/usr/bin:/bin"

# ------------------------------------------------------------------ 3. the release
if [ ! -d "$REL" ]; then
  stage="$(mktemp -d "$PREFIX/releases/.stage.XXXXXX")"
  build="$(mktemp -d /var/tmp/slingfall-build.XXXXXX)"
  trap 'rm -rf "$stage" "$build"' EXIT
  git -C "$SRC" archive "$SHA" "${RELEASE_PATHS[@]}" | tar -x -C "$stage"
  # The compile runs as an unprivileged user in a scratch copy, its HOME and scarb cache there too.
  mkdir "$build/src" "$build/home"
  cp -a "$stage/." "$build/src/"
  chown -R "$BUILD_USER:$(id -gn "$BUILD_USER")" "$build"
  as_build() {
    runuser -u "$BUILD_USER" -- env -i PATH="$SCARB_PATH" HOME="$build/home" SCARB_CACHE="$build/home/scarb-cache" \
      SCARB_CONFIG="$build/home/scarb-config" RAYON_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1 "$@"
  }
  say "building the replay as $BUILD_USER in $build (a few minutes)"
  (cd "$build/src/crates/slingfall_replay" && as_build scarb build)
  # The pile10 reference shot through the service's own replay: the committed golden outputs.
  (cd "$build/src" && as_build python3 - <<'EOF'
import json, sys
sys.path.insert(0, "services/attest")
import attest, golden
case = next(c for c in json.load(open("fixtures/golden/cases.json"))["cases"] if c["name"] == "pile10-reference")
want = [int(v, 16) for v in json.load(open("fixtures/golden/pile10-reference.json"))["outputs"]]
got = attest.scarb_replay("pile10", golden.case_inputs(case))
assert got == want, f"pile10-reference: {got} != {want}"
print("install.sh: pile10-reference replays to its golden outputs")
EOF
  )
  cp -a "$build/src/crates/slingfall_replay/target" "$stage/crates/slingfall_replay/target"
  echo "$SHA" >"$stage/REVISION"
  chown -R root:root "$stage"
  chmod -R a-w,a+rX "$stage"
  chmod 0755 "$stage"
  mv -T "$stage" "$REL"
  rm -rf "$build"
  trap - EXIT
  say "release $REL installed"
fi
ln -sfn "releases/$SHA" "$PREFIX/current.new" && mv -T "$PREFIX/current.new" "$PREFIX/current"

# ------------------------------------------------------------------ 4. environment file
NEW_ENV=0
if [ ! -e "$ETC/attest.env" ]; then
  install -o root -g "$ATTEST_USER" -m 0640 "$SRC/deploy/hosting/attest.env.example" "$ETC/attest.env"
  NEW_ENV=1
fi

# ------------------------------------------------------------------ 5. the unit
sed -e "s/@ATTEST_USER@/$ATTEST_USER/g" -e "s/@MEMORY_MAX@/$MEMORY_MAX/g" \
  "$SRC/deploy/hosting/slingfall-attest.service" >"$UNIT.new"
chmod 0644 "$UNIT.new" && mv -T "$UNIT.new" "$UNIT"
systemctl daemon-reload
systemctl enable slingfall-attest.service

say "done: revision $SHA"
[ "$NEW_ENV" = 1 ] && say "edit $ETC/attest.env (ATTEST_CONTRACT, STARKNET_RPC_URL) before the start"
say "then: systemctl restart slingfall-attest && curl -s http://127.0.0.1:8547/health"
