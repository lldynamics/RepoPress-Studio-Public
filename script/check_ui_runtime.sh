#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="PersonalSitePublisherMac"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
CORE_RESOURCE_BUNDLE="$APP_RESOURCES/${APP_NAME}_PublishingWorkbenchCore.bundle"
MODE="package"

fail() {
  echo "ui runtime gate: $*" >&2
  exit 1
}

case "${1:-}" in
  ""|--package-only)
    MODE="package"
    ;;
  --launch)
    MODE="launch"
    ;;
  *)
    fail "unknown argument: $1"
    ;;
esac

build_arguments=(--package-only)
if [[ "$MODE" == "launch" ]]; then
  build_arguments+=(--release)
fi
bash "$ROOT_DIR/script/build_and_run.sh" "${build_arguments[@]}" >/dev/null

[[ -d "$APP_BUNDLE" ]] || fail "app bundle was not created"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
[[ -d "$APP_RESOURCES" ]] || fail "app Resources directory is missing"
[[ -f "$APP_RESOURCES/en.lproj/Localizable.strings" ]] || fail "app English localization is missing"
[[ -f "$APP_RESOURCES/zh-Hans.lproj/Localizable.strings" ]] || fail "app Simplified Chinese localization is missing"
[[ -d "$CORE_RESOURCE_BUNDLE" ]] || fail "core SwiftPM resource bundle is missing"
plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
[[ "$bundle_id" == "com.jinfang.PersonalSitePublisherMac" ]] || fail "unexpected bundle identifier: $bundle_id"

minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
[[ "$minimum_system" == "14.0" ]] || fail "unexpected minimum system version: $minimum_system"

for file in \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/SettingsView.swift"; do
  [[ -f "$file" ]] || fail "expected UI file is missing: ${file#$ROOT_DIR/}"
done

bash "$ROOT_DIR/script/check_accessibility.sh"

grep -q "wait_for_main_window" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run --verify must wait for a visible main window"
grep -q "count of windows" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run --verify must query the app window count"
grep -q -- "--launch-baseline" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "build_and_run must expose a launch performance baseline mode"
[[ -x "$ROOT_DIR/script/check_launch_performance.sh" ]] \
  || fail "launch performance gate is missing or not executable"

grep -Fq ".frame(minHeight: 120, idealHeight: 132, maxHeight: 140)" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  || fail "compact empty states must keep the shared 120-140 point height"
grep -Fq "density: .compactPane" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  || fail "the image workbench empty state must use compact density"
grep -Fq "summary.imageCount > 0" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  || fail "the image workbench must hide refresh when no images exist"

content_view="$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ContentView.swift"
grep -Fq "@ObservedObject private var presentationState: WorkbenchContentPresentationFeatureFacade" \
  "$content_view" \
  || fail "ContentView must observe the narrow presentation projection"
if grep -Eq "@ObservedObject private var (aiState: WorkbenchAIFeatureFacade|publishingState: WorkbenchPublishingFeatureFacade)" \
  "$content_view"; then
  fail "ContentView must not observe broad AI or publishing facades"
fi

if [[ "$MODE" == "launch" ]]; then
  build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$INFO_PLIST")"
  [[ "$build_configuration" == "Release" ]] || fail "launch verification must use a Release bundle"
  actual_entitlements="$(mktemp "${TMPDIR:-/tmp}/ui-runtime-entitlements.XXXXXX")"
  trap 'rm -f "$actual_entitlements"' EXIT
  codesign -d --entitlements :- "$APP_BUNDLE" >"$actual_entitlements" 2>/dev/null \
    || fail "could not read Release bundle entitlements"
  actual_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$actual_entitlements" 2>/dev/null || true)"
  [[ "$actual_sandbox" == "true" ]] || fail "Release launch bundle is missing App Sandbox"
  bash "$ROOT_DIR/script/check_launch_performance.sh" --release
fi

if [[ "$MODE" == "launch" ]]; then
  echo "ui runtime gate: sandboxed Release artifact passed and a real visible main-window launch was verified"
else
  echo "ui runtime gate: packaged artifact passed; real app launch was not run"
fi
