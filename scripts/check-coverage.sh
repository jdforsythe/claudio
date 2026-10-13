#!/usr/bin/env bash
# Prints per-target line coverage and fails when a target is below its threshold (docs/09 §8).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build
PROFDATA="$(swift test --show-codecov-path | xargs dirname)/default.profdata"
BIN=$(find .build/debug -name 'ClaudioPackageTests' -path '*/MacOS/*' | head -1)
xcrun llvm-cov report "$BIN" -instr-profile "$PROFDATA" -ignore-filename-regex='Tests/|\.build/|Vendor/' > build/coverage.txt
cat build/coverage.txt
declare -A MIN=( [ClaudioControlProtocol]=80 [ClaudioCore]=70 [ClaudioBackends]=50 )
status=0
for target in "${!MIN[@]}"; do
  pct=$(grep "Sources/$target/" build/coverage.txt | awk '{ lines+=$8; missed+=$9 } END { if (lines>0) printf "%d", (lines-missed)*100/lines; else print 0 }')
  if [ "$pct" -lt "${MIN[$target]}" ]; then echo "✗ $target coverage $pct% < ${MIN[$target]}%"; status=1; else echo "✓ $target coverage $pct%"; fi
done
exit $status
