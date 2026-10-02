#!/usr/bin/env bash
# install.sh: installs slingfall-attest (services/attest, the provisional tier) on this machine.
# The owner reviews the revision (docs/hosting.md "Trust: what to review before an install"), then
# runs this AS ROOT from a root-owned checkout fetched by hash from GitHub, never from an agent's
# clone:
#
#   deploy/hosting/install.sh [--user NAME] [--proxy-group GROUP] [--signed-tag TAG --signer FPR] [--yes]
#
#   --user NAME          the dedicated system user the owner created (default slingfall-attest)
#   --proxy-group GROUP  the reverse proxy's group, the only one that may open the service's Unix
#                        socket (default caddy)
#   --signed-tag TAG     refuse unless TAG points at this checkout's commit and `git verify-tag`
#   --signer FPR         finds a good signature by the OpenPGP key FPR (root's keyring holds the
#                        owner's public key, imported from the owner's own machine; the agents do
#                        not hold the secret one)
#   --yes                do not ask before acting (the plan is printed either way)
#
# What it does, in order (each step is skipped when already done, so it can be run again):
#   1. checks: root; this checkout is root-owned, not group/other-writable, clean, at a commit, with
#      its git objects inside it (no gitfile, no alternates); the signed tag when asked; the service
#      user exists; the key file exists with that owner and mode 0600 (stat only: the key is never
#      read, copied or printed);
#   2. scarb $SCARB_VERSION, the official release tarball, sha256-checked, into
#      /opt/slingfall/scarb (root-owned);
#   3. the release /opt/slingfall/releases/<sha>: the files the service runs (git archive of this
#      commit), the prebuilt replay (crates/slingfall_replay/target/dev/*.executable.json) and the
#      scarb cache it was built with (scarb-cache/, offline at runtime). The archive is refused if it
#      holds compiled Python (__pycache__, *.pyc) or, in the six directories the service puts on
#      sys.path, any importable file outside PYTHON_FILES below. The compile runs as the
#      unprivileged user `nobody` (never root) in a transient systemd unit (no terminal, private
#      /tmp, no /home, no /etc/slingfall, its processes killed at the end), in a scratch directory
#      under the root-owned /opt/slingfall/.build. Only regular files are taken from what it built,
#      copied without following links. The release is made root-owned and read-only, then checked
#      as the service runs it (pile10 reference shot, again as `nobody`, confined the same way);
#      /opt/slingfall/current points at it; REVISION holds the sha;
#   4. /etc/slingfall/attest.env from attest.env.example when it does not exist (never overwritten);
#   5. /etc/systemd/system/slingfall-attest.{socket,service}, daemon-reload, enable both.
# It never starts or restarts the service: that is the owner's command at the end.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE

SCARB_VERSION=2.19.4
SCARB_NAME="scarb-v$SCARB_VERSION-x86_64-unknown-linux-gnu"
# checksums.sha256 of the GitHub release v2.19.4 of software-mansion/scarb.
SCARB_SHA256=3832b9d79640e5385372025be53b5a7dbdbee5ca1b2c7ab5d5c21e090dc9e108
SCARB_URL="https://github.com/software-mansion/scarb/releases/download/v$SCARB_VERSION/$SCARB_NAME.tar.gz"
PREFIX=/opt/slingfall
ETC=/etc/slingfall
KEY="$ETC/attest.key"
UNITS=/etc/systemd/system
BUILD_USER=nobody
MEMORY_MAX=6G # docs/hosting.md "Resources": the tower replay measured at 4.2 GB peak
SOCKET=/run/slingfall-attest/attest.sock # slingfall-attest.socket
# What the release holds (paths of this commit): the service, the modules it imports, the replay's
# sources and level fixtures, the note, these files.
RELEASE_PATHS=(services/attest tools crates fixtures Scarb.toml Scarb.lock .tool-versions docs/hosting.md
  deploy/hosting)
# The directories the service puts on sys.path (attest.py, vectors.py, encoding.py, golden.py) and the
# only importable files they may hold: whatever else sits there could be imported by the service
# user, which reads the key. A new module is added here, in the same reviewed commit.
PYTHON_DIRS=(services/attest crates/slingfall_contract/tools tools/atlantic tools/golden tools/levelc tools/tracec)
PYTHON_FILES=(services/attest/attest.py services/attest/test_attest.py crates/slingfall_contract/tools/vectors.py
  tools/atlantic/atlantic.py tools/atlantic/encoding.py tools/atlantic/test_atlantic.py tools/golden/golden.py
  tools/golden/matrix.py tools/levelc/levelc.py tools/levelc/poseidon.py tools/levelc/rules.py
  tools/levelc/test_levelc.py tools/tracec/tracec.py)

ATTEST_USER=slingfall-attest
PROXY_GROUP=caddy
YES=0
TAG=""
SIGNER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) ATTEST_USER="$2"; shift 2 ;;
    --proxy-group) PROXY_GROUP="$2"; shift 2 ;;
    --signed-tag) TAG="$2"; shift 2 ;;
    --signer) SIGNER="$2"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

die() { echo "install.sh: $*" >&2; exit 1; }
say() { echo "install.sh: $*"; }

# ------------------------------------------------------------------ 1. checks (nothing changes)
[ "$(id -u)" = 0 ] || die "run as root (the tree it installs must be root-owned)"
[[ "$ATTEST_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--user: a name of [a-z_][a-z0-9_-]*"
[[ "$PROXY_GROUP" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "--proxy-group: a name of [a-z_][a-z0-9_-]*"
getent group "$PROXY_GROUP" >/dev/null || die "no group $PROXY_GROUP (the reverse proxy's): --proxy-group"
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
# The objects `git archive` reads must be this checkout's own: no gitfile, no shared or alternate store.
[ -d "$SRC/.git" ] && [ ! -L "$SRC/.git" ] || die "$SRC/.git must be a directory (a plain git clone)"
common="$(cd "$SRC" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
[ "$common" = "$SRC/.git" ] || die "$SRC: git's common directory $common is outside the checkout"
[ ! -e "$SRC/.git/objects/info/alternates" ] || die "$SRC uses alternate object stores: clone it plainly"
SHA="$(git -C "$SRC" rev-parse --verify 'HEAD^{commit}')"
[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] || die "$SRC has local changes"
if [ -n "$TAG" ] || [ -n "$SIGNER" ]; then
  [ -n "$TAG" ] && [ -n "$SIGNER" ] || die "--signed-tag and --signer go together"
  [ "$(git -C "$SRC" rev-parse --verify "refs/tags/$TAG^{commit}")" = "$SHA" ] || die "tag $TAG does not point at $SHA"
  status="$(git -C "$SRC" verify-tag --raw "$TAG" 2>&1 >/dev/null)" || die "tag $TAG: no good signature"
  want="$(echo "$SIGNER" | tr -d ' ' | tr a-f A-F)"
  # VALIDSIG <signing key fpr> ... <primary key fpr>
  echo "$status" | awk '$2 == "VALIDSIG" { print $3; print $NF }' | grep -qxF "$want" \
    || die "tag $TAG is not signed by $want"
  say "tag $TAG: good signature by $want"
fi
grep -qx "scarb $SCARB_VERSION" "$SRC/.tool-versions" || die ".tool-versions does not pin scarb $SCARB_VERSION: update install.sh"
id -u "$ATTEST_USER" >/dev/null 2>&1 || die "no user $ATTEST_USER: create it first (docs/hosting.md)"
id -u "$BUILD_USER" >/dev/null 2>&1 || die "no user $BUILD_USER"
BUILD_GROUP="$(id -gn "$BUILD_USER")"
[ -f "$KEY" ] || die "no key file $KEY (docs/hosting.md: the owner writes it)"
[ "$(stat -c '%U %a' "$KEY")" = "$ATTEST_USER 600" ] || die "$KEY must be owned by $ATTEST_USER with mode 0600"
command -v systemd-run >/dev/null || die "systemd-run is needed (the confined build)"
REL="$PREFIX/releases/$SHA"

# ------------------------------------------------------------------ plan
say "installing slingfall-attest at revision $SHA from $SRC"
[ -n "$TAG" ] || say "  WARNING: no --signed-tag: you vouch for $SHA by your own review (docs/hosting.md \"Trust\")"
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
  say "           build the replay as $BUILD_USER in a confined transient unit under $PREFIX/.build,"
  say "           take its regular files only, make the release root-owned and read-only, check pile10"
fi
say "  link: $PREFIX/current -> releases/$SHA (now: $(readlink "$PREFIX/current" 2>/dev/null || echo none))"
if [ -e "$ETC/attest.env" ]; then
  say "  env: $ETC/attest.env present, kept"
else
  say "  env: $ETC/attest.env from deploy/hosting/attest.env.example (root:$ATTEST_USER 0640): edit it before the start"
fi
say "  units: $UNITS/slingfall-attest.socket ($SOCKET, group $PROXY_GROUP) and .service (User=$ATTEST_USER, MemoryMax=$MEMORY_MAX),"
say "         daemon-reload, enable both (no start, no restart)"
if [ "$YES" != 1 ]; then
  read -r -p "install.sh: proceed? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || die "nothing done"
fi
umask 022

# ------------------------------------------------------------------ 2. scarb
install -d -o root -g root -m 0755 "$PREFIX" "$PREFIX/releases" "$PREFIX/scarb" "$PREFIX/.build" "$ETC"
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

# as_nobody DIR CMD...: CMD as the build user in a transient unit: no terminal (stdin is a pipe or
# /dev/null), private /tmp, no /home, no /etc/slingfall, no new privileges, every process it starts
# killed when it ends.
as_nobody() {
  local dir="$1"
  shift
  systemd-run --quiet --pipe --wait --collect --uid="$BUILD_USER" --gid="$BUILD_GROUP" \
    -p WorkingDirectory="$dir" -p PrivateTmp=yes -p ProtectHome=yes -p InaccessiblePaths="$ETC" \
    -p NoNewPrivileges=yes -p KillMode=control-group -- "$@"
}

# ------------------------------------------------------------------ 3. the release
if [ ! -d "$REL" ]; then
  stage="$(mktemp -d "$PREFIX/releases/.stage.XXXXXX")"
  build="$(mktemp -d "$PREFIX/.build/run.XXXXXX")"
  trap 'rm -rf "$stage" "$build"' EXIT
  git -C "$SRC" archive "$SHA" "${RELEASE_PATHS[@]}" | tar -x -C "$stage"
  # No compiled Python anywhere, and nothing importable on the service's sys.path but PYTHON_FILES.
  odd="$(find "$stage" \( -name __pycache__ -o -name '*.pyc' -o -name '*.pyo' \) -print -quit)"
  [ -z "$odd" ] || die "the revision holds compiled Python: ${odd#"$stage"/}: refused"
  while IFS= read -r f; do
    rel="${f#"$stage"/}"
    case " ${PYTHON_FILES[*]} " in *" $rel "*) ;; *) die "$rel: not in install.sh's PYTHON_FILES: refused" ;; esac
  done < <(cd "$stage" && find "${PYTHON_DIRS[@]/#/$stage/}" -type f \( -name '*.py' -o -name '*.pyw' -o -name '*.so' \
    -o -name '*.pyd' -o -name '*.pth' \) -print)
  # The compile runs as the build user in a scratch copy, its HOME and scarb cache there too.
  mkdir "$build/src" "$build/home"
  cp -a "$stage/." "$build/src/"
  chown -R "$BUILD_USER:$BUILD_GROUP" "$build"
  say "building the replay as $BUILD_USER in $build (a few minutes)"
  as_nobody "$build/src/crates/slingfall_replay" /usr/bin/env -i PATH="$SCARB_PATH" HOME="$build/home" \
    SCARB_CACHE="$build/home/scarb-cache" SCARB_CONFIG="$build/home/scarb-config" RAYON_NUM_THREADS=1 \
    scarb build </dev/null
  # Only regular files and directories are taken from what the build user wrote, copied without
  # following links: a link to the key (or anywhere) refuses the build.
  built="$build/src/crates/slingfall_replay/target/dev"
  # The paths root copies from must still lie inside the build directory (no swapped-in link above them).
  for d in "$built" "$build/home/scarb-cache"; do
    case "$(realpath -e "$d")/" in "$build"/*) ;; *) die "$d resolves outside $build: refused" ;; esac
  done
  odd="$(find "$built" "$build/home/scarb-cache" ! -type f ! -type d -print -quit)"
  [ -z "$odd" ] || die "the build left $odd, not a regular file or directory: refused"
  install -d "$stage/crates/slingfall_replay/target/dev"
  for f in "$built"/*.executable.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || die "$f: not a regular file"
    cp -P --no-preserve=all "$f" "$stage/crates/slingfall_replay/target/dev/"
  done
  cp -RP --no-preserve=all "$build/home/scarb-cache" "$stage/scarb-cache"
  odd="$(find "$stage" ! -type f ! -type d -print -quit)"
  [ -z "$odd" ] || die "the release holds $odd, not a regular file or directory: refused"
  echo "$SHA" >"$stage/REVISION"
  chown -R root:root "$stage"
  chmod -R a-w,a+rX "$stage"
  chmod 0755 "$stage"
  # The release as the service will run it (prepare.sh, then the replay offline), as the build user,
  # confined the same way: the pile10 reference shot must give its committed golden outputs.
  install -d -o "$BUILD_USER" -g "$BUILD_GROUP" -m 0700 "$build/state"
  as_nobody "$stage" /usr/bin/env -i PATH="$SCARB_PATH" ATTEST_RELEASE="$stage" ATTEST_STATE="$build/state" \
    "$stage/deploy/hosting/prepare.sh" </dev/null
  as_nobody "$stage" /usr/bin/env -i PATH="$SCARB_PATH" HOME="$build/state" \
    SCARB_CACHE="$build/state/scarb-cache" SCARB_CONFIG="$build/state/scarb-config" SCARB_OFFLINE=true \
    RAYON_NUM_THREADS=1 PYTHONDONTWRITEBYTECODE=1 REPLAY_DIR="$build/state/work/crates/slingfall_replay" \
    python3 - <<'EOF'
import json, os, sys
from pathlib import Path
sys.path.insert(0, "services/attest")
import attest, golden
case = next(c for c in json.load(open("fixtures/golden/cases.json"))["cases"] if c["name"] == "pile10-reference")
want = [int(v, 16) for v in json.load(open("fixtures/golden/pile10-reference.json"))["outputs"]]
got = attest.scarb_replay("pile10", golden.case_inputs(case), Path(os.environ["REPLAY_DIR"]))
assert got == want, f"pile10-reference: {got} != {want}"
print("install.sh: pile10-reference replays to its golden outputs")
EOF
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

# ------------------------------------------------------------------ 5. the units
sed -e "s/@ATTEST_USER@/$ATTEST_USER/g" -e "s/@MEMORY_MAX@/$MEMORY_MAX/g" \
  "$SRC/deploy/hosting/slingfall-attest.service" >"$UNITS/slingfall-attest.service.new"
sed -e "s/@PROXY_GROUP@/$PROXY_GROUP/g" \
  "$SRC/deploy/hosting/slingfall-attest.socket" >"$UNITS/slingfall-attest.socket.new"
for u in socket service; do
  chmod 0644 "$UNITS/slingfall-attest.$u.new" && mv -T "$UNITS/slingfall-attest.$u.new" "$UNITS/slingfall-attest.$u"
done
systemctl daemon-reload
systemctl enable slingfall-attest.socket slingfall-attest.service

say "done: revision $SHA"
[ "$NEW_ENV" = 1 ] && say "edit $ETC/attest.env (ATTEST_CONTRACT, STARKNET_RPC_URL, ATTEST_CORS_ORIGIN) before the start"
say "then: systemctl start slingfall-attest.socket && systemctl restart slingfall-attest"
say "and check: curl -s --unix-socket $SOCKET http://localhost/health; systemctl show -p MainPID slingfall-attest; ss -lxp | grep $SOCKET"
