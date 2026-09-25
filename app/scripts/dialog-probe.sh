#!/bin/zsh
# Drive the dialog probe (see dialog-probe.swift). Watch the backend log while it runs:
# expect exactly two error_dialog events from com.wade.dialog-probe with equal signatures.
#
#   scripts/dialog-probe.sh            # the two alerts only
#   scripts/dialog-probe.sh --refocus  # also switch to Finder and back while alert A is open,
#                                      # to check a refocused dialog isn't counted twice (Phase 2)
set -euo pipefail
cd "${0:A:h}/.."

PROBE=build/DialogProbe.app
mkdir -p "$PROBE/Contents/MacOS"
swiftc -O -o "$PROBE/Contents/MacOS/DialogProbe" scripts/dialog-probe.swift
cat > "$PROBE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.wade.dialog-probe</string>
  <key>CFBundleExecutable</key><string>DialogProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$PROBE" 2>/dev/null

open -W "$PROBE" &
WAIT=$!
if [[ "${1:-}" == "--refocus" ]]; then
  sleep 2; open -a Finder
  sleep 1.5; open "$PROBE"   # back to the same, still-open alert
fi
wait $WAIT
echo "dialog probe finished"
