#!/bin/zsh
# Build Wade and assemble a signed build/Wade.app.
#
# Why a bundle: macOS grants Accessibility per signed app identity, not per bare binary.
# The grant is tied to the app's "designated requirement" (DR): a rule every future build
# must satisfy to keep the permission.
#
# Signing, in order of preference:
#   1. $WADE_SIGN_IDENTITY, if set.
#   2. The first "Apple Development" certificate in the keychain. The DR then says "bundle id
#      com.ricardo.wade, signed by this developer's certificate": stable across rebuilds
#      and can't be claimed by anything you didn't sign.
#   3. Ad-hoc (no certificate). An ad-hoc DR is normally the binary's hash, which changes on
#      every build and would re-prompt for Accessibility each time. So we pin the DR to
#      the bundle id only. That survives rebuilds, but any locally built app claiming this id
#      would inherit Wade's Accessibility grant. Fine for bootstrapping, not for daily use.
#
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${1:-debug}
BUNDLE_ID=com.ricardo.wade
APP=build/Wade.app

IDENTITY=${WADE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}

swift build -c "$CONFIG" --product Wade
BIN_DIR=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Wade" "$APP/Contents/MacOS/Wade"
cp Bundle/Info.plist "$APP/Contents/Info.plist"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
  echo "Built $APP ($CONFIG), signed by: $IDENTITY"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "Built $APP ($CONFIG), ad-hoc signed (no Apple Development certificate found; see header)"
fi
codesign -dr - "$APP" 2>&1 | grep designated
