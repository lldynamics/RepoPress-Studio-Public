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
compact_state="$(sed -n '/case \.compactPane:/,/case \.inline:/p' "$VIEWS/Shared/WorkbenchStateView.swift")"
grep -Fq '.frame(minHeight: 120)' <<<"$compact_state" || fail "compact empty-state minimum height contract changed"
if grep -Fq 'maxHeight:' <<<"$compact_state"; then fail "compact empty-state must grow with content instead of using a maximum height"; fi
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
grep -Fq 'WorkbenchDisclosureGroupStyle(toggleIdentifier: "repository-section-more-tools")' "$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift" || fail "repository more-tools disclosure identifier is missing"
disclosure_style="$VIEWS/Workspace/WorkbenchDisclosureGroupStyle.swift"
for required in 'Button {' 'configuration.isExpanded.toggle()' '.contentShape(Rectangle())' '.accessibilityIdentifier(toggleIdentifier)' '.accessibilityValue(configuration.isExpanded' 'configuration.content'; do
  grep -Fq "$required" "$disclosure_style" || fail "accessible disclosure contract is missing: $required"
done
grep -Fq 'onlinePublishCenterSection' "$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift" || fail "online publish center is missing"
overview_sections="$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift"
primary_column="$(sed -n '/private var repositoryOverviewPrimaryColumn/,/private var repositoryOverviewContextColumn/p' "$overview_sections")"
context_column="$(sed -n '/private var repositoryOverviewContextColumn/,/private var repositoryOverviewLocalPreviewSection/p' "$overview_sections")"
for direct_primary in repositoryScanProgress onlinePublishCenterSection; do
  grep -Fq "$direct_primary" <<<"$primary_column" || fail "repository primary action is no longer directly reachable: $direct_primary"
done
if grep -Fq 'DisclosureGroup' <<<"$primary_column"; then
  fail "repository scan or online publish must not be folded into more tools"
fi
grep -Fq 'DisclosureGroup' <<<"$context_column" || fail "repository secondary tools must use the explicit more-tools disclosure"
grep -Fq 'repository-section-more-tools' <<<"$context_column" || fail "repository more-tools disclosure lost its accessibility identifier"
for direct_primary in repositoryScanProgress onlinePublishCenterSection; do
  if grep -Fq "$direct_primary" <<<"$context_column"; then
    fail "repository primary action is folded into more tools: $direct_primary"
  fi
done
for folded in Repository/RepositoryWorkspacePublishingSections.swift Repository/RepositoryWorkspaceLocalPreviewSection.swift; do
  if grep -Fq 'DisclosureGroup' "$VIEWS/$folded"; then fail "repository/release history must remain visible: $folded"; fi
done
history="$VIEWS/Publishing/ReleaseHistoryDetailView.swift"
grep -Fq 'releaseActionCommandDisclosure(item)' "$history" || fail "release history advanced commands are missing from the record row"
grep -Fq 'releaseActionButtons(item, entry: entry)' "$history" || fail "release history record actions are missing from the record row"
grep -Fq 'DisclosureGroup(' "$history" || fail "release history advanced commands must remain collapsible"
grep -Fq '@State private var expandedCommandActionIDs: Set<String> = []' "$history" || fail "release history commands must default collapsed"
grep -Fq '.accessibilityIdentifier("release-action-\(item.id)-advanced-commands")' "$history" || fail "release history advanced command accessibility identifier is missing"
record_card="$VIEWS/Publishing/ReleaseHistoryRecordCardSection.swift"
grep -Fq 'if !rollbackDraft.commandLines.isEmpty' "$record_card" || fail "rollback Git commands are missing from release records"
grep -Fq 'release-record-' "$record_card" || fail "rollback Git command accessibility identifier is missing"
grep -Fq 'advanced-commands' "$record_card" || fail "rollback Git command accessibility identifier is missing"
python3 - "$history" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
row = source.split("private func releaseActionRow", 1)[1].split("private func releaseActionPriorityBadge", 1)[0]
assert "DisclosureGroup" not in row, "the main release record row must not be folded"
PY
if grep -Fq 'repositoryActionsMenu' "$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift" || grep -Fq 'Menu {' "$VIEWS/Repository/RepositoryWorkspaceOverviewSections.swift"; then fail "repository primary actions returned to a hidden menu"; fi
echo "ui product-contract gate: source UI contracts passed (not a real UI smoke test)"
