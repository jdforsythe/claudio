#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from Resources/AppIcon-1024.png (rendering the PNG first if it is missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/Resources/AppIcon-1024.png}"
OUT="${2:-$ROOT/Resources/AppIcon.icns}"
if [ ! -f "$SRC" ]; then
  swift "$ROOT/scripts/render-icon.swift" "$SRC"
fi
TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$TMP"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$TMP/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$SRC" --out "$TMP/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP" -o "$OUT"
echo "✓ $OUT"
