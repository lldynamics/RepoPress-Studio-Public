#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_MANIFEST_HELPER="$ROOT_DIR/script/release_evidence_source_manifest.py"

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

require_literal_source_manifest() {
  local relative_path="$1"
  local literal="$2"
  local message="$3"
  local expanded_paths=()
  local expanded_path
  while IFS= read -r expanded_path; do
    expanded_paths+=("$expanded_path")
  done < <(python3 "$SOURCE_MANIFEST_HELPER" "$relative_path" "$literal")
  require_literal_any_file "$literal" "$message" "${expanded_paths[@]}"
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
  "WorkspaceNavigationPresentation.commandMenuAdvancedItems" \
  "every advertised advanced workspace shortcut must remain available from the command menu"

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

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  "isCommandPalettePresented = false" \
  "quick hide must close the command palette"

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
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownTextView.swift" \
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
  ".accessibilityIdentifier(\"privacy-lock-overlay\")" \
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
  "PrivacyLockOverlay(store: store)" \
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

require_literal_source_manifest \
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
  ".workbenchTruncatedIdentity(displayTitle)" \
  "draft titles must keep their full hover and copy affordances"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  ".accessibilityLabel(\"全站图片优化\")" \
  "site-wide image optimization must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  ".accessibilityLabel(\"优化全站图片\")" \
  "site-wide image optimization menu must expose an accessibility label"

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
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerComponents.swift"

require_literal_any_file \
  ".accessibilityLabel(\"文章统计\")" \
  "markdown editor statistics must expose accessibility value" \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift" \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerComponents.swift" \
  "title: draft.title.trimmedForPublishing.nilIfEmpty" \
  "writing preview must include the current article title in its render input"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerComponents.swift" \
  "<header class=\"article-header\"><h1 class=\"article-title\">" \
  "writing preview must render the article title as a semantic heading"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerComponents.swift" \
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

require_literal_source_manifest \
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
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift"
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift"
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
  ".accessibilityIdentifier(\"workspace-sidebar\")" \
  "unified workspace sidebar must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
  ".accessibilityIdentifier(\"workspace-task-navigation\")" \
  "workspace task navigation must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceRailView.swift" \
  "List(selection: navigationSelection)" \
  "workspace task navigation must use native single-selection semantics"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift" \
  ".accessibilityLabel(\"AI 推荐指令\")" \
  "the single editor AI entry must expose a descriptive accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerToolbars.swift" \
  ".accessibilityValue(isSelectionAIActionRunning ? \"AI 处理中\" : \"\")" \
  "the single editor AI entry must expose its running state"

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
  "if knowledgeLibraryCommands != nil { return \"搜索资料库\" }" \
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

echo "accessibility gate: labels, values, hints, text editors, semantic knowledge headings, VoiceOver status announcements, selection traits, keyboard shortcuts, command routing, prominent-action contrast, first-run setup, status light, settings, editor, site starter, diff review, and publish recovery verified"
