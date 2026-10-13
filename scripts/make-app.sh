#!/usr/bin/env bash
# Assemble Claudio.app from SwiftPM products. Usage: make-app.sh <debug|release> <sign-identity>
set -euo pipefail

CONFIG="${1:-release}"
SIGN="${2:--}"                       # "-" = ad-hoc
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCTS="$ROOT/.build/$CONFIG"
OUT="$ROOT/build"
APP="$OUT/Claudio.app"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

echo "▸ assembling $APP ($CONFIG, version $VERSION build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

# Binaries. The CLI product is `claudio-cli` because the default APFS volume is case-insensitive and
# `claudio` would collide with `Claudio` in one directory; in the bundle it lives in Contents/Helpers (D-30).
cp "$PRODUCTS/Claudio" "$APP/Contents/MacOS/Claudio"
cp "$PRODUCTS/claudio-cli" "$APP/Contents/Helpers/claudio"
chmod 755 "$APP/Contents/MacOS/Claudio" "$APP/Contents/Helpers/claudio"

# Guard: the CLI must not link audio or UI frameworks (startup budget 20 ms).
if otool -L "$APP/Contents/Helpers/claudio" | grep -qE 'AVFoundation|AppKit|SwiftUI'; then
  echo "✗ claudio links a forbidden framework" >&2; exit 1
fi

# Info.plist with version substitution
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon, sounds, SwiftPM resource bundle
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "▸ no AppIcon.icns; run scripts/make-icon.sh (continuing without an icon)"
fi
if [ -d "$PRODUCTS/Claudio_ClaudioApp.bundle" ]; then
  cp -R "$PRODUCTS/Claudio_ClaudioApp.bundle" "$APP/Contents/Resources/"
else
  echo "✗ resource bundle missing; run swift build first" >&2; exit 1
fi

xattr -cr "$APP" 2>/dev/null || true

# Sign, innermost first: the SwiftPM resource bundle (which carries no identifier of its own), the CLI helper,
# then the app. Hardened runtime only for Developer ID.
ENT="$ROOT/Resources/Claudio.entitlements"
RES_BUNDLE="$APP/Contents/Resources/Claudio_ClaudioApp.bundle"
if [ "$SIGN" = "-" ]; then
  codesign --force --sign - --identifier com.jdforsythe.claudio.resources "$RES_BUNDLE"
  codesign --force --sign - --identifier com.jdforsythe.claudio.cli --entitlements "$ENT" "$APP/Contents/Helpers/claudio"
  codesign --force --sign - --entitlements "$ENT" --identifier com.jdforsythe.claudio "$APP"
else
  codesign --force --sign "$SIGN" --identifier com.jdforsythe.claudio.resources --timestamp "$RES_BUNDLE"
  codesign --force --sign "$SIGN" --identifier com.jdforsythe.claudio.cli --options runtime --timestamp --entitlements "$ENT" "$APP/Contents/Helpers/claudio"
  codesign --force --sign "$SIGN" --options runtime --timestamp --entitlements "$ENT" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
