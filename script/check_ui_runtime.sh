#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PersonalSitePublisherMac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

fail() {
  echo "ui runtime gate: $*" >&2
  exit 1
}

bash "$ROOT_DIR/script/build_and_run.sh" --package-only >/dev/null

[[ -d "$APP_BUNDLE" ]] || fail "app bundle was not created"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
[[ "$bundle_id" == "com.jinfang.PersonalSitePublisherMac" ]] || fail "unexpected bundle identifier: $bundle_id"

minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
[[ "$minimum_system" == "14.0" ]] || fail "unexpected minimum system version: $minimum_system"

for file in \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/SettingsView.swift"; do
  [[ -f "$file" ]] || fail "expected UI file is missing: ${file#$ROOT_DIR/}"
done

bash "$ROOT_DIR/script/check_accessibility.sh"

grep -q "wait_for_main_window" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run --verify must wait for a visible main window"
grep -q "count of windows" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run --verify must query the app window count"

if [[ "${RUN_UI_APP:-0}" == "1" ]]; then
  bash "$ROOT_DIR/script/build_and_run.sh" --verify
fi

echo "ui runtime gate: bundle, plist, executable, core UI files, accessibility contract, and window verification contract verified"
