#!/bin/bash

# Double-click launcher for the Obsidian plugin installer (install.js) on macOS.
# Keep it in the same folder as install.js.
#
# 1) Uses a Node.js 22+ from PATH, Homebrew or nvm if there is one.
# 2) Otherwise re-uses, or downloads, a private copy in
#      ~/Library/Application Support/node
#    shared by the Zotero MCP, Obsidian plugin and Obsidian bridge installers. Only the build for
#    this Mac's CPU is downloaded (newest LTS; MCP_NODE_CHANNEL=current for
#    the newest "Current" release). The SHA-256 checksum is verified before
#    anything is unpacked. No admin rights, no shell profile changes.
#    Set MCP_NO_NODE_DOWNLOAD=1 to disable the download.
# 3) Runs `node install.js` and keeps the window open so you can read it.
#
# If double-clicking is blocked by macOS, open Terminal, type `bash `, drag this
# file into the window and press Enter.

MIN_NODE=22
NODE_CHANNEL="${MCP_NODE_CHANNEL:-lts}"
NODE_BASE_URL="https://nodejs.org/download/release"
NODE_HOME_DIR="$HOME/Library/Application Support/node"

cd "$(dirname "$0")" || exit 1

pause_and_exit() {
  echo
  printf "Press any key to close."
  read -n 1 -s -r
  echo
  exit "$1"
}

node_arch() {
  case "$(uname -m)" in
    arm64)  echo "arm64" ;;
    x86_64) echo "x64" ;;
    *)      return 1 ;;
  esac
}

# True if `node` on the current PATH is at least MIN_NODE.
node_ok() {
  local major
  command -v node >/dev/null 2>&1 || return 1
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  [ -n "$major" ] && [ "$major" -ge "$MIN_NODE" ]
}

# Newest previously downloaded Node for this CPU architecture (a copy either
# installer put into $NODE_HOME_DIR), if it meets MIN_NODE.
find_bootstrapped_node() {
  local arch newest saved="$PATH"
  arch="$(node_arch)" || return 1
  [ -d "$NODE_HOME_DIR" ] || return 1
  newest="$(cd "$NODE_HOME_DIR" && ls -d node-v*-darwin-"$arch" 2>/dev/null \
    | sort -t. -k1.7,1n -k2,2n -k3,3n | tail -1)"
  if [ -n "$newest" ] && [ -x "$NODE_HOME_DIR/$newest/bin/node" ]; then
    PATH="$NODE_HOME_DIR/$newest/bin:$PATH"
    export PATH
    node_ok && return 0
    PATH="$saved"; export PATH
  fi
  return 1
}

find_node() {
  local saved="$PATH"
  # 1) already on PATH
  node_ok && return 0
  if command -v node >/dev/null 2>&1; then
    echo "Node.js on PATH is $(node -v); this installer needs $MIN_NODE or newer."
  fi
  # 2) Homebrew (Apple Silicon, then Intel)
  for dir in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$dir/node" ]; then
      PATH="$dir:$saved"; export PATH
      node_ok && return 0
      PATH="$saved"; export PATH
    fi
  done
  # 3) nvm: load it, then use the default version
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
    nvm use default >/dev/null 2>&1 || nvm use node >/dev/null 2>&1
    node_ok && return 0
    PATH="$saved"; export PATH
  fi
  # 4) a copy downloaded earlier by one of the installers
  find_bootstrapped_node
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Prints the newest version (e.g. v24.15.0) of the requested channel that has a
# macOS tarball for this CPU. index.tab is tab-separated, newest version first;
# columns: version date files npm v8 uv zlib openssl modules lts security.
# "lts" is a codename for LTS releases and "-" otherwise. A release whose
# files list does not (yet) contain our macOS tarball is skipped.
pick_node_version() { # $1=index.tab  $2=arch  $3=lts|current
  awk -F'\t' -v tok="osx-$2-tar" -v ch="$3" '
    NR > 1 && $1 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
      n = split($3, f, ",")
      has = 0
      for (i = 1; i <= n; i++) if (f[i] == tok) has = 1
      if (!has) next
      if (ch == "current" || ($10 != "-" && $10 != "" && $10 != "false")) { print $1; exit }
    }' "$1"
}

# Downloads Node.js into $NODE_HOME_DIR and puts it on PATH for this run.
bootstrap_node() {
  local arch tmp version dir_url expected file actual stage dirname
  arch="$(node_arch)" || { echo "Unsupported CPU architecture: $(uname -m)"; return 1; }
  case "$NODE_CHANNEL" in
    lts|current) ;;
    *) echo "MCP_NODE_CHANNEL must be 'lts' or 'current' (got: $NODE_CHANNEL)"; return 1 ;;
  esac

  echo "No Node.js $MIN_NODE+ found. Downloading the newest $NODE_CHANNEL release from nodejs.org into"
  echo "  $NODE_HOME_DIR"
  echo "(no admin rights needed; set MCP_NO_NODE_DOWNLOAD=1 to skip this)"
  echo

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/mcp-node.XXXXXX")" || { echo "Could not create a temporary folder."; return 1; }

  if ! curl -fsSL --retry 2 -o "$tmp/index.tab" "$NODE_BASE_URL/index.tab"; then
    echo "Download of the release index failed: $NODE_BASE_URL/index.tab"
    rm -rf "$tmp"; return 1
  fi
  version="$(pick_node_version "$tmp/index.tab" "$arch" "$NODE_CHANNEL")"
  if ! echo "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "No $NODE_CHANNEL release with a macOS ($arch) download found in the release index."
    rm -rf "$tmp"; return 1
  fi
  echo "Newest $NODE_CHANNEL release for macOS ($arch): $version"

  dir_url="$NODE_BASE_URL/$version"
  if ! curl -fsSL --retry 2 -o "$tmp/SHASUMS256.txt" "$dir_url/SHASUMS256.txt"; then
    echo "Download of the checksum list failed: $dir_url/SHASUMS256.txt"
    rm -rf "$tmp"; return 1
  fi

  # Format of each line: <64 hex chars><two spaces><file name>
  file="node-$version-darwin-$arch.tar.gz"
  expected="$(awk -v f="$file" '$2 == f { print $1; exit }' "$tmp/SHASUMS256.txt")"
  if ! echo "$expected" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "No checksum for $file found in the checksum list."
    rm -rf "$tmp"; return 1
  fi

  echo "Downloading $file ..."
  if ! curl -fSL --retry 2 -o "$tmp/$file" "$dir_url/$file"; then
    echo "Download failed: $dir_url/$file"
    rm -rf "$tmp"; return 1
  fi

  actual="$(sha256_of "$tmp/$file")"
  if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    echo "SHA-256 check FAILED for $file"
    echo "  expected: $expected"
    echo "  got:      ${actual:-<could not compute>}"
    echo "Nothing was installed."
    rm -rf "$tmp"; return 1
  fi
  echo "SHA-256 OK."

  mkdir -p "$NODE_HOME_DIR" || { rm -rf "$tmp"; return 1; }
  stage="$NODE_HOME_DIR/.staging.$$"
  rm -rf "$stage"; mkdir -p "$stage"
  if ! tar -xzf "$tmp/$file" -C "$stage"; then
    echo "Extraction failed."
    rm -rf "$tmp" "$stage"; return 1
  fi
  dirname="${file%.tar.gz}"
  if [ ! -x "$stage/$dirname/bin/node" ]; then
    echo "node binary not found after extraction."
    rm -rf "$tmp" "$stage"; return 1
  fi
  rm -rf "$NODE_HOME_DIR/$dirname"
  mv "$stage/$dirname" "$NODE_HOME_DIR/$dirname"
  rm -rf "$tmp" "$stage"

  PATH="$NODE_HOME_DIR/$dirname/bin:$PATH"
  export PATH
  echo "Installed: $NODE_HOME_DIR/$dirname"
  echo
  return 0
}

if ! find_node; then
  if [ "${MCP_NO_NODE_DOWNLOAD:-}" = "1" ]; then
    echo
    echo "Node.js $MIN_NODE or newer not found."
    echo "Install Node.js (version $MIN_NODE or newer) from https://nodejs.org"
    echo "and run this file again."
    pause_and_exit 1
  fi
  if ! bootstrap_node || ! node_ok; then
    echo
    echo "Could not set up Node.js automatically."
    echo "Install Node.js (version $MIN_NODE or newer) from https://nodejs.org"
    echo "and run this file again."
    pause_and_exit 1
  fi
fi

echo "Using Node: $(command -v node) ($(node -v))"
echo

node install.js "$@"
status=$?

echo
if [ "$status" -eq 0 ]; then
  echo "Done."
else
  echo "Installer exited with status $status."
fi
pause_and_exit "$status"
