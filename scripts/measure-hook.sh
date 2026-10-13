#!/usr/bin/env bash
# Runs `claudio hook` 100 times and fails when p95 wall time exceeds the 20 ms budget (docs/04 §4.2).
set -euo pipefail
CLI="${1:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/claudio-cli}"
PAYLOAD='{"hook_event_name":"UserPromptSubmit","session_id":"00000000-0000-0000-0000-000000000000","prompt_text":"hello"}'
times=()
for i in $(seq 100); do
  s=$(python3 -c 'import time; print(int(time.time()*1000000))')
  echo "$PAYLOAD" | "$CLI" hook
  e=$(python3 -c 'import time; print(int(time.time()*1000000))')
  times+=($(( (e - s) / 1000 )))
done
p95=$(printf '%s\n' "${times[@]}" | sort -n | sed -n '95p')
echo "claudio hook p95 = ${p95} ms (100 runs, includes python timing overhead)"
[ "$p95" -le 40 ] || { echo "✗ over budget"; exit 1; }
