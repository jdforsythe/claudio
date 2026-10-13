#!/usr/bin/env bash
# Builds a drag-to-Applications DMG from build/Claudio.app using only hdiutil. Usage: make-dmg.sh [out.dmg]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Claudio.app"
VERSION="$(cat "$ROOT/VERSION")"
OUT="${1:-$ROOT/build/Claudio-$VERSION.dmg}"
[ -d "$APP" ] || { echo "✗ $APP missing; run make app first" >&2; exit 1; }
STAGE="$(mktemp -d)/Claudio"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Claudio.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install.txt" <<TXT
Drag Claudio.app onto the Applications folder, then open it from Applications.

Claudio is not yet notarized by Apple. On first launch macOS will say it cannot verify the app:
click Done, open System Settings → Privacy & Security, scroll down and click "Open Anyway".
(Terminal alternative: xattr -dr com.apple.quarantine /Applications/Claudio.app)
TXT
rm -f "$OUT"
hdiutil create -volname "Claudio $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
rm -rf "$(dirname "$STAGE")"
if [ "${SIGN_IDENTITY:--}" != "-" ]; then codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT"; fi
echo "✓ $OUT"
