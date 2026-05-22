#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
DEST='platform=iOS Simulator,name=iPhone 17 Pro'
PASS=0; FAIL=0; FAILED=""
for entry in "$@"; do
  d="${entry%%:*}"; N="${entry##*:}"
  ( cd "$d" && xcodegen generate >/dev/null 2>&1 )
  sleep 25  # ease live-backend session-creation throttling between suites
  echo "===== UITEST $N ====="
  if xcodebuild test -project "$d/$N.xcodeproj" -scheme "$N" -destination "$DEST" \
       -derivedDataPath ".build/dd-$N-ui" 2>&1 | grep -qE "TEST SUCCEEDED"; then
    echo "$N: UITEST PASSED"; PASS=$((PASS+1))
  else
    echo "$N: UITEST FAILED"; FAIL=$((FAIL+1)); FAILED="$FAILED $N"
  fi
done
echo "================================"
echo "UITEST SUMMARY: $PASS passed, $FAIL failed.${FAILED:+ Failed:$FAILED}"
