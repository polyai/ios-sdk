#!/bin/bash
# Build all 14 example apps. Regenerates each xcodeproj with xcodegen, then xcodebuild for the simulator.
set -uo pipefail
cd "$(dirname "$0")/.."
DEST='platform=iOS Simulator,name=iPhone 17 Pro'
LOGDIR="build-logs"
mkdir -p "$LOGDIR"
declare -a APPS=(
  "SwiftUI/01-Hello:HelloSwiftUI"
  "SwiftUI/02-Standard:StandardSwiftUI"
  "SwiftUI/03-RichContent:RichContentSwiftUI"
  "SwiftUI/04-Resilience:ResilienceSwiftUI"
  "SwiftUI/05-Handoff:HandoffSwiftUI"
  "SwiftUI/06-FullReference:FullReferenceSwiftUI"
  "SwiftUI/07-Playground:PlaygroundSwiftUI"
  "UIKit/01-Hello:HelloUIKit"
  "UIKit/02-Standard:StandardUIKit"
  "UIKit/03-RichContent:RichContentUIKit"
  "UIKit/04-Resilience:ResilienceUIKit"
  "UIKit/05-Handoff:HandoffUIKit"
  "UIKit/06-FullReference:FullReferenceUIKit"
  "UIKit/07-Playground:PlaygroundUIKit"
)
PASS=0; FAIL=0; FAILED_APPS=""
for entry in "${APPS[@]}"; do
  dir="Examples/${entry%%:*}"
  scheme="${entry##*:}"
  log="$LOGDIR/${scheme}.log"
  echo "===== BUILDING $scheme ($dir) ====="
  ( cd "$dir" && xcodegen generate ) >"$log" 2>&1
  xcodebuild -project "$dir/$scheme.xcodeproj" -scheme "$scheme" -destination "$DEST" -derivedDataPath ".build/dd-$scheme" build >>"$log" 2>&1
  if grep -q "BUILD SUCCEEDED" "$log"; then
    echo "$scheme: BUILD SUCCEEDED"
    PASS=$((PASS+1))
  else
    echo "$scheme: BUILD FAILED (see $log)"
    FAIL=$((FAIL+1)); FAILED_APPS="$FAILED_APPS $scheme"
  fi
done
echo "================================"
echo "SUMMARY: $PASS succeeded, $FAIL failed.${FAILED_APPS:+ Failed:$FAILED_APPS}"
