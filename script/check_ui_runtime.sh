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

build_arguments=(--package-only --release)
if [[ "${RELEASE_GATE_PROFILE:-}" == "app-store" ]]; then
  build_arguments+=(--app-store)
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

build_configuration="$(/usr/libexec/PlistBuddy -c 'Print :PersonalSitePublisherBuildConfiguration' "$INFO_PLIST")"
[[ "$build_configuration" == "Release" ]] \
  || fail "packaged app must use the Release configuration"

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
grep -q "window_visibility_probe" "$ROOT_DIR/script/build_and_run.sh" \
  || fail "launch performance must use the target-process on-screen window probe"
if grep -Fq 'pkill -x "$APP_NAME"' "$ROOT_DIR/script/build_and_run.sh"; then
  fail "release launch cleanup must not terminate same-named isolated UI-test apps"
fi
grep -Fq 'rm -rf "$RUNTIME_HOME/Library/Containers/$TEST_BUNDLE_ID/Data"' \
  "$ROOT_DIR/script/check_accessibility_runtime.sh" \
  || fail "accessibility cleanup must remove only test-owned sandbox data"
if grep -Fq 'rm -rf "$RUNTIME_HOME/Library/Containers/$TEST_BUNDLE_ID"' \
  "$ROOT_DIR/script/check_accessibility_runtime.sh"; then
  fail "accessibility cleanup must preserve ContainerManager-owned metadata"
fi
[[ -x "$ROOT_DIR/script/check_launch_performance.sh" ]] \
  || fail "launch performance gate is missing or not executable"

grep -Fq ".frame(minHeight: 120, idealHeight: 132, maxHeight: 140)" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  || fail "compact empty states must keep the shared 120-140 point height"
for image_empty_state_file in \
  RepositoryImageBrowserView.swift \
  AssetResourceManagerView.swift; do
  grep -Fq "density: .compactPane" \
    "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/$image_empty_state_file" \
    || fail "image workbench empty states must use compact density: $image_empty_state_file"
done
grep -Fq "ForEach(ImageWorkbenchBatchAction.allActions)" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  || fail "the image workbench must keep every primary operation visible"
grep -Fq "RepositoryImageBrowserView(" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  || fail "the image workbench must include the repository image browser"
grep -Fq '.accessibilityIdentifier("image-workbench-refresh")' \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  || fail "the image workbench must keep an accessible rescan action available"

grep -Fq "WorkspaceQuickSearchView(" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  || fail "operational workspaces must keep quick article search in the sidebar"
grep -Fq "repositoryContextStage: shell.selectedSection == .sync" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  || fail "repository navigation must be injected into the sync sidebar"
grep -Fq '.accessibilityIdentifier("repository-sidebar-stage-navigation")' \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  || fail "repository navigation must stay directly below quick search"
grep -Fq "repositoryStageButton(item, stage: stage)" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  || fail "repository stages must remain one full-width button per row"
if grep -Fq "repositoryStageNavigation" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift"; then
  fail "repository navigation must not remain above the center content"
fi
grep -Fq "onlinePublishCenterSection" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift" \
  || fail "repository overview must render the online publish center"

# Release History is now split between its container, record cards, and shared deployment components.
for unfolded_repository_file in \
  RepositoryWorkspaceOverviewSections.swift \
  RepositoryWorkspacePublishingSections.swift \
  RepositoryWorkspaceLocalPreviewSection.swift \
  ReleaseHistoryDetailView.swift \
  ReleaseHistoryComponents.swift \
  ReleaseHistoryRecordCardSection.swift; do
  if grep -Fq "DisclosureGroup" \
    "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/$unfolded_repository_file"; then
    fail "repository and release-history functions must remain visible instead of folded: $unfolded_repository_file"
  fi
done

if grep -Fq "repositoryActionsMenu" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift"; then
  fail "repository primary actions must not return to the legacy actions menu"
fi
if grep -Fq "Menu {" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift"; then
  fail "repository overview actions must remain visible instead of being hidden in a menu"
fi

repository_identifier_sources=(
  "RepositoryWorkspaceView.swift:repository-workspace"
  "RepositoryWorkspaceOverviewSections.swift:repository-primary-actions"
  "RepositoryWorkspaceOverviewSections.swift:repository-action-select-folder"
  "RepositoryWorkspaceOverviewSections.swift:repository-action-scan"
  "RepositoryWorkspaceOverviewSections.swift:repository-action-import"
  "RepositoryWorkspaceOverviewSections.swift:repository-action-data-management"
  "RepositoryWorkspaceOverviewSections.swift:repository-action-open-images"
  "RepositoryWorkspaceOverviewSections.swift:repository-next-action"
  "RepositoryWorkspaceOverviewSections.swift:repository-section-summary"
  "RepositoryWorkspaceOverviewSections.swift:repository-section-information"
  "RepositoryWorkspacePublishingSections.swift:repository-section-online-publish"
  "RepositoryWorkspaceAutoSyncSection.swift:repository-section-auto-sync"
  "RepositoryWorkspaceLocalPreviewSection.swift:repository-section-local-preview"
  "RepositoryWorkspacePublishingSections.swift:repository-section-sync-plan"
  "RepositoryWorkspacePublishingSections.swift:repository-section-path-rules"
  "RepositoryWorkspaceRemoteChangesSection.swift:repository-section-remote-changes"
  "RepositoryWorkspaceChangeSections.swift:repository-section-local-changes"
  "ReleaseHistoryDetailView.swift:repository-section-release-history"
)
for identifier_source in "${repository_identifier_sources[@]}"; do
  source_file="${identifier_source%%:*}"
  identifier="${identifier_source#*:}"
  grep -Fq ".accessibilityIdentifier(\"$identifier\")" \
    "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/$source_file" \
    || fail "repository UI must expose $identifier in $source_file"
done

grep -Fq '.accessibilityIdentifier("workspace-quick-search-field")' \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  || fail "the workspace quick search must keep an accessible search field"
grep -Fq "store.focusDraft(draftID, section: .writing)" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  || fail "workspace quick search results must open their article"
if grep -Fq "private var optimizationMenu" \
  "$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift"; then
  fail "the image workbench must not hide primary operations in the legacy menu"
fi

content_view="$ROOT_DIR/Sources/PersonalSitePublisherMac/Views/ContentView.swift"
grep -Fq "@ObservedObject private var presentationState: WorkbenchContentPresentationFeatureFacade" \
  "$content_view" \
  || fail "ContentView must observe the narrow presentation projection"
if grep -Eq "@ObservedObject private var (aiState: WorkbenchAIFeatureFacade|publishingState: WorkbenchPublishingFeatureFacade)" \
  "$content_view"; then
  fail "ContentView must not observe broad AI or publishing facades"
fi

if [[ "$MODE" == "launch" ]]; then
  actual_entitlements="$(mktemp "${TMPDIR:-/tmp}/ui-runtime-entitlements.XXXXXX")"
  trap 'rm -f "$actual_entitlements"' EXIT
  codesign -d --entitlements :- "$APP_BUNDLE" >"$actual_entitlements" 2>/dev/null \
    || fail "could not read Release bundle entitlements"
  actual_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$actual_entitlements" 2>/dev/null || true)"
  [[ "$actual_sandbox" != "true" ]] \
    || fail "Release launch bundle unexpectedly enables App Sandbox"
  bash "$ROOT_DIR/script/check_launch_performance.sh" --release
fi

if [[ "$MODE" == "launch" ]]; then
  echo "ui runtime gate: non-sandboxed Release artifact passed and a real visible main-window launch was verified"
else
  echo "ui runtime gate: packaged artifact passed; real app launch was not run"
fi
