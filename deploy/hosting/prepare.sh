#!/bin/sh
# prepare.sh: ExecStartPre of slingfall-attest.service, run as the service user (docs/hosting.md).
# scarb opens Scarb.lock for writing even for `scarb execute --no-build`, so the replay cannot run in
# the read-only release. At every start this copies, from the root-owned release into the service's
# own state directory (writable by that user only):
#   * the replay's workspace: Scarb.toml, Scarb.lock and crates/ (with the prebuilt
#     crates/slingfall_replay/target/dev/*.executable.json); attest.py --replay-dir points there;
#   * the offline scarb cache the release was built with (SCARB_CACHE; SCARB_OFFLINE=true).
# The Python code keeps running from the release. Nothing is compiled.
set -eu
RELEASE="${ATTEST_RELEASE:-/opt/slingfall/current}"
STATE="${ATTEST_STATE:-/var/lib/slingfall-attest}"
umask 077
RELEASE="$(readlink -f "$RELEASE")"
[ -f "$RELEASE/REVISION" ] || { echo "prepare.sh: $RELEASE is not an installed release" >&2; exit 1; }
for d in work scarb-cache; do
  rm -rf "$STATE/$d.new"
done
mkdir "$STATE/work.new"
cp -R --preserve=timestamps "$RELEASE/Scarb.toml" "$RELEASE/Scarb.lock" "$RELEASE/crates" "$STATE/work.new/"
cp -R --preserve=timestamps "$RELEASE/scarb-cache" "$STATE/scarb-cache.new"
chmod -R u+w "$STATE/work.new" "$STATE/scarb-cache.new"
for d in work scarb-cache; do
  rm -rf "$STATE/$d"
  mv "$STATE/$d.new" "$STATE/$d"
done
echo "prepare.sh: replay of $(cat "$RELEASE/REVISION") copied to $STATE/work"
