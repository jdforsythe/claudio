# Fixtures

- `transcripts/<name>/session.jsonl` — scrubbed real transcripts (`scripts/capture-fixture.sh <session-id> <name>`), plus `subagents/`.
- `hooks/<Event>.json` — one hook payload per installed event, shaped like Claude Code 2.1.x output.
- `settings/` — `~/.claude/settings.json` shapes for `HookInstaller` tests.
- `markdown/*.md` + `*.expected.txt` — renderer golden corpus (`kind|text` per segment).

Every transcript fixture README records the Claude Code version it was captured from (docs/09 §2).
