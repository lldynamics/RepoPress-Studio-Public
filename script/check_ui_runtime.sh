#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/RepoPress Studio.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/PersonalSitePublisherMac"
MANIFEST="${RELEASE_ARTIFACT_MANIFEST:-$ROOT_DIR/.build/release-artifact-manifest.json}"
MODE="${1:---package-only}"
fail() { echo "ui runtime artifact gate: $*" >&2; exit 1; }
[[ "$MODE" == "--package-only" || "$MODE" == "--launch" ]] || fail "unknown argument: $MODE"
if [[ -n "${RELEASE_ARTIFACT_MANIFEST:-}" && -f "$MANIFEST" ]]; then
  python3 "$ROOT_DIR/script/release_artifact_manifest.py" validate --root "$ROOT_DIR" --manifest "$MANIFEST" || fail "Release artifact manifest is missing, stale, or drifted"
else
  build_arguments=(--package-only --release)
  bash "$ROOT_DIR/script/build_and_run.sh" "${build_arguments[@]}" >/dev/null
  python3 "$ROOT_DIR/script/release_artifact_manifest.py" create --root "$ROOT_DIR" --manifest "$MANIFEST" || fail "could not create Release artifact manifest"
fi
[[ -d "$APP_BUNDLE" ]] || fail "app bundle was not created"
[[ -x "$APP_BINARY" ]] || fail "app executable is missing or not executable"
[[ -d "$APP_BUNDLE/Contents/Resources" ]] || fail "app Resources directory is missing"
[[ -f "$APP_BUNDLE/Contents/Resources/en.lproj/Localizable.strings" ]] || fail "app English localization is missing"
[[ -f "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj/Localizable.strings" ]] || fail "app Simplified Chinese localization is missing"
[[ -d "$APP_BUNDLE/Contents/Resources/PersonalSitePublisherMac_PublishingCoreSupport.bundle" ]] || fail "core SwiftPM resource bundle is missing"
[[ -f "$APP_BUNDLE/Contents/Resources/TreeSitterMarkdown_TreeSitterMarkdown.bundle/queries/highlights.scm" ]] || fail "Tree-sitter Markdown highlight queries are missing"
[[ -f "$APP_BUNDLE/Contents/Resources/TreeSitterMarkdown_TreeSitterMarkdownInline.bundle/queries/highlights.scm" ]] || fail "Tree-sitter Markdown inline highlight queries are missing"
plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is invalid"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
[[ "$bundle_id" == "com.jinfang.PersonalSitePublisherMac" ]] || fail "unexpected bundle identifier: $bundle_id"
build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$INFO_PLIST")"
[[ "$build_configuration" == "Release" ]] || fail "packaged app must use the Release configuration"
grep -q 'wait_for_main_window' "$ROOT_DIR/script/build_and_run.sh" || fail "Release verification must wait for a visible main window"
grep -q 'count of windows' "$ROOT_DIR/script/build_and_run.sh" || fail "Release verification must query app window count"
grep -q -- '--launch-baseline' "$ROOT_DIR/script/build_and_run.sh" || fail "Release launch baseline mode is missing"
grep -q 'window_visibility_probe' "$ROOT_DIR/script/build_and_run.sh" || fail "launch must use the target-process window probe"
[[ -x "$ROOT_DIR/script/check_launch_performance.sh" ]] || fail "launch performance gate is missing"
echo "ui runtime artifact gate: Release package artifact and manifest passed"
if [[ "$MODE" == "--launch" ]]; then
  actual_entitlements="$(mktemp "${TMPDIR:-/tmp}/ui-runtime-entitlements.XXXXXX")"
  trap 'rm -f "$actual_entitlements"' EXIT
  codesign -d --entitlements :- "$APP_BUNDLE" >"$actual_entitlements" 2>/dev/null || fail "could not read Release bundle entitlements"
  actual_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$actual_entitlements" 2>/dev/null || true)"
  [[ "$actual_sandbox" != "true" ]] || fail "Release launch bundle unexpectedly enables App Sandbox"
  bash "$ROOT_DIR/script/check_launch_performance.sh" --release
  echo "ui runtime artifact gate: non-sandboxed Release artifact launch passed"
fi
