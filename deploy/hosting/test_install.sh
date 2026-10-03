#!/usr/bin/env bash
# test_install.sh: tests of install.sh's functions, without an install: `bash deploy/hosting/test_install.sh`.
# It sources the regions of install.sh between `# --- <name>: begin` and `# --- <name>: end` into a
# temporary tree and runs each case in a fresh bash with install.sh's options (set -euo pipefail).
# Network-free, nothing as root, nothing left behind.
#
# git: no repository is created (`git init` is refused to the agents' profile). A fake `git` first on PATH
# serves `ls-tree` and `check-attr` from fixture files in the documented -z formats, computes `hash-object`
# as git does (sha1 of "blob <size>\0" and the bytes), and prints a set version; the real git is never run.
# The environment is sanitised anyway (GIT_DIR and friends unset), as a pre-push hook would pass them.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

here="$(cd "$(dirname "$0")" && pwd -P)"
install="${1:-$here/install.sh}"
repo="$(cd "$here/../.." && pwd -P)"
root="$(mktemp -d)"
shared="$root/shared" # stands for the shared /tmp: read-only, so any file put there fails the case
trap 'chmod -R u+w "$root"; rm -rf "$root"' EXIT
mkdir "$shared" "$root/build" "$root/bin" "$root/fake" "$root/work"
chmod 0555 "$shared"

# ---------------------------------------------------------------- the regions, and the fake git
lib="$root/lib.sh"
grep -m1 '^die() ' "$install" >"$lib"
for name in "private tmp" "git version" "archive checks" "replay manifest" "lock comparison" "ELF scan"; do
  region="$(sed -n "/^# --- $name: begin\$/,/^# --- $name: end\$/p" "$install")"
  [ -n "$region" ] || { echo "test_install: no region '$name' in $install" >&2; exit 1; }
  printf '%s\n' "$region" >>"$lib"
done

cat >"$root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
f="$FAKE_GIT"
[ "${1:-}" = -C ] && shift 2
case "${1:-}" in
  --version) cat "$f/version"; exit "$(cat "$f/version.rc")" ;;
  ls-tree) if [[ " $* " == *" --name-only "* ]]; then cat "$f/names"; else cat "$f/tree"; fi ;;
  check-attr) cat >/dev/null; cat "$f/attrs"; exit "$(cat "$f/attrs.rc")" ;;
  hash-object) file="${*: -1}"; { printf 'blob %d\0' "$(stat -c %s "$file")"; cat "$file"; } | sha1sum | cut -d' ' -f1 ;;
  *) echo "fake git: unexpected: $*" >&2; exit 2 ;;
esac
EOF
chmod 0755 "$root/bin/git"
export FAKE_GIT="$root/fake"
echo "git version 2.43.0" >"$FAKE_GIT/version"
echo 0 >"$FAKE_GIT/version.rc"
echo 0 >"$FAKE_GIT/attrs.rc"

# fixture_tree DIR: the fake git's `ls-tree -r -z` and `--name-only` of the files under DIR, as a commit of them.
fixture_tree() {
  local f mode
  : >"$FAKE_GIT/tree"
  : >"$FAKE_GIT/names"
  while IFS= read -r -d '' f; do
    mode=100644
    [ -x "$1/$f" ] && mode=100755
    printf '%s blob %s\t%s\0' "$mode" "$("$root/bin/git" -C "$1" hash-object --no-filters -- "$1/$f")" "$f" >>"$FAKE_GIT/tree"
    printf '%s\0' "$f" >>"$FAKE_GIT/names"
  done < <(cd "$1" && find . -type f -printf '%P\0' | LC_ALL=C sort -z)
}
# attrs VALUE...: the fake check-attr's answer, export-subst then export-ignore for each path, VALUE in turn.
attrs() {
  local p i=0 values=("$@")
  : >"$FAKE_GIT/attrs"
  while IFS= read -r -d '' p; do
    for a in export-subst export-ignore; do
      printf '%s\0%s\0%s\0' "$p" "$a" "${values[i % ${#values[@]}]}" >>"$FAKE_GIT/attrs"
      i=$((i + 1))
    done
  done <"$FAKE_GIT/names"
}

# ---------------------------------------------------------------- cases
pass=0
fail=0
# check ok|refused NAME SCRIPT: SCRIPT after private_tmp, in a fresh bash with the regions; the shared
# directory stays empty, and the private one holds nothing once SCRIPT succeeds (after a refusal, the
# install's EXIT trap removes it).
check() {
  local want="$1" name="$2" out rc=0 got leftover
  out="$(cd "$root/work" && TMPDIR="$shared" PATH="$root/bin:$PATH" bash -c \
    'set -euo pipefail; source "$1"; private_tmp "$2"; '"$3"'; echo "tmpdir=$tmpdir"' _ "$lib" "$root/build" 2>&1)" \
    || rc=$?
  got=ok
  [ "$rc" = 0 ] || got=refused
  leftover="$(find "$shared" -mindepth 1 -print -quit)"
  [ "$got" = refused ] || leftover="${leftover:-$(find "$root/build" -mindepth 1 ! -type d -print -quit)}"
  if [ "$got" = "$want" ] && [ -z "$leftover" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $name: $got (want $want)${leftover:+, left $leftover}"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /'
  fi
  rm -rf "${root:?}/build/"tmp.*
}
assert() {  # assert NAME COMMAND...
  if "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1"; fi
}

# Remark 1: one private directory, its path in TMPDIR, under the given directory, 0700.
check ok "private_tmp: 0700 under the build directory, TMPDIR at it" '
  case "$tmpdir" in "$2"/tmp.*) ;; *) exit 1 ;; esac
  [ "$TMPDIR" = "$tmpdir" ] && [ "$(stat -c %a "$tmpdir")" = 700 ]'
# Remark 1: the functions take their temporary files from it, never from a bare mktemp (the shared /tmp).
assert "install.sh: no mktemp without the private directory" \
  bash -c '! grep -nE "mktemp( -d)?\)|mktemp( -d)? \"?(/tmp|/var/tmp)" "$1"' _ "$install"
# Remark 1: one EXIT trap, set after private_tmp, removing the private directory; the same at the end.
traps="$(grep -nE "^[[:space:]]*trap '[^']+' EXIT" "$install")"
assert "install.sh: one EXIT trap, naming \$tmpdir" \
  bash -c '[ "$(printf "%s\n" "$1" | wc -l)" = 1 ] && [[ "$1" == *"\"\$tmpdir\""* ]]' _ "$traps"
assert "install.sh: private_tmp before the trap" \
  bash -c '[ "$(grep -n "^  private_tmp \"\$PREFIX/.build\"" "$1" | cut -d: -f1)" -lt "${2%%:*}" ]' _ "$install" "$traps"
assert "install.sh: the private directory removed before trap - EXIT" \
  bash -c 'grep -B1 "^  trap - EXIT" "$1" | head -n1 | grep -qF "\"\$tmpdir\""' _ "$install"

# Remark 5 / N17: git older than 2.40 refused, an unreadable version refused.
for v in "2.43.0:ok" "2.40.0:ok" "2.40.1.windows.1:ok" "3.0.0:ok" "2.39.5:refused" "1.99.0:refused" "2:refused" \
  "x.y:refused"; do
  echo "git version ${v%%:*}" >"$FAKE_GIT/version"
  check "${v##*:}" "check_git: ${v%%:*}" check_git
done
echo "git version 2.43.0" >"$FAKE_GIT/version"
echo 1 >"$FAKE_GIT/version.rc"
check refused "check_git: git --version fails" check_git
echo 0 >"$FAKE_GIT/version.rc"

# A commit of three files (one executable) for the archive checks.
commit="$root/commit"
mkdir -p "$commit/services/attest" "$commit/crates/a"
echo 'print("hi")' >"$commit/services/attest/attest.py"
printf '[package]\nname = "a"\n' >"$commit/crates/a/Scarb.toml"
printf '#!/bin/sh\n' >"$commit/crates/a/run.sh"
chmod +x "$commit/crates/a/run.sh"
fixture_tree "$commit"
stage="$root/stage"
reset_stage() { rm -rf "$stage"; cp -a "$commit" "$stage"; }

# Remark 5 / N17: check_attributes fails closed.
attrs unspecified unset
check ok "check_attributes: nothing set" 'check_attributes "$PWD" HEAD services crates'
attrs unspecified set
check refused "check_attributes: export-ignore set" 'check_attributes "$PWD" HEAD services crates'
attrs '$Format:%s$' unspecified
check refused "check_attributes: export-subst set" 'check_attributes "$PWD" HEAD services crates'
attrs unspecified unset
echo 128 >"$FAKE_GIT/attrs.rc"
check refused "check_attributes: check-attr fails (git < 2.40: no --source)" 'check_attributes "$PWD" HEAD services crates'
: >"$FAKE_GIT/attrs"
check refused "check_attributes: check-attr fails and prints nothing" 'check_attributes "$PWD" HEAD services crates'
echo 0 >"$FAKE_GIT/attrs.rc"
check refused "check_attributes: check-attr prints nothing, status 0" 'check_attributes "$PWD" HEAD services crates'
attrs unspecified unset
head -c "$(( $(stat -c %s "$FAKE_GIT/attrs") / 2 ))" "$FAKE_GIT/attrs" >"$FAKE_GIT/attrs.half"
mv "$FAKE_GIT/attrs.half" "$FAKE_GIT/attrs"
check refused "check_attributes: an attribute missing for a path" 'check_attributes "$PWD" HEAD services crates'
attrs unspecified unset

# check_archive (its temporary files: remark 1).
reset_stage
check ok "check_archive: the commit's bytes and modes" "check_archive \"\$PWD\" HEAD '$stage' services crates"
reset_stage
echo extra >"$stage/crates/a/extra.txt"
check refused "check_archive: a file not in the commit" "check_archive \"\$PWD\" HEAD '$stage' services crates"
reset_stage
echo 'print("changed")' >"$stage/services/attest/attest.py"
check refused "check_archive: a file that differs" "check_archive \"\$PWD\" HEAD '$stage' services crates"
reset_stage
chmod -x "$stage/crates/a/run.sh"
check refused "check_archive: a mode that differs" "check_archive \"\$PWD\" HEAD '$stage' services crates"
reset_stage
rm "$stage/crates/a/Scarb.toml"
check refused "check_archive: a file missing" "check_archive \"\$PWD\" HEAD '$stage' services crates"

# N15: the strip, checked with tomllib.
manifests="$root/manifests"
mkdir "$manifests"
for m in "$repo"/crates/*/Scarb.toml; do
  crate="$(basename "$(dirname "$m")")"
  cp "$m" "$manifests/$crate.toml"
  check ok "strip_test_parts: crates/$crate/Scarb.toml" \
    "strip_test_parts '$manifests/$crate.toml'
     python3 -I -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], \"rb\")); assert \"dev-dependencies\" not in d' \
       '$manifests/$crate.toml'"
done
cat >"$manifests/hidden.toml" <<'EOF'
[package]
name = "x"
version = "0.1.0"

[dependencies]
fixed = "0.4.0"

[tool.x]
allow-prebuilt-plugins-doc = """
[dependencies.evil]
version = "1.0"
allow-prebuilt-plugins"""
EOF
check refused "strip_test_parts: a table hidden in a multi-line string (N15)" "strip_test_parts '$manifests/hidden.toml'"
cat >"$manifests/opened.toml" <<'EOF'
[package]
name = "x"
version = "0.1.0"

[dev-dependencies]
snforge_std = "0.64.0"
note = """
[dependencies.evil]
version = "1.0"
"""
EOF
check refused "strip_test_parts: a string opened in a stripped section" "strip_test_parts '$manifests/opened.toml'"
cat >"$manifests/other.toml" <<'EOF'
[package]
name = "x"
version = "0.1.0"

[dev-dependencies]
snforge_std = "0.64.0"

[tool]
fmt.workspace = true
allow-prebuilt-plugins = ["snforge_std"]
EOF
check refused "strip_test_parts: a key it drops, outside tool.scarb" "strip_test_parts '$manifests/other.toml'"
# N18: the snforge guard is one process; a match followed by more than a pipe's buffer still refuses.
{
  printf '[package]\nname = "x"\nversion = "0.1.0"\n\n[dependencies]\nsnforge_x = "1.0"\n\n[tool.pad]\n'
  for i in $(seq 1 2000); do printf 'k%d = "%s"\n' "$i" "$(printf '%0100d' 0)"; done
} >"$manifests/sigpipe.toml"
check refused "strip_test_parts: snforge named, 200 KB after it (N18)" "strip_test_parts '$manifests/sigpipe.toml'"

# N16: the settled lock holds only packages of the committed one.
locks="$root/locks"
mkdir "$locks"
cp "$repo/crates/slingfall_replay/Scarb.lock" "$locks/committed.lock"
# write_lock OUT EDIT: the committed lock without the test-only packages, EDIT (Python) applied to its list.
write_lock() {
  python3 -I - "$locks/committed.lock" "$1" "$2" <<'EOF'
import sys, tomllib
packages = [p for p in tomllib.load(open(sys.argv[1], "rb"))["package"]
            if not p["name"].startswith(("snforge", "assert_macros", "slingfall_testing"))]
exec(sys.argv[3])
with open(sys.argv[2], "w") as f:
    f.write("version = 1\n")
    for p in packages:
        f.write("\n[[package]]\n" + "".join(f'{k} = "{p[k]}"\n' for k in ("name", "version", "source", "checksum") if k in p))
EOF
}
write_lock "$locks/subset.lock" "pass"
check ok "check_lock: the committed lock less its dev-dependencies" "check_lock '$locks/subset.lock' '$locks/committed.lock'"
check ok "check_lock: the committed lock itself" "check_lock '$locks/committed.lock' '$locks/committed.lock'"
write_lock "$locks/bumped.lock" 'next(p for p in packages if p["name"] == "fixed")["version"] = "0.4.9"'
check refused "check_lock: a version the committed lock does not hold" "check_lock '$locks/bumped.lock' '$locks/committed.lock'"
write_lock "$locks/checksum.lock" 'next(p for p in packages if "checksum" in p)["checksum"] = "sha256:" + "0" * 64'
check refused "check_lock: another checksum" "check_lock '$locks/checksum.lock' '$locks/committed.lock'"
write_lock "$locks/extra.lock" 'packages.append({"name": "evil", "version": "1.0.0", "source": "registry+https://scarbs.xyz/"})'
check refused "check_lock: an extra package" "check_lock '$locks/extra.lock' '$locks/committed.lock'"
printf 'version = 1\n' >"$locks/empty.lock"
check refused "check_lock: no package list" "check_lock '$locks/empty.lock' '$locks/committed.lock'"

# N19: no shared object or ELF file in the release, the archived crates/ included.
reset_stage
check ok "refuse_native: sources only" "refuse_native '$stage' '$stage'"
echo 'not really' >"$stage/crates/a/libplugin.so"
check refused "refuse_native: a .so under crates/" "refuse_native '$stage' '$stage'"
reset_stage
printf '\177ELF\002\001\001' >"$stage/crates/a/data.bin"
check refused "refuse_native: an ELF file under crates/" "refuse_native '$stage' '$stage'"
check refused "refuse_native: a directory that cannot be listed" "refuse_native '$stage' '$stage/nope'"

echo "test_install: $pass passed, $fail failed"
[ "$fail" = 0 ]
