#!/usr/bin/env bash
# e2e-validation.sh — Deep end-to-end validation of the PolyMessaging iOS SDK
# example ladder.
#
#   1. Builds & screenshots all 7 SwiftUI examples (01-Hello through 07-Playground)
#   2. Runs the StandardSwiftUI XCUITest target (live E2E against dev backend)
#   3. Runs NotificationBannerUITests (foreground banner) across SwiftUI+UIKit
#      × 03/06/07, then (3b) the reboot/resume-dedupe test on SwiftUI 06.
#   4. Drops everything into /tmp/poly-e2e/ + prints a pass/fail summary.
#
# The connector token MUST be provided via POLY_CONNECTOR_TOKEN env var —
# never hard-coded.
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

# Optional overrides for the live config. When POLY_ENVIRONMENT is set, every
# patched App entrypoint is rewritten to that environment + host identifier.
# Leave empty to keep each example's committed `.us` default.
#   e.g. POLY_ENVIRONMENT='.cluster("dev")' \
#        POLY_HOST_IDENTIFIER='https://jupiter-api.dev.polyai.app/' ...
POLY_ENVIRONMENT="${POLY_ENVIRONMENT:-}"
POLY_HOST_IDENTIFIER="${POLY_HOST_IDENTIFIER:-}"

# Notification-banner E2E targets (Part 3). Each entry:
#   <framework>:<dir>:<scheme>:<App entrypoint rel-path>
# These run NotificationBannerUITests and confirm the foreground banner
# from Components/NewMessageNotifier.swift, saving a screenshot of the banner.
NOTIF_TARGETS=(
  "SwiftUI:03-RichContent:RichContentSwiftUI:App/RichContentApp.swift"
  "UIKit:03-RichContent:RichContentUIKit:App/AppDelegate.swift"
  "SwiftUI:06-FullReference:FullReferenceSwiftUI:App/FullReferenceApp.swift"
  "UIKit:06-FullReference:FullReferenceUIKit:App/AppDelegate.swift"
  "SwiftUI:07-Playground:PlaygroundSwiftUI:App/PlaygroundApp.swift"
  "UIKit:07-Playground:PlaygroundUIKit:App/AppDelegate.swift"
)

# Reboot/resume-dedupe E2E targets (Part 3b). Same entry shape as NOTIF_TARGETS.
# These run test_resume_doesNotReNotifyAlreadyShownMessages: notify once, then
# relaunch + resume the same conversation and assert the SDK's history replay
# does NOT re-show a banner (the persisted messageId store in
# Components/NewMessageNotifier.swift must suppress it). Only the 06-FullReference
# SwiftUI example carries this test today — its connect screen offers an explicit
# "Resume Chat" button, which the test drives.
NOTIF_RESUME_TARGETS=(
  "SwiftUI:06-FullReference:FullReferenceSwiftUI:App/FullReferenceApp.swift"
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
echo "==> Patching connector token into example App.swift files (will revert on exit)"
mkdir -p "$BACKUP_DIR"

# patch_app <abs-app-path>
# Backs up, injects the token, and — when POLY_ENVIRONMENT is set — rewrites the
# initialize(.init(...)) block to that environment + host identifier. Idempotent
# across the SwiftUI and notification lists (skips if already backed up).
patch_app() {
  local app_path="$1"
  if [ ! -f "$app_path" ]; then
    echo "    WARNING: $app_path not found, skipping patch"
    return
  fi
  local flat="${app_path//\//__}"
  [ -f "$BACKUP_DIR/$flat" ] && return   # already patched this run
  cp -p "$app_path" "$BACKUP_DIR/$flat"
  PATCHED_FILES+=("$app_path")
  TOKEN="$POLY_CONNECTOR_TOKEN" ENVV="$POLY_ENVIRONMENT" HOSTID="$POLY_HOST_IDENTIFIER" \
  python3 - "$app_path" <<'PY'
import os, re, sys
path = sys.argv[1]
tok, env, host = os.environ["TOKEN"], os.environ.get("ENVV",""), os.environ.get("HOSTID","")
s = open(path).read()
s = s.replace("YOUR_CONNECTOR_TOKEN", tok)
if env:
    fields = [f'apiKey: "{tok}"', f'environment: {env}']
    if host:
        fields.append(f'hostIdentifier: "{host}"')
    fields.append('logLevel: .error')
    block = "PolyMessaging.initialize(.init(\n            " + ",\n            ".join(fields) + "\n        ))"
    s2 = re.sub(r'PolyMessaging\.initialize\(\.init\(.*?\)\)', block, s, count=1, flags=re.S)
    if s2 == s:
        sys.stderr.write(f"WARNING: no initialize block matched in {path}\n")
    s = s2
open(path, "w").write(s)
PY
}

for entry in "${SWIFTUI_EXAMPLES[@]}"; do
  dir="${entry%%:*}"; rest="${entry#*:}"; app_rel="${rest##*:}"
  patch_app "$REPO_ROOT/Examples/SwiftUI/$dir/$app_rel"
done
# Also patch the UIKit notification targets (Part 3 drives these too).
for entry in "${NOTIF_TARGETS[@]}"; do
  IFS=':' read -r fw dir scheme app_rel <<<"$entry"
  patch_app "$REPO_ROOT/Examples/$fw/$dir/$app_rel"
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
STD_DIR="$REPO_ROOT/Examples/SwiftUI/Chat/02-Standard"
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
# Part 3: notification-banner E2E (SwiftUI + UIKit, 03 + 06 + 07)
#
# Runs NotificationBannerUITests on each target: grants notification permission,
# sends a message, and confirms a foreground local-notification banner is
# presented when the agent replies. The banner screenshot is extracted to
# $OUT_DIR/notif-<tag>-banner.png.
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "PART 3: Notification banner E2E"
echo "========================================"

notif_results=()
notif_one() {
  local fw="$1" dir="$2" scheme="$3" tag="$4"
  local proj_dir="$REPO_ROOT/Examples/$fw/$dir"
  local log="$LOGDIR/notif-$tag.log"
  local rb="$OUT_DIR/notif-$tag.xcresult"
  rm -rf "$rb"

  echo ""
  echo "==> [$tag] xcodegen + NotificationBannerUITests"
  ( cd "$proj_dir" && xcodegen generate ) >"$log" 2>&1 || true
  xcodebuild test \
    -project "$proj_dir/$scheme.xcodeproj" -scheme "$scheme" \
    -destination "$DEST" -derivedDataPath "$REPO_ROOT/.build/dd-e2e-$tag" \
    -only-testing:"${scheme}UITests/NotificationBannerUITests/test_newMessageBanner_appearsWhileForeground" \
    -resultBundlePath "$rb" >>"$log" 2>&1
  local rc=$?

  # Extract the banner screenshot (attachment named "2-BANNER…").
  local shot="$OUT_DIR/notif-$tag-banner.png"
  if [ -d "$rb" ]; then
    local exdir="$OUT_DIR/_att-$tag"; mkdir -p "$exdir"
    xcrun xcresulttool export attachments --path "$rb" --output-path "$exdir" >/dev/null 2>&1 || true
    if [ -f "$exdir/manifest.json" ]; then
      local fname
      fname="$(python3 -c "import json,sys;d=json.load(open('$exdir/manifest.json'));print(next((a['exportedFileName'] for e in d for a in e.get('attachments',[]) if (a.get('suggestedHumanReadableName') or '').startswith('2-BANNER')),''))" 2>/dev/null)"
      [ -n "$fname" ] && [ -f "$exdir/$fname" ] && cp -f "$exdir/$fname" "$shot"
    fi
  fi

  if [ "$rc" -eq 0 ] || grep -q "TEST SUCCEEDED" "$log"; then
    echo "    [$tag] PASS  (banner: ${shot})"
    notif_results+=("$tag|PASS|$shot")
  else
    echo "    [$tag] FAIL  (see $log)"
    notif_results+=("$tag|FAIL|$log")
  fi
}

for entry in "${NOTIF_TARGETS[@]}"; do
  IFS=':' read -r fw dir scheme _ <<<"$entry"
  tag="$(echo "${fw}-${dir%%-*}" | tr '[:upper:]' '[:lower:]')"
  notif_one "$fw" "$dir" "$scheme" "$tag"
done

# ---------------------------------------------------------------------------
# Part 3b: reboot/resume-dedupe E2E
#
# Runs test_resume_doesNotReNotifyAlreadyShownMessages: the test relaunches the
# app and resumes the conversation, so the SDK replays history; the persisted
# messageId store must suppress any second banner. PASS means *no* duplicate
# banner appeared during the resume window.
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "PART 3b: Reboot/resume dedupe E2E"
echo "========================================"

resume_results=()
resume_one() {
  local fw="$1" dir="$2" scheme="$3" tag="$4"
  local proj_dir="$REPO_ROOT/Examples/$fw/$dir"
  local log="$LOGDIR/resume-$tag.log"
  local rb="$OUT_DIR/resume-$tag.xcresult"
  rm -rf "$rb"

  echo ""
  echo "==> [$tag] xcodegen + resume-dedupe test"
  ( cd "$proj_dir" && xcodegen generate ) >"$log" 2>&1 || true
  xcodebuild test \
    -project "$proj_dir/$scheme.xcodeproj" -scheme "$scheme" \
    -destination "$DEST" -derivedDataPath "$REPO_ROOT/.build/dd-e2e-$tag" \
    -only-testing:"${scheme}UITests/NotificationBannerUITests/test_resume_doesNotReNotifyAlreadyShownMessages" \
    -resultBundlePath "$rb" >>"$log" 2>&1
  local rc=$?

  # On FAIL, surface the unexpected-resume-banner screenshot if the test captured one.
  local shot="$OUT_DIR/resume-$tag-no-banner.png"
  if [ -d "$rb" ]; then
    local exdir="$OUT_DIR/_att-resume-$tag"; mkdir -p "$exdir"
    xcrun xcresulttool export attachments --path "$rb" --output-path "$exdir" >/dev/null 2>&1 || true
    if [ -f "$exdir/manifest.json" ]; then
      local fname
      fname="$(python3 -c "import json,sys;d=json.load(open('$exdir/manifest.json'));print(next((a['exportedFileName'] for e in d for a in e.get('attachments',[]) if (a.get('suggestedHumanReadableName') or '').startswith('resume-no-banner')),''))" 2>/dev/null)"
      [ -n "$fname" ] && [ -f "$exdir/$fname" ] && cp -f "$exdir/$fname" "$shot"
    fi
  fi

  if [ "$rc" -eq 0 ] || grep -q "TEST SUCCEEDED" "$log"; then
    echo "    [$tag] PASS  (no duplicate banner on resume)"
    resume_results+=("$tag|PASS|$shot")
  else
    echo "    [$tag] FAIL  (see $log)"
    resume_results+=("$tag|FAIL|$log")
  fi
}

for entry in "${NOTIF_RESUME_TARGETS[@]}"; do
  IFS=':' read -r fw dir scheme _ <<<"$entry"
  tag="$(echo "${fw}-${dir%%-*}" | tr '[:upper:]' '[:lower:]')"
  resume_one "$fw" "$dir" "$scheme" "$tag"
done

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
echo "Part 3 — notification banner E2E:"
NOTIF_PASS=0; NOTIF_FAIL=0
for r in "${notif_results[@]:-}"; do
  [ -z "$r" ] && continue
  tag="${r%%|*}"; rest="${r#*|}"; verdict="${rest%%|*}"; detail="${rest#*|}"
  if [ "$verdict" = "PASS" ]; then
    echo "  PASS  $tag  ->  $detail"
    NOTIF_PASS=$((NOTIF_PASS+1))
  else
    echo "  FAIL  $tag  ($detail)"
    NOTIF_FAIL=$((NOTIF_FAIL+1))
  fi
done
echo "  Part 3 total: $NOTIF_PASS pass / $NOTIF_FAIL fail"
echo ""
echo "Part 3b — reboot/resume dedupe E2E:"
RESUME_PASS=0; RESUME_FAIL=0
for r in "${resume_results[@]:-}"; do
  [ -z "$r" ] && continue
  tag="${r%%|*}"; rest="${r#*|}"; verdict="${rest%%|*}"; detail="${rest#*|}"
  if [ "$verdict" = "PASS" ]; then
    echo "  PASS  $tag  (no duplicate banner on resume)"
    RESUME_PASS=$((RESUME_PASS+1))
  else
    echo "  FAIL  $tag  ($detail)"
    RESUME_FAIL=$((RESUME_FAIL+1))
  fi
done
echo "  Part 3b total: $RESUME_PASS pass / $RESUME_FAIL fail"
echo ""
echo "All artifacts:  $OUT_DIR"
echo ""
echo "Done."
exit 0
