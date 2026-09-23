#!/bin/zsh
# Build Wade and assemble a signed build/Wade.app.
#
# Why a bundle: macOS grants Accessibility per signed app identity, not per bare binary.
#
# Signing: uses $WADE_SIGN_IDENTITY if set (e.g. "Apple Development: …"), else ad-hoc.
# Either way the designated requirement is pinned to the bundle identifier, so an
# Accessibility grant survives rebuilds instead of needing re-approval every time.
#
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${1:-debug}
BUNDLE_ID=com.ricardo.wade
APP=build/Wade.app

swift build -c "$CONFIG" --product Wade
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Wade" "$APP/Contents/MacOS/Wade"
cp Bundle/Info.plist "$APP/Contents/Info.plist"

codesign --force \
  --sign "${WADE_SIGN_IDENTITY:--}" \
  --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP"

echo "Built $APP ($CONFIG, signed with ${WADE_SIGN_IDENTITY:-ad-hoc})"
