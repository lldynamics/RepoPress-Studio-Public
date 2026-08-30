#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIEWS="$ROOT_DIR/Sources/PersonalSitePublisherMac/Views"
fail() { echo "ui product-contract gate: $*" >&2; exit 1; }

top_level_view_files="$(find "$VIEWS" -maxdepth 1 -type f -name '*.swift' -print)"
[[ -z "$top_level_view_files" ]] || fail "view source files must be grouped by business domain: $top_level_view_files"
for file in \
  Workspace/ContentView.swift Workspace/WorkspaceLayoutViews.swift \
  AIChat/AIChatWorkspaceInspectorComponents.swift Workspace/WorkspaceTaskInspector.swift \
  Settings/SettingsView.swift; do
  [[ -f "$VIEWS/$file" ]] || fail "expected UI source is missing: $file"
done
grep -Fq '.frame(minHeight: 120, idealHeight: 132, maxHeight: 140)' "$VIEWS/Shared/WorkbenchStateView.swift" || fail "compact empty-state height contract changed"
grep -Fq 'ForEach(ImageWorkbenchBatchAction.allActions)' "$VIEWS/Images/ImageWorkbenchView.swift" || fail "image workbench operations are hidden"
grep -Fq 'RepositoryImageBrowserView(' "$VIEWS/Images/ImageWorkbenchView.swift" || fail "image browser is missing"
grep -Fq '.accessibilityIdentifier("image-workbench-refresh")' "$VIEWS/Images/ImageWorkbenchView.swift" || fail "image rescan identifier is missing"
for image_file in RepositoryImageBrowserView.swift AssetResourceManagerView.swift; do
  grep -Fq 'density: .compactPane' "$VIEWS/Images/$image_file" || fail "image empty state density changed: $image_file"
done
grep -Fq 'WorkspaceQuickSearchView(' "$VIEWS/Workspace/WorkspaceContextSidebarView.swift" || fail "quick search is missing from sidebar"
grep -Fq '.accessibilityIdentifier("workspace-quick-search-field")' "$VIEWS/Workspace/WorkspaceQuickSearchView.swift" || fail "quick search accessibility identifier is missing"
grep -Fq 'store.focusDraft(draftID, section: .writing)' "$VIEWS/Workspace/WorkspaceQuickSearchView.swift" || fail "quick search does not open articles"
content_view="$VIEWS/Workspace/ContentView.swift"
grep -Fq '@ObservedObject private var rootPresentation: WorkbenchRootPresentationFeatureFacade' "$content_view" || fail "ContentView must observe narrow presentation projection"
if grep -Eq '@ObservedObject private var (aiState: WorkbenchAIFeatureFacade|publishingState: WorkbenchPublishingFeatureFacade)' "$content_view"; then
  fail "ContentView observes broad AI or publishing facades"
fi
if grep -Fq 'private var optimizationMenu' "$VIEWS/Images/ImageWorkbenchView.swift"; then fail "primary image operations returned to legacy menu"; fi
for source in \
  Repository/RepositoryWorkspaceView.swift:repository-workspace \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-primary-actions \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-action-select-folder \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-action-scan \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-action-import \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-action-data-management \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-action-open-images \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-next-action \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-section-summary \
  Repository/RepositoryWorkspaceOverviewSections.swift:repository-section-information \
  Repository/RepositoryWorkspacePublishingSections.swift:repository-section-online-publish \
  Repository/RepositoryWorkspaceAutoSyncSection.swift:repository-section-auto-sync \
  Repository/RepositoryWorkspaceLocalPreviewSection.swift:repository-section-local-preview \
  Repository/RepositoryWorkspacePublishingSections.swift:repository-section-sync-plan \
  Repository/RepositoryWorkspacePublishingSections.swift:repository-section-path-rules \
  Repository/RepositoryWorkspaceRemoteChangesSection.swift:repository-section-remote-changes \
  Repository/RepositoryWorkspaceChangeSections.swift:repository-section-local-changes \
  Publishing/ReleaseHistoryDetailView.swift:repository-section-release-history; do
  file="${source%%:*}"; identifier="${source#*:}"
  grep -Fq ".accessibilityIdentifier(\"$identifier\")" "$VIEWS/$file" || fail "repository UI identifier missing: $identifier"
done
grep -Fq 'onlinePublishCenterSection' "$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift" || fail "online publish center is missing"
for folded in Repository/RepositoryWorkspaceOverviewSections.swift Repository/RepositoryWorkspacePublishingSections.swift Repository/RepositoryWorkspaceLocalPreviewSection.swift Publishing/ReleaseHistoryDetailView.swift Publishing/ReleaseHistoryRecordCardSection.swift; do
  if grep -Fq 'DisclosureGroup' "$VIEWS/$folded"; then fail "repository/release history must remain visible: $folded"; fi
done
if grep -Fq 'repositoryActionsMenu' "$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift" || grep -Fq 'Menu {' "$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift"; then fail "repository primary actions returned to a hidden menu"; fi
echo "ui product-contract gate: source UI contracts passed (not a real UI smoke test)"
