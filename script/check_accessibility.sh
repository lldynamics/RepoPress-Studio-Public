#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "accessibility gate: $*" >&2
  exit 1
}

require_file() {
  local relative_path="$1"
  [[ -f "$ROOT_DIR/$relative_path" ]] || fail "missing required file: $relative_path"
}

require_literal() {
  local relative_path="$1"
  local literal="$2"
  local message="$3"
  require_file "$relative_path"
  grep -Fq "$literal" "$ROOT_DIR/$relative_path" || fail "$message"
}

require_absent_literal() {
  local relative_path="$1"
  local literal="$2"
  local message="$3"
  require_file "$relative_path"
  if grep -Fq "$literal" "$ROOT_DIR/$relative_path"; then
    fail "$message"
  fi
}

require_literal_any_file() {
  local literal="$1"
  local message="$2"
  shift 2
  local relative_path
  for relative_path in "$@"; do
    require_file "$relative_path"
    if grep -Fq "$literal" "$ROOT_DIR/$relative_path"; then
      return
    fi
  done
  fail "$message"
}

require_regex() {
  local relative_path="$1"
  local pattern="$2"
  local message="$3"
  require_file "$relative_path"
  grep -Eq "$pattern" "$ROOT_DIR/$relative_path" || fail "$message"
}

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "ForEach(WorkspaceNavigationPresentation.commandMenuItems)" \
  "workspace command menu must use the shared navigation presentation"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "KeyEquivalent(item.keyboardShortcutKey)" \
  "workspace command menu must use stable keyboard shortcut keys"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "WorkspaceNavigationPresentation.secondaryEntryItems" \
  "the Go menu must expose every secondary workspace without an extra advanced submenu"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "workspaceCommandPaletteAction?.openMaintenance()" \
  "site maintenance must remain directly reachable from the Go menu"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "workspaceCommandPaletteAction?.openReleaseHistory()" \
  "release history must remain directly reachable from the Publish menu"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "CommandGroup(replacing: .newItem)" \
  "the File menu must expose the app's new-article command"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "CommandGroup(after: .pasteboard)" \
  "the Edit menu must contain the app's find and Markdown commands"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkbenchVisualStyle.swift" \
  "func workbenchProminentActionStyle(" \
  "prominent actions must use the shared high-contrast action style"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  ".tint(WorkbenchTheme.navigationSelection)" \
  "global navigation controls must follow the user's macOS accent"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AdvancedWorkspaceMenu.swift" \
  "ForEach(WorkspaceNavigationPresentation.secondaryEntryItems)" \
  "flattened workspace menu must expose every advanced destination as a labeled button"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  ".keyboardShortcut(\"l\", modifiers: [.command, .control])" \
  "quick hide must have a keyboard shortcut"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  ".focusedSceneValue(" \
  "content view must expose focused command actions"

unexpected_publish_execution_references="$(
  grep -R -nE \
    '(writeSelectedDraftToLocalRepository|commitSelectedDraftUsingPreferredStrategy|commitSelectedDraftDirectly|commitSelectedDraftToReviewBranch|publishSelectedDraftOnlineUsingPreferredStrategy|writeBatchReadyDraftsToLocalRepository|publishBatchReadyDraftsOnlineUsingPreferredStrategy)\(' \
    "$ROOT_DIR/Sources/PersonalSitePublisherMac" \
    --include='*.swift' \
    | grep -v '/Views/PublishDrawerView.swift:' \
    || true
)"
if [[ -n "$unexpected_publish_execution_references" ]]; then
  printf '%s\n' "$unexpected_publish_execution_references" >&2
  fail "desktop publishing mutations must remain isolated to PublishDrawerView"
fi

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  "modalPresentation.dismiss()" \
  "quick hide must close all transient presentations"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WritingDraftListComponents.swift" \
  "display.title.nilIfEmpty" \
  "private draft rows must render the privacy-safe title"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceCommandPalette.swift" \
  "matchesPrivacyProtectedDraftSearch(" \
  "command palette search must honor private-content masking"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  "@FocusState private var isKeyboardFocused" \
  "status announcements must not steal keyboard focus"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MarkdownEditorAppKitViews.swift" \
  "heightInvalidationWorkItem" \
  "long-document height measurement must coalesce typing updates"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  ".accessibilityIdentifier(\"workspace-inspector-toggle\")" \
  "workspace inspector toggle must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MetadataColumn.swift" \
  ".accessibilityIdentifier(\"workspace-inspector\")" \
  "workspace inspector must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift" \
  ".focusedSceneValue(\\.markdownEditorCommandActions" \
  "markdown composer must expose focused editor commands"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MarkdownEditorEnhancementPanels.swift" \
  ".accessibilityLabel(\"站点片段名称\")" \
  "site snippet name field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MarkdownEditorEnhancementPanels.swift" \
  ".accessibilityLabel(\"站点片段 Markdown 内容\")" \
  "site snippet editor must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  ".keyboardShortcut(\"[\", modifiers: [.command])" \
  "draft history backward navigation must keep its keyboard shortcut"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  ".keyboardShortcut(\"]\", modifiers: [.command])" \
  "draft history forward navigation must keep its keyboard shortcut"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "EditorAccessibilityAnnouncementCenter.announce(" \
  "draft history navigation must announce the destination article"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".keyboardShortcut(.return, modifiers: [])" \
  "quick-hide overlay must support return-key return"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityIdentifier(\"quick-hide-overlay\")" \
  "quick-hide overlay must expose an accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityLabel(status.title)" \
  "quick-hide overlay must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityHint(status.detail)" \
  "quick-hide overlay must expose an accessibility hint"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  "ProtectedSettingsView" \
  "settings scene must be wrapped by privacy protection"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  ".disabled(!store.canUseProtectedWorkbench)" \
  "settings scene must disable controls while workbench content is hidden"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  "QuickHideOverlay(store: store)" \
  "settings scene must show the quick-hide overlay"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTopBarView.swift" \
  ".accessibilityLabel(\"发布状态\")" \
  "publishing status control must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTopBarView.swift" \
  ".accessibilityValue(\"\(toolbarStatus.area.title)：\(toolbarStatus.value)\")" \
  "publishing status control must expose its current priority status"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTopBarView.swift" \
  "点击查看状态和发布操作。" \
  "publishing status control must explain the merged status and publishing entry"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  ".keyboardShortcut(.return, modifiers: [.command])" \
  "AI assistant send action must keep a keyboard shortcut"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  ".accessibilityIdentifier(\"ai-assistant-inspector\")" \
  "AI assistant inspector must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  ".accessibilityLabel(\"AI 助手\")" \
  "AI assistant inspector must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  ".accessibilityLabel(\"AI 消息\")" \
  "AI assistant composer must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  ".accessibilityIdentifier(\"ai-assistant-composer\")" \
  "AI assistant composer must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  ".allowsHitTesting(false)" \
  "AI assistant composer decoration must not intercept text input"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  ".disabled(isComposerInputUnavailable)" \
  "AI assistant input must use its own availability state"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift" \
  "&& !isAIKeyMissing" \
  "a missing AI key may block sending but must not block composing text"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityValue(value)" \
  "metric tiles must expose their current value"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  "func workbenchTruncatedIdentity(_ value: String, lineLimit: Int = 1)" \
  "truncated titles and paths must use the shared readable identity treatment"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".truncationMode(.middle)" \
  "truncated identities must preserve both ends of paths and titles"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".help(value)" \
  "truncated identities must reveal their complete value on hover"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityAction(named: Text(\"复制完整内容\"), copyValue)" \
  "truncated identities must expose a copy action to assistive technologies"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  "struct WorkbenchPathIdentity: View" \
  "path-only rows must expose a high-contrast file-name identity"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceChangeSections.swift" \
  "WorkbenchPathIdentity(path: file.path)" \
  "repository change rows must not rely on a low-contrast path as their only identity"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WritingDraftListComponents.swift" \
  ".workbenchTruncatedIdentity(presentation.title)" \
  "draft titles must keep their full hover and copy affordances"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  ".accessibilityIdentifier(\"image-workbench\")" \
  "image workbench must expose a stable root accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  "ForEach(ImageWorkbenchBatchAction.allActions)" \
  "every primary image operation must remain visible instead of being hidden in a menu"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  ".accessibilityIdentifier(action.accessibilityIdentifier)" \
  "every visible image operation must expose its stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchBatchSupport.swift" \
  "\"image-action-\(id)\"" \
  "image operation identifiers must be derived from stable action IDs"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  "private var optimizationMenu" \
  "primary image operations must not be hidden in the legacy optimization menu"

for repository_image_identifier in \
  repository-image-browser \
  repository-image-target-picker \
  repository-image-open-target-article \
  repository-image-search \
  repository-image-filter \
  repository-image-list \
  repository-image-detail \
  repository-image-attach \
  repository-image-preview \
  repository-image-reveal \
  repository-image-copy-path; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/RepositoryImageBrowserView.swift" \
    ".accessibilityIdentifier(\"$repository_image_identifier\")" \
    "repository image browser control must expose a unique identifier: $repository_image_identifier"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryImageBrowserView.swift" \
  ".accessibilityIdentifier(\"repository-image-open-article-\(reference.draftID.uuidString)\")" \
  "each repository image reference must expose a unique open-article accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentHealthDetailView.swift" \
  "content-health-select-article-\(row.draftID.uuidString)" \
  "each problem article in Checks must expose a unique selection accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentHealthDetailView.swift" \
  "content-health-open-article-\(selectedRow.draftID.uuidString)" \
  "each selected problem article in Checks must expose a unique open-article accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift" \
  ".accessibilityLabel(\"发布流程\")" \
  "publish drawer flow must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerComponents.swift" \
  ".accessibilityValue(value)" \
  "publish drawer stats and rows must expose current values"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SettingsProfileBar.swift" \
  ".accessibilityLabel(\"站点配置名称\")" \
  "settings site configuration name field must expose an accessibility label"

require_literal_any_file \
  ".accessibilityLabel(\"仓库访问令牌\")" \
  "settings repository access token field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/TokenSettingsView.swift" \
  "Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"AI API Key\")" \
  "settings AI API key field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/AISettingsView.swift" \
  "Sources/PersonalSitePublisherMac/Views/AIKeychainSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"遮挡私密文章内容和路径，标题仍显示\")" \
  "settings private-content masking toggle must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/PrivacySettingsView.swift" \
  "Sources/PersonalSitePublisherMac/Views/PrivacySettingsVisibilitySection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"元数据标题\")" \
  "article inspector title field must expose a distinct metadata accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift"

require_literal_any_file \
  ".accessibilityLabel(\"图片 Alt 文本\")" \
  "article inspector image alt field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift"

require_literal_any_file \
  ".accessibilityLabel(\"查找文本\")" \
  "markdown find field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift" \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerFindReplace.swift"

require_literal_any_file \
  ".accessibilityLabel(\"文章统计\")" \
  "markdown editor statistics must expose accessibility value" \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift" \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerPreview.swift" \
  "title: draft.title.trimmedForPublishing.nilIfEmpty" \
  "writing preview must include the current article title in its render input"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerPreview.swift" \
  "<header class=\"article-header\"><h1 class=\"article-title\">" \
  "writing preview must render the article title as a semantic heading"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerPreview.swift" \
  "<title>\\(escapedTitle)</title>" \
  "writing preview HTML must expose the article title as its document title"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownTextView.swift" \
  "textView.setAccessibilityLabel(String(localized: \"Markdown 文档编辑器\"))" \
  "native markdown text editor must expose a descriptive accessibility name"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownTextView.swift" \
  "requestKeyboardFocus(focusRequest, in: textView)" \
  "markdown focus requests must cross the SwiftUI-AppKit bridge"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownTextView.swift" \
  "window.makeFirstResponder(textView)" \
  "markdown focus requests must make the native editor first responder"

require_literal_any_file \
  ".accessibilityLabel(\"建站模式\")" \
  "site starter mode picker must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/SiteStarterWorkspaceView.swift" \
  "Sources/PersonalSitePublisherMac/Views/SiteStarterWorkspaceComponents.swift"

require_literal_any_file \
  ".accessibilityLabel(\"GitHub Owner\")" \
  "site starter GitHub owner field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/SiteStarterWorkspaceView.swift" \
  "Sources/PersonalSitePublisherMac/Views/SiteStarterWorkspaceComponents.swift"

require_literal_any_file \
  ".accessibilityLabel(\"启用自动检查远端\")" \
  "repository remote auto-check toggle must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"远端 diff 预览\")" \
  "remote diff preview must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceRemoteChangesSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"复制远端 diff\")" \
  "remote diff copy action must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceRemoteChangesSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"复制发布恢复包\")" \
  "release recovery actions must expose accessibility labels" \
  "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift" \
  "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift" \
  ".accessibilityLabel(\"搜索草稿\")" \
  "draft search field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  ".accessibilityLabel(\"搜索文章或输入结构化条件\")" \
  "structured full-text search field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  ".accessibilityLabel(\"保存的全文搜索查询\")" \
  "saved full-text queries must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  ".onKeyPress(.downArrow)" \
  "full-text search must support down-arrow result selection"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  ".onKeyPress(.upArrow)" \
  "full-text search must support up-arrow result selection"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  ".onExitCommand" \
  "full-text search must close with Escape"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  ".accessibilityAddTraits(selectedHitID == hit.id ? .isSelected : [])" \
  "full-text search must expose its keyboard selection to accessibility"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  "Button(\"清除条件\"" \
  "empty full-text search results must offer to clear filters"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift" \
  "Button(\"搜索全部站点\"" \
  "empty full-text search results must offer an all-sites search"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/DraftVersionComparisonView.swift" \
  "Text(\"恢复左侧版本 · \\(" \
  "version comparison must identify the fixed left-side restore source"

sheet_action_files=(
  "Sources/PersonalSitePublisherMac/Views/DraftFullTextSearchPanel.swift"
  "Sources/PersonalSitePublisherMac/Views/DraftVersionComparisonView.swift"
  "Sources/PersonalSitePublisherMac/Views/AIChatDraftDiffPreview.swift"
  "Sources/PersonalSitePublisherMac/Views/MarkdownEditorEnhancementPanels.swift"
  "Sources/PersonalSitePublisherMac/Views/KnowledgeMetadataEditorView.swift"
  "Sources/PersonalSitePublisherMac/Views/KnowledgeAnnotationViews.swift"
  "Sources/PersonalSitePublisherMac/Views/ContentMigrationAssistantView.swift"
  "Sources/PersonalSitePublisherMac/Views/KnowledgeImportAssistantView.swift"
  "Sources/PersonalSitePublisherMac/Views/KnowledgeRecycleBinView.swift"
  "Sources/PersonalSitePublisherMac/Views/FirstRunSetupView.swift"
  "Sources/PersonalSitePublisherMac/Views/SiteKindChangeConfirmationView.swift"
  "Sources/PersonalSitePublisherMac/Views/RemoteArticleImportPreviewView.swift"
  "Sources/PersonalSitePublisherMac/Views/RemoteRepositoryCreationConfirmationView.swift"
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerComponents.swift"
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchBatchSupport.swift"
  "Sources/PersonalSitePublisherMac/Views/KnowledgeLibraryRestorePreviewView.swift"
)
for sheet_action_file in "${sheet_action_files[@]}"; do
  require_literal \
    "$sheet_action_file" \
    ".keyboardShortcut(.cancelAction)" \
    "submission sheet must support Escape: $sheet_action_file"
  require_literal \
    "$sheet_action_file" \
    ".keyboardShortcut(.defaultAction)" \
    "submission sheet must support Return: $sheet_action_file"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift" \
  ".keyboardShortcut(.cancelAction)" \
  "publish drawer must support Escape"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift" \
  "@Environment(\\.accessibilityReduceMotion)" \
  "publish drawer disclosure motion must respect Reduce Motion"

for publish_drawer_identifier in \
  publish-drawer-header \
  publish-drawer-action-save-local \
  publish-drawer-action-publish-all \
  publish-drawer-action-publish-current \
  publish-drawer-review-disclosure \
  publish-drawer-diff; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift" \
    "\"$publish_drawer_identifier\"" \
    "publish drawer must expose $publish_drawer_identifier"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerPresentationComponents.swift" \
  ".accessibilityIdentifier(\"publish-drawer-check-results\")" \
  "publish drawer must expose its check results"

require_literal_any_file \
  ".keyboardShortcut(.defaultAction)" \
  "publish drawer must expose a visible Return action through its composed controls" \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerPresentationComponents.swift" \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerComponents.swift"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTopBarView.swift" \
  ".accessibilityLabel(\"切换个人网站\")" \
  "personal website menu must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/LocalSitePreviewToolbarControl.swift" \
  ".accessibilityLabel(\"本地预览\")" \
  "local preview toolbar control must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/LocalSitePreviewToolbarControl.swift" \
  ".accessibilityValue(statusTitle)" \
  "local preview toolbar control must expose its current runtime status"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift" \
  ".accessibilityLabel(\"启用部署轮询\")" \
  "deployment polling toggle must expose an accessibility label"

require_literal_any_file \
  ".accessibilityLabel(\"复制全部外部调试链接\")" \
  "social external debug copy-all action must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/FirstRunSetupView.swift" \
  ".accessibilityLabel(\"首次设置\")" \
  "first-run setup must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/FirstRunSetupView.swift" \
  ".accessibilityLabel(\"设置进度\")" \
  "first-run setup must expose accessible progress"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/FirstRunSetupView.swift" \
  ".accessibilityHint(\"选择当前网站使用的静态站点生成器\")" \
  "first-run generator picker must expose an accessibility hint"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/FirstRunSetupView.swift" \
  ".keyboardShortcut(.defaultAction)" \
  "first-run setup must provide a default keyboard action"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  ".accessibilityElement(children: .contain)" \
  "unified workspace sidebar must own its identifier without overwriting descendants"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  ".accessibilityIdentifier(\"workspace-sidebar\")" \
  "unified workspace sidebar must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
  ".accessibilityElement(children: .contain)" \
  "workspace task navigation must own its identifier without overwriting buttons"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
  ".accessibilityIdentifier(\"workspace-task-navigation\")" \
  "workspace task navigation must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
  ".accessibilityAddTraits(isSelected ? .isSelected : [])" \
  "workspace task navigation buttons must expose single-selection semantics"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
  '.accessibilityIdentifier("workspace-sidebar-\(section.rawValue)")' \
  "workspace task navigation buttons must expose stable accessibility identifiers"

for workspace_section in writing library rss sync contentHealth; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
    "sectionButton(.$workspace_section" \
    "workspace task navigation must keep the $workspace_section entry"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RSSReaderView.swift" \
  '.accessibilityIdentifier("rss-reader-sidebar")' \
  "RSS subscriptions must remain inside the main workspace sidebar"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RSSReaderView.swift" \
  '.accessibilityIdentifier("rss-reader-workspace")' \
  "RSS articles must remain inside the main workspace content area"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  'openWindow(id: "rss-reader")' \
  "RSS must not reopen as an auxiliary window"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  'Window("RSS 阅读器"' \
  "RSS must not declare a separate scene"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
  "sectionButton(.images" \
  "image resources must remain contextual to the site instead of returning to primary navigation"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift" \
  '.accessibilityIdentifier("repository-action-open-images")' \
  "site workspace must expose the contextual image resources entry"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  "WorkspaceQuickSearchView(" \
  "operational workspaces must keep quick article search in the sidebar"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  "repositoryContextStage: shell.selectedSection == .sync" \
  "repository navigation must be injected below search only for the sync workspace"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  "imageWorkbenchContextStage: shell.selectedSection == .images" \
  "image-workbench navigation must be injected below search only for the image workspace"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceContextSidebarView.swift" \
  "contentHealthFilter: shell.selectedSection == .contentHealth" \
  "content-health navigation must be injected below search only for the health workspace"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  ".accessibilityIdentifier(\"repository-sidebar-stage-navigation\")" \
  "repository overview, changes and history navigation must remain accessible below search"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  "repositoryStageButton(item, stage: stage)" \
  "repository stages must remain separate full-width sidebar buttons"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  '"repository-sidebar-stage-\(item.rawValue)"' \
  "repository stage buttons must expose stable identifiers"

for operational_navigation_identifier in \
  image-sidebar-stage-navigation \
  content-health-sidebar-stage-navigation; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
    ".accessibilityIdentifier(\"$operational_navigation_identifier\")" \
    "operational stage navigation must expose $operational_navigation_identifier"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceGitManagementSection.swift" \
  ".accessibilityIdentifier(\"repository-section-git-management\")" \
  "repository overview must expose repository-section-git-management"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceGitManagementSection.swift" \
  ".accessibilityLabel(switchBranchLabel(branch.name))" \
  "repository branch controls must identify their target branch"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceGitManagementSection.swift" \
  "store.repository.scanState.isScanning" \
  "repository branch operations must not race repository scans"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  '"image-sidebar-stage-\(item.rawValue)"' \
  "image-workbench stages must remain separate full-width sidebar buttons"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  '"content-health-sidebar-stage-\(item.rawValue)"' \
  "content-health stages must remain separate full-width sidebar buttons"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentHealthDetailView.swift" \
  "pageModePicker" \
  "content health must not restore duplicate center-stage navigation"

for unfolded_health_file in \
  Sources/PersonalSitePublisherMac/Views/SiteMaintenanceSnapshotHeader.swift \
  Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift; do
  require_absent_literal \
    "$unfolded_health_file" \
    "Menu {" \
    "site-maintenance actions must remain visible instead of hidden in menus: $unfolded_health_file"
done

for unfolded_health_file in \
  Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift \
  Sources/PersonalSitePublisherMac/Views/OnlineSiteInspectionSection.swift; do
  require_absent_literal \
    "$unfolded_health_file" \
    "DisclosureGroup" \
    "site-maintenance metrics must remain visible instead of folded: $unfolded_health_file"
done

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" \
  "repositoryStageNavigation" \
  "repository navigation must not return to the top of the center content"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceContextNavigation.swift" \
  "case checks" \
  "repository navigation must not restore the unreachable duplicate checks stage"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" \
  "GitConflictResolverSheet(" \
  "repository workspace must not expose a conflict resolver backed by empty data"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift" \
  "repositoryPublishPreviewSection" \
  "repository workspace must leave publish preview and final confirmation to PublishDrawer"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift" \
  "onlinePublishCenterSection" \
  "repository overview must render the online publish center instead of leaving it as dead UI"

for unfolded_repository_file in \
  Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift \
  Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift \
  Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceLocalPreviewSection.swift \
  Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift \
  Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDeploymentDebugSection.swift \
  Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift; do
  require_absent_literal \
    "$unfolded_repository_file" \
    "DisclosureGroup" \
    "repository and release-history functions must remain visible instead of folded: $unfolded_repository_file"
done

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift" \
  "repositoryActionsMenu" \
  "repository primary actions must not return to the legacy repository actions menu"

require_absent_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift" \
  "Menu {" \
  "repository overview actions must remain visible instead of being hidden in a menu"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" \
  ".accessibilityIdentifier(\"repository-workspace\")" \
  "repository workspace must expose a stable root accessibility identifier"

for repository_primary_identifier in \
  repository-primary-actions \
  repository-action-select-folder \
  repository-action-scan \
  repository-action-import \
  repository-action-migrate \
  repository-action-open-images \
  repository-action-open-publish \
  repository-section-summary \
  repository-section-information; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceOverviewSections.swift" \
    ".accessibilityIdentifier(\"$repository_primary_identifier\")" \
    "repository overview must expose $repository_primary_identifier"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift" \
  ".accessibilityIdentifier(\"repository-section-online-publish\")" \
  "repository online publish section must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift" \
  ".accessibilityIdentifier(\"repository-section-auto-sync\")" \
  "repository auto-sync section must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceLocalPreviewSection.swift" \
  ".accessibilityIdentifier(\"repository-section-local-preview\")" \
  "repository local-preview section must expose a stable accessibility identifier"

for repository_publishing_identifier in \
  repository-section-sync-plan \
  repository-section-path-rules; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspacePublishingSections.swift" \
    ".accessibilityIdentifier(\"$repository_publishing_identifier\")" \
    "repository publishing support must expose $repository_publishing_identifier"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceRemoteChangesSection.swift" \
  ".accessibilityIdentifier(\"repository-section-remote-changes\")" \
  "repository remote changes must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceChangeSections.swift" \
  ".accessibilityIdentifier(\"repository-section-local-changes\")" \
  "repository local changes must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift" \
  ".accessibilityIdentifier(\"repository-section-release-history\")" \
  "repository release history must expose a stable accessibility identifier"

for quick_search_identifier in \
  workspace-quick-search \
  workspace-quick-search-field \
  repository-sidebar-stage-navigation \
  workspace-quick-search-results; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
    ".accessibilityIdentifier(\"$quick_search_identifier\")" \
    "workspace quick search must expose $quick_search_identifier"
done

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  "store.matchesPrivacyProtectedDraftSearch" \
  "workspace quick search must preserve private-content search policy"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceQuickSearchView.swift" \
  "store.focusDraft(draftID, section: .writing)" \
  "workspace quick search results must open the selected article"

require_literal \
  "UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift" \
  "testOperationalSidebarQuickSearchIdentifiersRemainUnique" \
  "runtime accessibility coverage must verify operational sidebar quick search"

require_literal \
  "UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift" \
  "testRepositoryWorkspaceIdentifiersRemainUniqueAcrossAllStages" \
  "runtime accessibility coverage must verify repository controls across all stages"

require_literal \
  "UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift" \
  "testImageWorkbenchIdentifiersRemainUniqueAndDoNotOverrideChildControls" \
  "runtime accessibility coverage must verify every image-workbench stage"

require_literal \
  "UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift" \
  "testContentHealthIdentifiersRemainUniqueAcrossAllStages" \
  "runtime accessibility coverage must verify every content-health stage"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/RepositoryImageBrowserView.swift" \
  "RepositoryAccessibilityIdentifier.token(for: asset.repositoryPath)" \
  "repository-image rows must not expose raw repository paths in accessibility identifiers"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WritingDraftColumn.swift" \
  'Label("新建", systemImage: "plus")' \
  "writing create menu must keep its visible title and icon"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WritingDraftColumn.swift" \
  ".labelStyle(.titleAndIcon)" \
  "writing create menu must not collapse to an icon-only label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WritingDraftColumn.swift" \
  ".accessibilityIdentifier(\"writing-create-menu\")" \
  "writing create menu must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WritingDraftColumn.swift" \
  ".accessibilityIdentifier(\"writing-draft-search\")" \
  "writing search field must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WritingDraftColumn.swift" \
  ".accessibilityIdentifier(\"writing-draft-list\")" \
  "writing list must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeSourceListColumn.swift" \
  ".accessibilityIdentifier(\"knowledge-source-search\")" \
  "knowledge search field must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeSourceListColumn.swift" \
  ".accessibilityIdentifier(\"knowledge-document-list\")" \
  "knowledge document list must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeLibraryDetailView.swift" \
  ".accessibilityElement(children: .contain)" \
  "knowledge detail must contain descendants without overwriting their identifiers"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeLibraryDetailView.swift" \
  ".accessibilityLabel(document.title)" \
  "knowledge detail title must expose the selected document title"

for knowledge_detail_identifier in \
  knowledge-library-detail \
  knowledge-library-detail-title \
  knowledge-library-reader \
  knowledge-library-inspector-toggle \
  knowledge-library-pin-toggle \
  knowledge-library-actions-menu \
  knowledge-library-import-button \
  knowledge-library-content-presentation-picker \
  knowledge-library-reclean-button; do
  require_literal \
    "Sources/PersonalSitePublisherMac/Views/KnowledgeLibraryDetailView.swift" \
    ".accessibilityIdentifier(\"$knowledge_detail_identifier\")" \
    "knowledge detail must expose the $knowledge_detail_identifier accessibility identifier"
done

require_literal \
  "UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift" \
  "testSidebarIdentifiersRemainUniqueAcrossWritingAndLibrary" \
  "runtime accessibility identifier uniqueness must remain covered by XCUI"

require_literal \
  "UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift" \
  "testKnowledgeDetailIdentifiersRemainUniqueAndActionSpecific" \
  "runtime knowledge detail identifier uniqueness must remain covered by XCUI"

require_literal \
  "UITests/WorkspaceAccessibilityUITests/WorkspaceAccessibilityUITests.swift" \
  "testImageWorkbenchIdentifiersRemainUniqueAndDoNotOverrideChildControls" \
  "runtime image workbench identifier uniqueness must remain covered by XCUI"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift" \
  ".accessibilityLabel(\"AI 常用操作\")" \
  "the single editor AI entry must expose a descriptive accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift" \
  ".accessibilityValue(isSelectionAIActionRunning ? \"AI 处理中\" : \"\")" \
  "the single editor AI entry must expose its running state"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTopBarView.swift" \
  "label.labelStyle(.titleAndIcon)" \
  "workspace toolbar actions must show text when the layout has room"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTopBarView.swift" \
  "@Environment(\\.isFocused) private var isFocused" \
  "workspace toolbar actions must expose a visible keyboard focus state"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkbenchVisualStyle.swift" \
  "struct WorkbenchFocusRingButtonStyle: ButtonStyle" \
  "custom/plain buttons must retain a visible keyboard focus ring"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift" \
  "editorActionGroup(showsTitle: true)" \
  "editor actions must prefer readable text labels before the compact icon fallback"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift" \
  ".buttonStyle(WorkbenchFocusRingButtonStyle())" \
  "formatting toolbar buttons must expose a visible keyboard focus state"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MarkdownEditorComfortControl.swift" \
  "Label(\"编辑显示与辅助功能\", systemImage: \"textformat.size.smaller\")" \
  "editor display accessibility control must expose text when space permits"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift" \
  ".accessibilityAddTraits(editorDisplayMode == mode ? .isSelected : [])" \
  "editor display modes must expose selected accessibility traits"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentHealthDetailView.swift" \
  ".accessibilityAddTraits(isSelected ? .isSelected : [])" \
  "content health article selection must expose selected accessibility traits"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeLibraryDetailView.swift" \
  ".accessibilityHeading(accessibilityHeadingLevel(level))" \
  "knowledge reader headings must expose semantic VoiceOver heading levels"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeMetadataEditorView.swift" \
  ".accessibilityLabel(\"标题\")" \
  "knowledge metadata title field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeMetadataEditorView.swift" \
  ".accessibilityLabel(\"作者\")" \
  "knowledge metadata authors field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeMetadataEditorView.swift" \
  ".accessibilityLabel(\"语言\")" \
  "knowledge metadata language field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeMetadataEditorView.swift" \
  ".accessibilityLabel(\"标签\")" \
  "knowledge metadata tags field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeMetadataEditorView.swift" \
  ".accessibilityLabel(\"摘要\")" \
  "knowledge metadata summary editor must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeAnnotationViews.swift" \
  ".accessibilityLabel(\"引用文字（可选）\")" \
  "knowledge annotation quote editor must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeAnnotationViews.swift" \
  ".accessibilityLabel(\"笔记\")" \
  "knowledge annotation note editor must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/KnowledgeSourceListColumn.swift" \
  ".focusedSceneValue(\.knowledgeLibraryCommandActions" \
  "knowledge library must expose focused keyboard command actions"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/EditorCenterColumn.swift" \
  "EditorAccessibilityAnnouncementCenter.announce(message)" \
  "knowledge search and import status changes must be announced to VoiceOver"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift" \
  "if knowledgeLibraryCommands != nil { return String(localized: \"搜索资料库\") }" \
  "command-f must route to knowledge search while the library is active"

textfield_gaps="$(
  perl -0ne 'while(/TextField\([^\n]*(?:\n[^\n]*){0,8}/g){$m=$&; if($m !~ /accessibilityLabel/){$prefix=substr($_,0,pos($_)); $line=1+($prefix=~tr/\n//); print "$ARGV:$line\n"}}' \
    "$ROOT_DIR"/Sources/PersonalSitePublisherMac/Views/*.swift
)"
[[ -z "$textfield_gaps" ]] || fail "text fields missing accessibility labels: $textfield_gaps"

texteditor_gaps="$(
  perl -0ne 'while(/TextEditor\([^\n]*(?:\n[^\n]*){0,14}/g){$m=$&; if($m !~ /accessibilityLabel/){$prefix=substr($_,0,pos($_)); $line=1+($prefix=~tr/\n//); print "$ARGV:$line\n"}}' \
    "$ROOT_DIR"/Sources/PersonalSitePublisherMac/Views/*.swift
)"
[[ -z "$texteditor_gaps" ]] || fail "text editors missing accessibility labels: $texteditor_gaps"

prominent_style_gaps="$(
  rg -n 'buttonStyle\(\.borderedProminent\)' \
    "$ROOT_DIR"/Sources/PersonalSitePublisherMac/Views \
    --glob '!WorkbenchVisualStyle.swift' || true
)"
[[ -z "$prominent_style_gaps" ]] || fail "prominent buttons bypassing the shared high-contrast style: $prominent_style_gaps"

echo "accessibility gate: labels, values, hints, text editors, semantic knowledge headings, VoiceOver status announcements, selection traits, keyboard shortcuts, command routing, visible focus states, responsive text labels, prominent-action contrast, first-run setup, status light, settings, editor, site starter, diff review, and publish recovery verified"
