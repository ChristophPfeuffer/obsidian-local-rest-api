#!/bin/bash
# Scenario test for the Node.js selection / update logic in installMAC.command.
#
#   bash installer/test-launcher-mac.sh            all cases
#   bash installer/test-launcher-mac.sh update     only cases whose name contains "update"
#   bash installer/test-launcher-mac.sh --list     list the case names
#   VERBOSE=1 bash installer/test-launcher-mac.sh  also show the launcher output
#
# Runs the launcher in a throw-away HOME with fake Node.js binaries (small
# scripts that report a chosen version and forward everything else to your
# real node). Downloads are stubbed, install.js is not run, and Homebrew/nvm on
# this machine are ignored — nothing outside the temp folder is touched.
# Needs bash and a node (20+) on PATH. Works on macOS and Linux.
#
# Kept IDENTICAL in MCP-Zotero and obsidian-local-rest-api (under installer/).

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$REPO/installMAC.command"
# A real node to run the fakes with: PATH, else the newest in the shared Node folder.
REAL_NODE="$(command -v node 2>/dev/null)"
if [ -z "$REAL_NODE" ]; then
  REAL_NODE="$(ls -d "$HOME/Library/Application Support/node"/node-v*/bin/node 2>/dev/null | sort -t. -k1.7,1n | tail -1)"
fi
[ -x "$REAL_NODE" ] || { echo "No node found (PATH or ~/Library/Application Support/node)."; exit 1; }
FILTER="$1"
MIN="$(sed -n 's/^MIN_NODE=\([0-9]*\)$/\1/p' "$LAUNCHER")"
OLD="$((MIN - 2)).0.0"   # too old
OK="$MIN.1.0"            # new enough
NEW="$((MIN + 4)).2.0"   # newer than OK
DL="99.0.0"              # what the stubbed download "installs"

PASS=0
FAIL=0
RAN=0
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launcher-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# The launcher runs with PATH=$SYSBIN only: the usual system tools, but no
# node/npm — the same on macOS and Linux, whatever is installed here.
SYSBIN="$ROOT/sysbin"
mkdir -p "$SYSBIN"
for t in bash sh env sed awk grep sort head tail cat cut tr mkdir chmod rm mv cp ls \
         dirname basename mktemp uname date sleep xattr; do
  p="$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v "$t" 2>/dev/null)" && ln -s "$p" "$SYSBIN/$t"
done

# Fake node: `mk_node <path> <version> [failtests|nonpm]`
# Next to it goes a fake npm (like a real install has), unless "nonpm".
# `--test` (the launcher's installer-test step) just passes, or fails with
# "failtests" — the installer tests themselves are run by `npm run test:installer`.
mk_node() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/bin/bash
case "\$1" in
  -v) echo v$2 ;;
  -p) case "\$2" in
        *versions*) echo ${2%%.*} ;;
        *execPath*) echo "\$0" ;;
        *) exec "$REAL_NODE" "\$@" ;;
      esac ;;
  --test) [ "$3" = failtests ] && exit 1; exit 0 ;;
  *) exec "$REAL_NODE" "\$@" ;;
esac
EOF
  chmod +x "$1"
  if [ "$3" != nonpm ]; then
    printf '#!/bin/bash\necho 10.0.0\n' > "$(dirname "$1")/npm"
    chmod +x "$(dirname "$1")/npm"
  fi
}

# New sandbox: sets T, N (shared Node folder), F (foreign node), CFG.
setup() {
  T="$(mktemp -d "$ROOT/case.XXXXXX")"
  N="$T/home/Library/Application Support/node"
  F="$T/other/bin/node"
  CFG="$T/home/.config/Claude/claude_desktop_config.json"
  [ "$(uname)" = Darwin ] && CFG="$T/home/Library/Application Support/Claude/claude_desktop_config.json"
  mkdir -p "$T/repo/installer" "$(dirname "$CFG")"
  cp "$REPO"/installer/*.cjs "$T/repo/installer/"
  cp "$REPO"/package.json "$T/repo/"
  [ -f "$REPO/install.js" ] && cp "$REPO/install.js" "$T/repo/"
  FOREIGN=""
}
private() { mk_node "$N/node-v$1-darwin-x64/bin/node" "$1"; }
foreign() { mk_node "$F" "$1" "$2"; FOREIGN="$F"; }
claude_on() { echo "{\"mcpServers\":{\"zotero\":{\"command\":\"$1\",\"args\":[\"/x/index.js\"]}}}" > "$CFG"; }

# Runs the launcher; $1 = typed answers (e.g. "\n\n" = Enter, Enter).
run() {
  # Test doubles, inserted just before the launcher's main part.
  {
    declare -f mk_node
    echo "REAL_NODE='$REAL_NODE'"
    echo "node_arch() { echo x64; }"
    echo "collect_foreign_nodes() { [ -n '$FOREIGN' ] && add_foreign '$FOREIGN'; }"
    echo "bootstrap_node() {"
    echo "  echo 'STUB_DOWNLOAD v$DL'"
    echo "  mk_node \"\$NODE_HOME_DIR/node-v$DL-darwin-x64/bin/node\" $DL"
    echo "  use_node_dir \"\$NODE_HOME_DIR/node-v$DL-darwin-x64/bin\""
    echo "}"
  } > "$T/doubles.sh"
  sed -e 's/^  read -n 1 -s -r$/  :/' \
      -e 's/^node install.js "\$@"$/echo "INSTALL_JS_WITH $(node -v)"/' "$LAUNCHER" \
    | awk -v f="$T/doubles.sh" '/^# Main$/ { while ((getline l < f) > 0) print l } { print }' \
    > "$T/repo/installMAC.command"
  OUT="$(printf "$1" | HOME="$T/home" PATH="$SYSBIN" bash "$T/repo/installMAC.command" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
}

# --- assertions -------------------------------------------------------------
CASE=""
ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL [$CASE] $1"; }
uses()       { echo "$OUT" | grep -q "^INSTALL_JS_WITH v$1$" && ok || bad "should run install.js with v$1"; }
says()       { echo "$OUT" | grep -qF -- "$1" && ok || bad "output should contain: $1"; }
not_says()   { echo "$OUT" | grep -qF -- "$1" && bad "output should not contain: $1" || ok; }
has_private(){ [ -d "$N/node-v$1-darwin-x64" ] && ok || bad "shared folder should have v$1"; }
no_private() { [ ! -d "$N/node-v$1-darwin-x64" ] && ok || bad "shared folder should not have v$1"; }
choice_is()  { [ "$(cat "$N/use-node" 2>/dev/null)" = "$1" ] && ok || bad "use-node should be '$1' (is '$(cat "$N/use-node" 2>/dev/null)')"; }
claude_is()  { "$REAL_NODE" -e 'const c=require(process.argv[1]);process.exit(c.mcpServers.zotero.command===process.argv[2]?0:1)' "$CFG" "$1" && ok || bad "Claude entry should use $1"; }
# Starts a case unless it is filtered out (or only listed with --list).
start() {
  CASE="$1"
  if [ "$FILTER" = --list ]; then echo "  $CASE"; return 1; fi
  case "$CASE" in *"$FILTER"*) ;; *) return 1 ;; esac
  RAN=$((RAN + 1)); setup
}
finish() { [ -n "$VERBOSE" ] && { echo "----- $CASE"; echo "$OUT"; }; }

# --- fresh install ----------------------------------------------------------
if start "fresh: installed Node passes the test -> used"; then
foreign "$OK"; run ""
uses "$OK"; says "passed."; no_private "$DL"; choice_is ""; finish; fi

if start "fresh: installed Node too old -> download"; then
foreign "$OLD"; run ""
uses "$DL"; says "too old for this installer"; has_private "$DL"; finish; fi

if start "fresh: installed Node fails the installer tests -> download"; then
foreign "$OK" failtests; run ""
uses "$DL"; says "installer tests failed"; has_private "$DL"; finish; fi

if start "fresh: installed Node without npm -> download"; then
foreign "$OK" nonpm; run ""
uses "$DL"; says "npm does not run"; has_private "$DL"; finish; fi

if start "fresh: no Node at all -> download"; then
run ""
uses "$DL"; says "No Node.js in the shared Node folder yet."; has_private "$DL"; finish; fi

# --- re-run -----------------------------------------------------------------
if start "re-run: our copy, installed Node older -> no question"; then
private "$OK"; foreign "$((MIN + 0)).0.1"; run ""
uses "$OK"; not_says "Use it from now on?"; says "not used, left unchanged"; finish; fi

if start "re-run: newer installed Node, answer n -> stay"; then
private "$OK"; foreign "$NEW"; claude_on "$N/node-v$OK-darwin-x64/bin/node"; run "n\n"
uses "$OK"; says "Use it from now on?"; has_private "$OK"; choice_is ""; claude_is "$N/node-v$OK-darwin-x64/bin/node"; finish; fi

if start "re-run: newer installed Node, Enter + Enter -> move, delete our copy"; then
private "$OK"; foreign "$NEW"; claude_on "$N/node-v$OK-darwin-x64/bin/node"; run "\n\n"
uses "$NEW"; choice_is "$F"; no_private "$OK"; claude_is "$F"; finish; fi

if start "re-run: newer installed Node, Enter + n -> move, keep our copy"; then
private "$OK"; foreign "$NEW"; run "\nn\n"
uses "$NEW"; choice_is "$F"; has_private "$OK"; finish; fi

if start "re-run: newer installed Node fails the tests -> no question"; then
private "$OK"; foreign "$NEW" failtests; run ""
uses "$OK"; says "installer tests failed"; not_says "Use it from now on?"; finish; fi

if start "re-run: saved choice still fine -> used"; then
private "$OK"; foreign "$NEW"; mkdir -p "$N"; echo "$F" > "$N/use-node"; run ""
uses "$NEW"; says "Using the Node.js chosen earlier"; finish; fi

if start "re-run: saved choice now too old -> back to shared folder"; then
private "$OK"; foreign "$OLD"; mkdir -p "$N"; echo "$F" > "$N/use-node"; run ""
uses "$OK"; says "back to the shared Node folder"; choice_is ""; finish; fi

# --- update case (our copy too old) -----------------------------------------
if start "update: no usable installed Node -> download, old copy replaced, Claude re-pointed"; then
private "$OLD"; claude_on "$N/node-v$OLD-darwin-x64/bin/node"; run ""
uses "$DL"; says "too old for this installer"; no_private "$OLD"; has_private "$DL"
claude_is "$N/node-v$DL-darwin-x64/bin/node"; finish; fi

if start "update: installed Node passes, Enter + Enter -> move, old copy deleted"; then
private "$OLD"; foreign "$OK"; claude_on "$N/node-v$OLD-darwin-x64/bin/node"; run "\n\n"
uses "$OK"; choice_is "$F"; no_private "$OLD"; no_private "$DL"; claude_is "$F"; finish; fi

if start "update: installed Node passes, answer n -> download instead"; then
private "$OLD"; foreign "$OK"; run "n\n"
uses "$DL"; choice_is ""; no_private "$OLD"; finish; fi

if start "update: Claude config unreadable -> old copy NOT deleted"; then
private "$OLD"; echo "{ broken" > "$CFG"; run ""
uses "$DL"; has_private "$OLD"; says "could not be re-pointed"; finish; fi

# --- result -----------------------------------------------------------------
[ "$FILTER" = --list ] && exit 0
[ "$RAN" -eq 0 ] && { echo "No case matches \"$FILTER\" (see --list)."; exit 1; }
echo
echo "Launcher scenarios (MIN_NODE=$MIN, real node $("$REAL_NODE" -v)): $RAN cases, $PASS checks passed, $FAIL failed."
echo "(VERBOSE=1 shows the launcher output of every case.)"
[ "$FAIL" -eq 0 ]
