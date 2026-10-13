#!/usr/bin/env bash
set -euo pipefail
APP="$1"; PROFILE="$2"
ZIP="${APP%.app}-notary.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
echo "✓ notarized and stapled: $APP"
