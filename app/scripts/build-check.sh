#!/bin/zsh
# Build wade-exec-check and sign it with a stable identity (the Apple Development certificate
# when present), so a Keychain "Always Allow" for the Gemini/GitHub keys survives rebuilds.
set -euo pipefail
cd "${0:A:h}/.."
swift build --product wade-exec-check
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.ricardo.wade.exec-check --timestamp=none .build/debug/wade-exec-check
else
  codesign --force --sign - --identifier com.ricardo.wade.exec-check \
    --requirements '=designated => identifier "com.ricardo.wade.exec-check"' .build/debug/wade-exec-check
fi
codesign -dr - .build/debug/wade-exec-check 2>&1 | grep designated
