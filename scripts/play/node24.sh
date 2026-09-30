# Sourced by scripts/play.sh and scripts/play/doctor.sh (lot H4): the commands of `play.sh` need a Node
# of the major version in .tool-versions (24). When the shell's `node` is another major (a Mac with
# Node 22 first on PATH) but asdf holds a 24.x, that one's bin directory is put first on PATH, so
# `node`, `npm` and every child use it. Sets NODE_NOTE to a sentence saying so (empty when the shell's
# node is already right, or nothing suitable is installed). Installs nothing.
use_asdf_node_major() {
  local major="$1" have="" dir="" version=""
  NODE_NOTE=""
  have="$(node --version 2>/dev/null | sed 's/^v//')" || true
  [ "${have%%.*}" = "$major" ] && return 0
  command -v asdf >/dev/null 2>&1 || return 0
  # `asdf list nodejs` prints one version per line, the current one marked with `*`; newest last.
  version="$(asdf list nodejs 2>/dev/null | sed 's/^[ *]*//' | grep -E "^$major\.[0-9]+\.[0-9]+$" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)"
  [ -n "$version" ] || return 0
  dir="$(asdf where nodejs "$version" 2>/dev/null || true)"
  [ -x "$dir/bin/node" ] || return 0
  PATH="$dir/bin:$PATH"
  export PATH ASDF_NODEJS_VERSION="$version"
  NODE_NOTE="the shell's node is ${have:-missing}; using Node $version from asdf ($dir/bin)"
}
