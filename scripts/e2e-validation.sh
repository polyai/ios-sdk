#!/usr/bin/env bash
# e2e-validation.sh — Deep end-to-end validation of the PolyMessaging iOS SDK
# example ladder.
#
#   1. Builds & screenshots all 7 SwiftUI examples (01-Hello through 07-Playground)
#   2. Runs the StandardSwiftUI XCUITest target (live E2E against dev backend)
#   3. Drops everything into /tmp/poly-e2e/ + prints a pass/fail summary.
#
# The dev connector token MUST be provided via POLY_CONNECTOR_TOKEN env var —
# never hard-coded (see AGENTS.md "Never log the connector token").
#
# Usage:
#   POLY_CONNECTOR_TOKEN=xxx scripts/e2e-validation.sh
#
# Requires:
#   - Xcode + an iOS simulator booted (auto-boots one if none)
#   - xcodegen (brew install xcodegen)
set -uo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="/tmp/poly-e2e"
SIM_NAME="iPhone 17 Pro Max"
DEST="platform=iOS Simulator,name=${SIM_NAME}"

SWIFTUI_EXAMPLES=(
  "01-Hello:HelloSwiftUI:HelloApp.swift"
  "02-Standard:StandardSwiftUI:App/StandardApp.swift"
  "03-RichContent:RichContentSwiftUI:App/RichContentApp.swift"
  "04-Resilience:ResilienceSwiftUI:App/ResilienceApp.swift"
  "05-Handoff:HandoffSwiftUI:App/HandoffApp.swift"
  "06-FullReference:FullReferenceSwiftUI:App/FullReferenceApp.swift"
  "07-Playground:PlaygroundSwiftUI:App/PlaygroundApp.swift"
)

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ "${POLY_CONNECTOR_TOKEN:-}" = "" ]; then
  echo "ERROR: POLY_CONNECTOR_TOKEN env var is required."
  echo "       Run as:  POLY_CONNECTOR_TOKEN=... scripts/e2e-validation.sh"
  exit 2
fi

command -v xcodegen >/dev/null 2>&1 || {
  echo "ERROR: xcodegen not found. Install with: brew install xcodegen"
  exit 2
}

# ---------------------------------------------------------------------------
# EXIT trap: revert any token edits we made.
# Backups are stored OUTSIDE the example directory so they don't get picked
# up by xcodegen's directory scan (otherwise the generated .pbxproj refers
# to non-existent *.bak files after restore).
# ---------------------------------------------------------------------------
BACKUP_DIR="/tmp/poly-e2e/_backups"
PATCHED_FILES=()
restore_files() {
  echo ""
  echo "==> Reverting token edits..."
  for f in "${PATCHED_FILES[@]:-}"; do
    [ -z "$f" ] && continue
    # Backup path == BACKUP_DIR + flattened slashes
    flat="${f//\//__}"
    bak="$BACKUP_DIR/$flat"
    if [ -f "$bak" ]; then
      mv -f "$bak" "$f"
      echo "    restored: $f"
    fi
  done
}
trap restore_files EXIT INT TERM

# ---------------------------------------------------------------------------
# Output dir (fresh)
# ---------------------------------------------------------------------------
echo "==> Wiping and recreating $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
LOGDIR="$OUT_DIR/logs"
mkdir -p "$LOGDIR"

# ---------------------------------------------------------------------------
# Simulator
# ---------------------------------------------------------------------------
BOOTED_UDID="$(xcrun simctl list devices booted 2>/dev/null | awk -F'[()]' '/Booted/{print $2; exit}')"
if [ -z "$BOOTED_UDID" ]; then
  echo "==> No simulator booted. Booting '$SIM_NAME'..."
  BOOTED_UDID="$(xcrun simctl list devices available | awk -F'[()]' "/$SIM_NAME/ {print \$2; exit}")"
  if [ -z "$BOOTED_UDID" ]; then
    echo "ERROR: No '$SIM_NAME' simulator available."
    exit 2
  fi
  xcrun simctl boot "$BOOTED_UDID"
  open -a Simulator
  sleep 6
fi
echo "==> Using simulator UDID: $BOOTED_UDID"

# ---------------------------------------------------------------------------
# Patch token into all example App.swift files
# ---------------------------------------------------------------------------
echo "==> Patching API key into example App.swift files (will revert on exit)"
mkdir -p "$BACKUP_DIR"
for entry in "${SWIFTUI_EXAMPLES[@]}"; do
  dir="${entry%%:*}"
  rest="${entry#*:}"
  app_rel="${rest##*:}"
  app_path="$REPO_ROOT/Examples/SwiftUI/$dir/$app_rel"
  if [ ! -f "$app_path" ]; then
    echo "    WARNING: $app_path not found, skipping patch"
    continue
  fi
  flat="${app_path//\//__}"
  cp -p "$app_path" "$BACKUP_DIR/$flat"
  PATCHED_FILES+=("$app_path")
  # In-place: replace YOUR_API_KEY with the real token
  /usr/bin/sed -i '' "s/YOUR_API_KEY/${POLY_CONNECTOR_TOKEN}/g" "$app_path"
done

# ---------------------------------------------------------------------------
# screenshot_example <name> <dir-under-Examples/SwiftUI> <scheme> <screenshot-path>
# ---------------------------------------------------------------------------
build_results=()
screenshot_example() {
  local name="$1"
  local subdir="$2"
  local scheme="$3"
  local shot="$4"
  local dir="$REPO_ROOT/Examples/SwiftUI/$subdir"
  local log="$LOGDIR/${scheme}.log"

  echo ""
  echo "==> [$name] xcodegen + build"
  ( cd "$dir" && xcodegen generate ) >"$log" 2>&1 || true

  local dd="$REPO_ROOT/.build/dd-e2e-$scheme"
  xcodebuild -project "$dir/$scheme.xcodeproj" -scheme "$scheme" \
    -destination "$DEST" -derivedDataPath "$dd" \
    -configuration Debug build >>"$log" 2>&1
  if ! grep -q "BUILD SUCCEEDED" "$log"; then
    echo "    [$name] BUILD FAILED (see $log)"
    build_results+=("$name|FAIL|build")
    return 1
  fi

  # Locate the .app
  local app_bundle
  app_bundle="$(find "$dd/Build/Products" -maxdepth 4 -name "$scheme.app" -type d | head -1)"
  if [ -z "$app_bundle" ]; then
    echo "    [$name] could not find $scheme.app"
    build_results+=("$name|FAIL|missing-app")
    return 1
  fi
  local bundle_id
  bundle_id="$(defaults read "$app_bundle/Info" CFBundleIdentifier 2>/dev/null || echo "ai.poly.examples.$scheme")"

  echo "    [$name] installing $bundle_id"
  xcrun simctl terminate "$BOOTED_UDID" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$BOOTED_UDID" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl install "$BOOTED_UDID" "$app_bundle" >>"$log" 2>&1

  echo "    [$name] launching + waiting 8s"
  xcrun simctl launch "$BOOTED_UDID" "$bundle_id" >>"$log" 2>&1 || true
  sleep 8

  xcrun simctl io "$BOOTED_UDID" screenshot "$shot" >/dev/null 2>&1
  if [ -f "$shot" ]; then
    echo "    [$name] screenshot -> $shot"
    build_results+=("$name|PASS|$shot")
  else
    echo "    [$name] screenshot FAILED"
    build_results+=("$name|FAIL|screenshot")
  fi

  xcrun simctl terminate "$BOOTED_UDID" "$bundle_id" >/dev/null 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# Part 1: screenshots for all 7 SwiftUI examples
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "PART 1: Screenshot pass (7 examples)"
echo "========================================"

# 01-Hello stands in as the "Quick Start" project — it's the README Step-1 example.
screenshot_example "01-quickstart"        "01-Hello"        "HelloSwiftUI"          "$OUT_DIR/01-quickstart.png"          || true
screenshot_example "02-standard-idle"     "02-Standard"     "StandardSwiftUI"       "$OUT_DIR/02-standard-idle.png"       || true
screenshot_example "03-richcontent-idle"  "03-RichContent"  "RichContentSwiftUI"    "$OUT_DIR/03-richcontent-idle.png"    || true
screenshot_example "04-resilience-idle"   "04-Resilience"   "ResilienceSwiftUI"     "$OUT_DIR/04-resilience-idle.png"     || true
screenshot_example "05-handoff-idle"      "05-Handoff"      "HandoffSwiftUI"        "$OUT_DIR/05-handoff-idle.png"        || true
screenshot_example "06-fullref-launcher"  "06-FullReference" "FullReferenceSwiftUI" "$OUT_DIR/06-fullref-launcher.png"    || true
screenshot_example "07-playground-launcher" "07-Playground" "PlaygroundSwiftUI"     "$OUT_DIR/07-playground-launcher.png" || true

# ---------------------------------------------------------------------------
# Part 2: live E2E XCUITest against StandardSwiftUI
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "PART 2: Live XCUITest (StandardSwiftUI)"
echo "========================================"
STD_DIR="$REPO_ROOT/Examples/SwiftUI/02-Standard"
STD_LOG="$LOGDIR/uitest-standard.log"
STD_RESULT_BUNDLE="$OUT_DIR/StandardSwiftUI.xcresult"
rm -rf "$STD_RESULT_BUNDLE"

( cd "$STD_DIR" && xcodegen generate ) >"$STD_LOG" 2>&1
echo "==> Running xcodebuild test (this may take 2-3 min over live backend)"
xcodebuild test \
  -project "$STD_DIR/StandardSwiftUI.xcodeproj" \
  -scheme StandardSwiftUI \
  -destination "$DEST" \
  -derivedDataPath "$REPO_ROOT/.build/dd-e2e-StandardSwiftUI" \
  -resultBundlePath "$STD_RESULT_BUNDLE" \
  >>"$STD_LOG" 2>&1
UITEST_RC=$?
if [ "$UITEST_RC" -eq 0 ] || grep -q "TEST SUCCEEDED" "$STD_LOG"; then
  UITEST_VERDICT="PASS"
else
  UITEST_VERDICT="FAIL"
fi
echo "==> XCUITest verdict: $UITEST_VERDICT (see $STD_LOG, $STD_RESULT_BUNDLE)"

# Extract any screenshots/attachments embedded in the xcresult bundle.
if [ -d "$STD_RESULT_BUNDLE" ]; then
  echo "==> Extracting XCUITest attachments..."
  ATT_DIR="$OUT_DIR/xcuitest-attachments"
  mkdir -p "$ATT_DIR"
  # Best-effort: just copy the bundle so the team has the raw artifacts.
  # Modern xcresulttool API requires --legacy or JSON parsing; we leave the
  # xcresult bundle in $OUT_DIR for Xcode to open.
  ls "$STD_RESULT_BUNDLE" > "$ATT_DIR/_bundle-contents.txt" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "SUMMARY"
echo "========================================"
echo ""
echo "Part 1 — screenshot pass:"
PASS_COUNT=0; FAIL_COUNT=0
for r in "${build_results[@]}"; do
  name="${r%%|*}"; rest="${r#*|}"; verdict="${rest%%|*}"; detail="${rest#*|}"
  if [ "$verdict" = "PASS" ]; then
    echo "  PASS  $name  ->  $detail"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "  FAIL  $name  ($detail)  log: $LOGDIR/"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
done
echo ""
echo "  Part 1 total: $PASS_COUNT pass / $FAIL_COUNT fail"
echo ""
echo "Part 2 — XCUITest verdict: $UITEST_VERDICT"
echo "  Log:      $STD_LOG"
echo "  xcresult: $STD_RESULT_BUNDLE  (open in Xcode)"
echo ""
echo "All artifacts:  $OUT_DIR"
echo ""
echo "Done."
exit 0
