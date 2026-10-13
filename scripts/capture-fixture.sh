#!/usr/bin/env bash
# Copies a live transcript (and subagents) into Tests/Fixtures/transcripts/<name>/ after scrubbing.
# Usage: capture-fixture.sh <session-id> <fixture-name>
set -euo pipefail
SESSION="$1"; NAME="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SRC=$(find "$CLAUDE_DIR/projects" -maxdepth 2 -name "$SESSION.jsonl" | head -1)
[ -n "$SRC" ] || { echo "no transcript for $SESSION"; exit 1; }
DEST="$ROOT/Tests/Fixtures/transcripts/$NAME"
mkdir -p "$DEST"
swift "$ROOT/scripts/scrub-transcript.swift" "$SRC" "$DEST/session.jsonl"
if [ -d "${SRC%.jsonl}/subagents" ]; then
  mkdir -p "$DEST/subagents"
  for f in "${SRC%.jsonl}"/subagents/*.jsonl; do
    swift "$ROOT/scripts/scrub-transcript.swift" "$f" "$DEST/subagents/$(basename "$f")"
  done
  cp "${SRC%.jsonl}"/subagents/*.meta.json "$DEST/subagents/" 2>/dev/null || true
fi
VERSION=$(grep -o '"version":"[^"]*"' "$SRC" | head -1 | cut -d'"' -f4)
cat > "$DEST/README.md" <<MD
# $NAME

Captured from Claude Code $VERSION on $(date -u +%Y-%m-%d). Scrubbed with scripts/scrub-transcript.swift.

Exercises: (fill in)
MD
echo "✓ $DEST"
