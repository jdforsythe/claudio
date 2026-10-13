#!/usr/bin/env bash
# Lists fixture capture versions next to the installed Claude Code version.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLED=$(claude --version 2>/dev/null | awk '{print $1}' || echo unknown)
echo "installed Claude Code: $INSTALLED"
for d in "$ROOT"/Tests/Fixtures/transcripts/*/; do
  v=$(grep -o 'Claude Code [0-9.]*' "$d/README.md" 2>/dev/null | head -1 || echo "unknown")
  echo "  $(basename "$d"): $v"
done
echo "Re-capture single-turn-final-answer and narration-then-tool-then-answer when the installed version is two or more minor versions newer."
