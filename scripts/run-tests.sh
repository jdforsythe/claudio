#!/usr/bin/env bash
# Runs the suite with `swift test` when XCTest is available (Xcode), else via the shim runner (docs/13 D-32).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLAUDIO_BUILT_PRODUCTS="$ROOT/.build/debug"
if [ "${CLAUDIO_XCTEST:-}" = "1" ] || { [ "${CLAUDIO_XCTEST:-}" != "0" ] && [ -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework ]; }; then
  swift test --parallel "$@"
else
  python3 scripts/gen-test-registry.py
  swift run claudio-tests "$@"
fi
