#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-surface-map.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "screenshot surface map test: $*" >&2
  exit 1
}

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  cat >"$path" "$@"
}

create_fixture() {
  local root="$1"
  mkdir -p "$root"
  write_file "$root/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md" <<'EOF_MANIFEST'
# App Store Screenshot Manifest

| ID | Target file | Screen | Purpose | Status |
| --- | --- | --- | --- | --- |
| `writing` | `writing.png` | Writing workspace | Markdown editing, preview, metadata, and contextual writing actions. | Pending capture |
| `ai-chat` | `ai-chat.png` | AI assistant Inspector | Keep the article editor visible while showing conversation, context, quick prompts, and apply actions. | Pending capture |
| `sync-api-publish` | `sync-api-publish.png` | Sync workspace | GitHub/GitLab token check, remote conflict preview, direct API publish, and PR/MR flow. | Pending capture |
| `seo-social-preview` | `seo-social-preview.png` | SEO/social preview | Search, Open Graph, Twitter card, cache state, and manual refresh. | Pending capture |
| `deployment-status` | `deployment-status.png` | Deployment status | GitHub Pages/Actions, Netlify, Vercel, Cloudflare Pages, or custom endpoint validation. | Pending capture |
| `maintenance` | `maintenance.png` | Site maintenance | Calendar, taxonomy governance, stale articles, links, and operation log. | Pending capture |
| `general-drafts` | `general-drafts.png` | Cross-site copy | Copy an article from one publishing site to another. | Pending capture |
| `pro-settings` | `pro-settings.png` | Pro settings | Free quota, Pro unlock, purchase, and restore state. | Pending capture |
| `privacy-lock` | `privacy-lock.png` | Quick hide | Manually hidden workbench and private-content masking. | Pending capture |
EOF_MANIFEST

  write_file "$root/script/capture_app_screenshots.sh" <<'EOF_CAPTURE'
#!/usr/bin/env bash
required_ids=(writing ai-chat sync-api-publish seo-social-preview deployment-status maintenance general-drafts pro-settings privacy-lock)
FORCE_RELAUNCH=0
--force-relaunch
--auto-window
frontmost_app_window_id
AXWindowNumber
capture_current_app_window
screencapture -x -l
--auto-window with --real-data requires --only
--auto-window with --skip-build requires --only
pkill -TERM -x "$APP_PRODUCT"
PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO=1 PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE="${ONLY_ID:-writing}" ./PersonalSitePublisherMac
screen_guidance() {
  case "$1" in
    writing) echo "Show the writing workspace with editor, preview, metadata, and contextual writing actions." ;;
    ai-chat) echo "Keep the article editor visible while showing the AI assistant Inspector with conversation, context, quick prompts, and apply actions." ;;
    sync-api-publish) echo "Show GitHub/GitLab token check, remote conflict preview, direct API publish, and PR/MR controls." ;;
    seo-social-preview) echo "Show search/Open Graph/Twitter card previews, cache state, manual refresh, and external debug links." ;;
    deployment-status) echo "Show GitHub Pages/Actions, Netlify, Vercel, Cloudflare Pages, or custom endpoint validation status." ;;
    maintenance) echo "Show content calendar, taxonomy governance, stale articles, links, and operation log." ;;
    general-drafts) echo "Show cross-site copy across publishing sites with the copy to site action." ;;
    pro-settings) echo "Show free quota, Pro unlock, purchase, and restore state without real payment or account secrets." ;;
    privacy-lock) echo "Show the manually hidden workbench and private-content masking state." ;;
  esac
}
EOF_CAPTURE

  write_file "$root/script/build_and_run.sh" <<'EOF_BUILD'
#!/usr/bin/env bash
required_screenshot_surfaces=(writing ai-chat sync-api-publish seo-social-preview deployment-status maintenance general-drafts pro-settings privacy-lock)
--screenshot-demo [id]
--screenshot-surface <id>
--list-screenshot-surfaces
contains_screenshot_surface
PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO=1 PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE="$SCREENSHOT_SURFACE" ./PersonalSitePublisherMac
EOF_BUILD

  write_file "$root/Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift" <<'EOF_SWIFT'
struct MacMarkdownComposerView { let markdownBlocks = ""; let pasteAIPromptToClipboard = "" }
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift" <<'EOF_SWIFT'
let inspector = "WorkspaceTaskMetadataSection WorkspaceTaskSEOSection refreshSEOSocialPreview relatedArticleSuggestionSection"
// .accessibilityLabel("元数据标题")
// .accessibilityLabel("复制全部外部调试链接")
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" <<'EOF_SWIFT'
let aiChatInspector = "ai-assistant-inspector ai-assistant-composer .keyboardShortcut(.return, modifiers: [.command])"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorSections.swift" <<'EOF_SWIFT'
let aiChatSections = "AIChatConversationInspectorSection AIChatContextOverviewInspectorSection"
EOF_SWIFT
  write_file "$root/Sources/PublishingWorkbenchCore/Stores/WorkbenchAIStore.swift" <<'EOF_SWIFT'
let aiChatRoute = "openAIChatWorkspace isAIPublishingAssistantPresented = true"
EOF_SWIFT
  write_file "$root/Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift" <<'EOF_SWIFT'
let generalDraftService = "GeneralDraftLibraryReport publishingProfileCount purpose == .publishing"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/DetailContainerView.swift" <<'EOF_SWIFT'
let detail = "SiteMaintenanceDetailView GeneralDraftLibraryDetailView"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift" <<'EOF_SWIFT'
let maintenance = "SiteMaintenanceDetailView calendarSection linkAuditSection operationLogSection"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSectionGroups.swift" <<'EOF_SWIFT'
let maintenanceSections = "SiteMaintenanceCalendarSection SiteMaintenanceLinkAuditSection SiteMaintenanceOperationLogSection"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift" <<'EOF_SWIFT'
let generalDrafts = "GeneralDraftLibraryDetailView copyTargets 复制到站点"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" <<'EOF_SWIFT'
let repository = "RepositoryWorkspaceView"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift" <<'EOF_SWIFT'
let repositoryPublishing = "onlinePublishCenterSection remoteConflictPreview PR/MR"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift" <<'EOF_SWIFT'
let releaseHistory = "deploymentPollingSummary refreshDeploymentStatus GitHub Pages / Actions Netlify Vercel Cloudflare Pages"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/SettingsView.swift" <<'EOF_SWIFT'
let settings = "selectedSettingsTab ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .proSettings ? .pro"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift" <<'EOF_SWIFT'
let token = "TokenRepositoryTokenSection"
// .accessibilityHint("仅用于仓库创建、权限检查、提交、PR/MR 和回滚")
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/TokenSettingsView.swift" <<'EOF_SWIFT'
let tokenSettings = "deploymentProviderBinding"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift" <<'EOF_SWIFT'
let proSettings = "ProPurchaseRestoreSection ProQuotaSection"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Support/ScreenshotDemoSettingsPresenter.swift" <<'EOF_SWIFT'
let screenshotSettings = "ScreenshotDemoSettingsPresenter showSettingsWindow: requestedSurfaceFromEnvironment == .proSettings"
EOF_SWIFT
  write_file "$root/Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift" <<'EOF_SWIFT'
func testSnapshotBuildsSearchOpenGraphAndTwitterCards() {}
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift" <<'EOF_SWIFT'
func purchasePro(store: String) {}
func restorePro(store: String) {}
let storeKitMarkers = "Product.products(for: [productID]) Transaction.currentEntitlements"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/SharedViews.swift" <<'EOF_SWIFT'
let privacy = "PrivacyLockOverlay privacy-lock-overlay"
EOF_SWIFT
  write_file "$root/Sources/PersonalSitePublisherMac/Views/ContentView.swift" <<'EOF_SWIFT'
let privacyState = "isPrivacyLocked lockPrivacy(reason canUseProtectedWorkbench"
EOF_SWIFT
}

run_gate() {
  local root="$1"
  SCREENSHOT_SURFACE_ROOT="$root" bash "$PROJECT_ROOT/script/check_screenshot_surface_map.sh" >/dev/null
}

positive="$TMP_DIR/positive"
create_fixture "$positive"
run_gate "$positive" || fail "valid fixture should pass"

missing_manifest="$TMP_DIR/missing-manifest"
create_fixture "$missing_manifest"
perl -0pi -e 's/\| `ai-chat` \| `ai-chat\.png`[^\n]*\n//' "$missing_manifest/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md"
if run_gate "$missing_manifest" 2>/dev/null; then
  fail "missing manifest id should fail"
fi

missing_source_marker="$TMP_DIR/missing-source-marker"
create_fixture "$missing_source_marker"
perl -0pi -e 's/ai-assistant-composer//' "$missing_source_marker/Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift"
if run_gate "$missing_source_marker" 2>/dev/null; then
  fail "missing source marker should fail"
fi

missing_capture_marker="$TMP_DIR/missing-capture-marker"
create_fixture "$missing_capture_marker"
perl -0pi -e 's/GitHub\/GitLab token check//' "$missing_capture_marker/script/capture_app_screenshots.sh"
if run_gate "$missing_capture_marker" 2>/dev/null; then
  fail "missing capture guidance marker should fail"
fi

missing_build_marker="$TMP_DIR/missing-build-marker"
create_fixture "$missing_build_marker"
perl -0pi -e 's/--screenshot-surface <id>//' "$missing_build_marker/script/build_and_run.sh"
if run_gate "$missing_build_marker" 2>/dev/null; then
  fail "missing build/run screenshot surface marker should fail"
fi

missing_auto_capture="$TMP_DIR/missing-auto-capture"
create_fixture "$missing_auto_capture"
perl -0pi -e 's/--auto-window//g' "$missing_auto_capture/script/capture_app_screenshots.sh"
if run_gate "$missing_auto_capture" 2>/dev/null; then
  fail "missing auto-window capture marker should fail"
fi

echo "screenshot surface map test: fixture coverage passed"
