#!/bin/bash
# Dev verification script (NOT part of the customer README / example sources).
# Runs the full ship-readiness gate: SDK unit tests + resilience matrix, then
# builds all 14 example apps.
#
# Usage: scripts/verify.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DEST='platform=iOS Simulator,name=iPhone 17 Pro'
FAIL=0

echo "==> 1/2  swift test (SDK unit tests + resilience matrix)"
if swift test 2>&1 | tail -3 | grep -q "0 failures"; then
  echo "    PASS: swift test green"
else
  echo "    FAIL: swift test"; FAIL=1
fi

echo "==> 2/2  build all 14 example apps"
if ./scripts/build-all.sh 2>&1 | tail -1 | grep -q "0 failed"; then
  echo "    PASS: 14/14 built"
else
  echo "    FAIL: example build"; FAIL=1
fi

echo "================================"
[ "$FAIL" -eq 0 ] && echo "VERIFY: ALL GREEN" || echo "VERIFY: FAILURES ABOVE"
exit $FAIL
