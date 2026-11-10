#!/bin/bash
# Turns compiler errors / failed tests in an xcodebuild log into GitHub annotations,
# so failures are readable from the public check-run API.
LOG="$1"
[ -f "$LOG" ] || { echo "::error::log $LOG not found"; exit 0; }

LINES=$(grep -E "error:|: error|Test Case .* failed|XCTAssert|failed \(|Fatal error|\*\* (BUILD|TEST) FAILED" "$LOG" \
  | sed -E 's#^/Users/runner/work/[^/]+/[^/]+/##' | awk '!seen[$0]++' | head -60)
if [ -z "$LINES" ]; then
  LINES=$(tail -40 "$LOG")
fi

chunk=""
count=0
while IFS= read -r line; do
  line=$(printf '%s' "$line" | cut -c1-400 | sed 's/%/%25/g')
  if [ ${#chunk} -gt 2500 ]; then
    echo "::error::${chunk}"
    chunk=""
    count=$((count + 1))
    [ $count -ge 8 ] && break
  fi
  chunk="${chunk}${line}%0A"
done <<< "$LINES"
[ -n "$chunk" ] && [ $count -lt 8 ] && echo "::error::${chunk}"
exit 0
