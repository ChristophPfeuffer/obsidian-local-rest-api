#!/bin/bash

# Double-click launcher for the Obsidian plugin installer (install.js) on macOS.
# Keep it in the same folder as install.js.
#
# Which Node.js is used (MIN_NODE differs: Zotero MCP 20, Obsidian plugin 22):
#
# Fresh install (nothing in the shared Node folder
#   ~/Library/Application Support/node
# used by the Zotero MCP, Obsidian plugin and Obsidian bridge installers):
#   An installed Node.js (PATH, Homebrew, nvm, nodejs.org) is used if it passes
#   the compatibility test: version >= MIN_NODE, its npm runs, and this repo's
#   installer tests (installer/*.test.cjs) pass with it. Otherwise the newest
#   LTS is downloaded into the shared Node folder (only the build for this
#   Mac's CPU; MCP_NODE_CHANNEL=current for the newest "Current" release;
#   SHA-256 verified before unpacking; no admin rights, no shell profile
#   changes; MCP_NO_NODE_DOWNLOAD=1 disables it).
#
# Re-run:
#   The Node.js in use (the shared Node folder, or one chosen earlier — saved
#   in its file "use-node"; delete that file to go back) stays, unless a NEWER
#   installed Node.js passes the compatibility test. Then you are asked whether
#   to move to it (Enter = yes) and, if so, whether to delete the copies in the
#   shared Node folder (Enter = yes). Only too-old copies there: the same offer,
#   otherwise the newest LTS is downloaded and the old copies are replaced.
#
# Claude Desktop entries that run a Node.js that is replaced or left are
# re-pointed first (installer/relink-node.cjs, config backed up); nothing is
# deleted if that fails. Other Node.js installs are never changed.
#
# Then runs `node install.js` and keeps the window open so you can read it.
#
# If double-clicking is blocked by macOS, open Terminal, type `bash `, drag this
# file into the window and press Enter.

MIN_NODE=22
NODE_CHANNEL="${MCP_NODE_CHANNEL:-lts}"
NODE_BASE_URL="https://nodejs.org/download/release"
NODE_HOME_DIR="$HOME/Library/Application Support/node"
CHOICE_FILE="$NODE_HOME_DIR/use-node"
ORIG_PATH="$PATH"

cd "$(dirname "$0")" || exit 1

# Downloaded copies (e.g. a ZIP from GitHub) carry macOS's quarantine flag and
# may have lost their executable bit. Clear both for this folder so install.js
# and the files it copies are not blocked silently. Harmless if already clean.
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x "$0" 2>/dev/null || true

pause_and_exit() {
  echo
  printf "Press any key to close."
  read -n 1 -s -r
  echo
  exit "$1"
}

# Enter = yes.
ask_yes() {
  local a
  printf "%s [Y/n]: " "$1"
  read -r a
  case "$a" in [nN]*) return 1 ;; *) return 0 ;; esac
}

# Enter = no.
ask_no() {
  local a
  printf "%s [y/N]: " "$1"
  read -r a
  case "$a" in [yYjJ]*) return 0 ;; *) return 1 ;; esac
}

node_arch() {
  case "$(uname -m)" in
    arm64)  echo "arm64" ;;
    x86_64) echo "x64" ;;
    *)      return 1 ;;
  esac
}

# Compatibility test: true if `node` (default: the one on PATH) is at least MIN_NODE.
node_ok() {
  local major cmd="${1:-node}"
  command -v "$cmd" >/dev/null 2>&1 || return 1
  major="$("$cmd" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || return 1
  [ -n "$major" ] && [ "$major" -ge "$MIN_NODE" ]
}

use_node_dir() { # puts a node folder first on PATH
  PATH="$1:$ORIG_PATH"; export PATH
  hash -r
}

# ---------------------------------------------------------------------------
# The shared Node folder
# ---------------------------------------------------------------------------

PRIVATE_TOO_OLD=""

# All copies in the shared Node folder (any version), one node binary per line.
private_nodes() {
  local n
  for n in "$NODE_HOME_DIR"/node-v*-darwin-*/bin/node; do
    [ -x "$n" ] && echo "$n"
  done
}

# Newest copy for this CPU; used if it passes the compatibility test,
# otherwise remembered in PRIVATE_TOO_OLD (update case).
find_private_node() {
  local arch newest
  arch="$(node_arch)" || return 1
  [ -d "$NODE_HOME_DIR" ] || return 1
  newest="$(cd "$NODE_HOME_DIR" && ls -d node-v*-darwin-"$arch" 2>/dev/null \
    | sort -t. -k1.7,1n -k2,2n -k3,3n | tail -1)"
  [ -n "$newest" ] && [ -x "$NODE_HOME_DIR/$newest/bin/node" ] || return 1
  if node_ok "$NODE_HOME_DIR/$newest/bin/node"; then
    use_node_dir "$NODE_HOME_DIR/$newest/bin"
    return 0
  fi
  PRIVATE_TOO_OLD="$("$NODE_HOME_DIR/$newest/bin/node" -v 2>/dev/null) at $NODE_HOME_DIR/$newest"
  return 1
}

# ---------------------------------------------------------------------------
# Other Node.js installs — only reported (and offered on a re-run), never changed
# ---------------------------------------------------------------------------

FOREIGN_CMD=()
FOREIGN_REAL=()
FOREIGN_VER=()
FOREIGN_OK=()

add_foreign() { # $1 = path of a node command
  local cmd="$1" real i
  [ -n "$cmd" ] && [ -x "$cmd" ] || return 0
  real="$("$cmd" -p 'process.execPath' 2>/dev/null)" || return 0
  case "$real" in "$NODE_HOME_DIR"/*) return 0 ;; esac
  for i in "${!FOREIGN_REAL[@]}"; do [ "${FOREIGN_REAL[$i]}" = "$real" ] && return 0; done
  FOREIGN_CMD+=("$cmd")
  FOREIGN_REAL+=("$real")
  FOREIGN_VER+=("$("$cmd" -v 2>/dev/null)")
  if node_ok "$cmd"; then FOREIGN_OK+=(1); else FOREIGN_OK+=(0); fi
}

collect_foreign_nodes() {
  local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  add_foreign "$(command -v node 2>/dev/null)"
  add_foreign /opt/homebrew/bin/node
  add_foreign /usr/local/bin/node
  if [ -s "$nvm_sh" ]; then
    # shellcheck disable=SC1090
    add_foreign "$( . "$nvm_sh" >/dev/null 2>&1; nvm which default 2>/dev/null )"
  fi
}

# Compatibility test "for our purpose" with one node binary:
#   1. version >= MIN_NODE
#   2. its npm runs (install.js needs npm)
#   3. this repo's installer tests pass with it
# Prints one line with the result.
compat_test() { # $1 = node command  $2 = its real path
  local cmd="$1" real="$2" cli label
  label="Node.js $("$cmd" -v 2>/dev/null) at $cmd"
  if ! node_ok "$cmd"; then
    echo "  Compatibility test: $label — too old (needs $MIN_NODE or newer)."
    return 1
  fi
  cli="$(dirname "$real")/../lib/node_modules/npm/bin/npm-cli.js"
  if [ -f "$cli" ]; then
    "$cmd" "$cli" -v >/dev/null 2>&1
  else
    PATH="$(dirname "$cmd"):$ORIG_PATH" npm -v >/dev/null 2>&1
  fi || { echo "  Compatibility test: $label — npm does not run."; return 1; }
  if ! "$cmd" --test installer/*.test.cjs >/dev/null 2>&1; then
    echo "  Compatibility test: $label — installer tests failed."
    return 1
  fi
  echo "  Compatibility test: $label — passed."
}

# Index of the newest installed Node.js that is >= MIN_NODE (not yet tested).
best_foreign() {
  local i best=""
  for i in "${!FOREIGN_CMD[@]}"; do
    [ "${FOREIGN_OK[$i]}" = 1 ] || continue
    if [ -z "$best" ] || version_lt "${FOREIGN_VER[$best]#v}" "${FOREIGN_VER[$i]#v}"; then best="$i"; fi
  done
  [ -n "$best" ] && echo "$best"
}

# Hint about installed Node.js versions that are not used. Nothing is changed.
report_unused_foreign() {
  local i current shown=0
  current="$(node -p 'process.execPath' 2>/dev/null)"
  for i in "${!FOREIGN_CMD[@]}"; do
    [ "${FOREIGN_REAL[$i]}" = "$current" ] && continue
    [ "$shown" -eq 0 ] && { echo "Note: other Node.js on this Mac (not used, left unchanged):"; shown=1; }
    if [ "${FOREIGN_OK[$i]}" = 1 ]; then
      echo "  ${FOREIGN_VER[$i]} at ${FOREIGN_CMD[$i]}"
    else
      echo "  ${FOREIGN_VER[$i]} at ${FOREIGN_CMD[$i]} (too old for this installer)"
    fi
  done
  [ "$shown" -eq 1 ] && echo
  return 0
}

# Downloads from nodejs.org (checksum-verified)
# ---------------------------------------------------------------------------

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

# Sets NODE_VERSION to the newest release of NODE_CHANNEL for this Mac.
resolve_node_version() { # $1=temp dir
  local arch
  arch="$(node_arch)" || { echo "Unsupported CPU architecture: $(uname -m)"; return 1; }
  case "$NODE_CHANNEL" in
    lts|current) ;;
    *) echo "MCP_NODE_CHANNEL must be 'lts' or 'current' (got: $NODE_CHANNEL)"; return 1 ;;
  esac
  if ! curl -fsSL --retry 2 -o "$1/index.tab" "$NODE_BASE_URL/index.tab"; then
    echo "Download of the release index failed: $NODE_BASE_URL/index.tab"
    return 1
  fi
  NODE_VERSION="$(pick_node_version "$1/index.tab" "$arch" "$NODE_CHANNEL")"
  if ! echo "$NODE_VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "No $NODE_CHANNEL release with a macOS ($arch) download found in the release index."
    return 1
  fi
  echo "Newest $NODE_CHANNEL release for macOS ($arch): $NODE_VERSION"
}

# Downloads one release file of NODE_VERSION into $1 and checks its SHA-256.
fetch_verified() { # $1=temp dir  $2=file name
  local dir_url="$NODE_BASE_URL/$NODE_VERSION" expected actual
  if [ ! -s "$1/SHASUMS256.txt" ] && ! curl -fsSL --retry 2 -o "$1/SHASUMS256.txt" "$dir_url/SHASUMS256.txt"; then
    echo "Download of the checksum list failed: $dir_url/SHASUMS256.txt"
    return 1
  fi
  # Format of each line: <64 hex chars><two spaces><file name>
  expected="$(awk -v f="$2" '$2 == f { print $1; exit }' "$1/SHASUMS256.txt")"
  if ! echo "$expected" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "No checksum for $2 found in the checksum list."
    return 1
  fi
  echo "Downloading $2 ..."
  if ! curl -fSL --retry 2 -o "$1/$2" "$dir_url/$2"; then
    echo "Download failed: $dir_url/$2"
    return 1
  fi
  actual="$(sha256_of "$1/$2")"
  if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
    echo "SHA-256 check FAILED for $2"
    echo "  expected: $expected"
    echo "  got:      ${actual:-<could not compute>}"
    echo "Nothing was installed."
    return 1
  fi
  echo "SHA-256 OK."
}

# Downloads Node.js into $NODE_HOME_DIR and puts it on PATH for this run.
bootstrap_node() {
  local tmp file stage dirname
  if [ "${MCP_NO_NODE_DOWNLOAD:-}" = "1" ]; then
    echo "Download disabled (MCP_NO_NODE_DOWNLOAD=1)."
    return 1
  fi
  echo "Downloading the newest $NODE_CHANNEL release from nodejs.org into"
  echo "  $NODE_HOME_DIR"
  echo "(no admin rights needed; set MCP_NO_NODE_DOWNLOAD=1 to skip this)"
  echo

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/mcp-node.XXXXXX")" || { echo "Could not create a temporary folder."; return 1; }
  resolve_node_version "$tmp" || { rm -rf "$tmp"; return 1; }
  file="node-$NODE_VERSION-darwin-$(node_arch).tar.gz"
  fetch_verified "$tmp" "$file" || { rm -rf "$tmp"; return 1; }

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

# ---------------------------------------------------------------------------
# Replacing and moving (Claude Desktop entries are re-pointed first)
# ---------------------------------------------------------------------------

# Major.minor.patch of a copy in the shared Node folder, e.g. 20.19.0.
private_version() { # $1=.../node-vX.Y.Z-darwin-<arch>/bin/node
  echo "$1" | sed -n 's#.*/node-v\([0-9]*\.[0-9]*\.[0-9]*\)-darwin-[^/]*/bin/node$#\1#p'
}

version_lt() { # $1 < $2 ?  (X.Y.Z)
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]
}

# Update case: deletes copies in the shared Node folder that are older than
# the one in use, without asking.
replace_older_private_nodes() {
  local current cur_ver n v olds=()
  current="$(node -p 'process.execPath')"
  cur_ver="$(private_version "$current")"
  [ -n "$cur_ver" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" != "$current" ] || continue
    v="$(private_version "$n")"
    [ -n "$v" ] && version_lt "$v" "$cur_ver" && olds+=("$n")
  done < <(private_nodes)
  [ "${#olds[@]}" -eq 0 ] && return 0

  if ! node installer/relink-node.cjs --to="$current" "${olds[@]}"; then
    echo "Older Node.js copies kept: Claude Desktop entries could not be re-pointed."
    return 1
  fi
  for n in "${olds[@]}"; do
    rm -rf "${n%/bin/node}" && echo "Replaced old Node.js v$(private_version "$n"): ${n%/bin/node}"
  done
  echo
}

# Moves to installed Node.js number $1 (already tested): asks (Enter = yes),
# re-points Claude Desktop entries, saves the choice, then offers to delete
# the copies in the shared Node folder (Enter = yes).
offer_move_to_foreign() {
  local i="$1" cmd="${FOREIGN_CMD[$1]}" ver="${FOREIGN_VER[$1]}" olds=() n
  ask_yes "Newer Node.js $ver found at $cmd. Use it from now on?" || { echo; return 1; }

  while IFS= read -r n; do [ -n "$n" ] && olds+=("$n"); done < <(private_nodes)
  [ -n "$CURRENT" ] && [ "$CURRENT" != "${FOREIGN_REAL[$i]}" ] && olds+=("$CURRENT")
  if ! "$cmd" installer/relink-node.cjs --to="$cmd" "${olds[@]}"; then
    echo "Not moved: Claude Desktop entries could not be re-pointed."
    echo
    return 1
  fi
  mkdir -p "$NODE_HOME_DIR" && echo "$cmd" > "$CHOICE_FILE"
  use_node_dir "$(dirname "$cmd")"
  CURRENT="${FOREIGN_REAL[$i]}"
  echo "Moved to $cmd (saved in $CHOICE_FILE; delete that file to go back)."

  olds=()
  while IFS= read -r n; do [ -n "$n" ] && olds+=("$n"); done < <(private_nodes)
  if [ "${#olds[@]}" -gt 0 ] && ask_yes "Delete the Node.js copies in $NODE_HOME_DIR?"; then
    for n in "${olds[@]}"; do rm -rf "${n%/bin/node}" && echo "Deleted ${n%/bin/node}"; done
  fi
  echo
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

collect_foreign_nodes
CURRENT=""          # real path of the node binary in use
BEST="$(best_foreign)"

# 1) Re-run: a Node.js chosen earlier instead of the shared Node folder.
if [ -f "$CHOICE_FILE" ]; then
  chosen="$(head -n 1 "$CHOICE_FILE")"
  if node_ok "$chosen"; then
    use_node_dir "$(dirname "$chosen")"
    CURRENT="$(node -p 'process.execPath')"
    echo "Using the Node.js chosen earlier: $chosen ($(node -v))"
    echo
  else
    echo "The Node.js chosen earlier ($chosen) is missing or too old for this installer;"
    echo "back to the shared Node folder."
    rm -f "$CHOICE_FILE"
    echo
  fi
fi

# 2) Re-run: the shared Node folder.
if [ -z "$CURRENT" ] && find_private_node; then
  CURRENT="$(node -p 'process.execPath')"
fi

if [ -n "$CURRENT" ]; then
  # Re-run: move to a newer installed Node.js if it passes the test.
  if [ -n "$BEST" ] && [ "${FOREIGN_REAL[$BEST]}" != "$CURRENT" ] \
     && version_lt "$(node -v | sed 's/^v//')" "${FOREIGN_VER[$BEST]#v}"; then
    echo "Checking the newer Node.js installed on this Mac:"
    compat_test "${FOREIGN_CMD[$BEST]}" "${FOREIGN_REAL[$BEST]}" && { echo; offer_move_to_foreign "$BEST"; } || echo
  fi
else
  if [ -n "$PRIVATE_TOO_OLD" ]; then
    # Update case (re-run): our copy is too old.
    echo "Node.js in the shared Node folder is too old for this installer (needs $MIN_NODE or newer):"
    echo "  $PRIVATE_TOO_OLD"
    echo
    if [ -n "$BEST" ]; then
      echo "Checking the Node.js installed on this Mac:"
      compat_test "${FOREIGN_CMD[$BEST]}" "${FOREIGN_REAL[$BEST]}" && { echo; offer_move_to_foreign "$BEST"; } || echo
    fi
    [ -z "$CURRENT" ] && { echo "Updating to the newest Node.js; the old copy is replaced."; echo; }
  else
    # Fresh install: use an installed Node.js if it passes the test.
    echo "No Node.js in the shared Node folder yet."
    if [ -n "$BEST" ]; then
      echo "Checking the Node.js installed on this Mac:"
      if compat_test "${FOREIGN_CMD[$BEST]}" "${FOREIGN_REAL[$BEST]}"; then
        use_node_dir "$(dirname "${FOREIGN_CMD[$BEST]}")"
        CURRENT="${FOREIGN_REAL[$BEST]}"
      fi
    elif [ "${#FOREIGN_CMD[@]}" -gt 0 ]; then
      echo "The Node.js installed on this Mac is too old for this installer (needs $MIN_NODE or newer)."
    fi
    [ -z "$CURRENT" ] && echo "Installing Node.js $MIN_NODE+ into the shared Node folder."
    echo
  fi

  if [ -z "$CURRENT" ]; then
    if ! bootstrap_node || ! node_ok; then
      echo
      echo "Could not set up Node.js $MIN_NODE or newer automatically."
      echo "Install it from https://nodejs.org and run this file again."
      pause_and_exit 1
    fi
    CURRENT="$(node -p 'process.execPath')"
  fi
fi

replace_older_private_nodes
report_unused_foreign

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
