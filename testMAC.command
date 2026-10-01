#!/bin/bash

# Double-click: tests the Node.js selection / update logic of installMAC.command
# (installer/test-launcher-mac.sh). Changes nothing on this Mac — everything
# runs in a temporary folder that is deleted afterwards.

cd "$(dirname "$0")" || exit 1
xattr -dr com.apple.quarantine . 2>/dev/null || true
chmod +x "$0" 2>/dev/null || true

echo "Tests for the Node.js update in installMAC.command"
echo
echo "  Enter    run all cases"
echo "  l        list the cases"
echo "  <text>   run only cases whose name contains <text> (e.g. update:)"
echo "  v        all cases, with the installer window output of each"
echo
printf "Choice: "
read -r choice
echo

case "$choice" in
  "")  bash installer/test-launcher-mac.sh ;;
  l|L) bash installer/test-launcher-mac.sh --list ;;
  v|V) VERBOSE=1 bash installer/test-launcher-mac.sh ;;
  *)   bash installer/test-launcher-mac.sh "$choice" ;;
esac
status=$?

echo
if [ "$status" -eq 0 ]; then echo "All good."; else echo "Something failed (see above)."; fi
echo
printf "Press any key to close."
read -n 1 -s -r
echo
exit "$status"
