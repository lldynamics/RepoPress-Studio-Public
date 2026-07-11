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
  ".keyboardShortcut(\"l\", modifiers: [.command, .control])" \
  "privacy lock must have a keyboard shortcut"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ContentView.swift" \
  ".focusedSceneValue(" \
  "content view must expose focused command actions"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift" \
  ".focusedSceneValue(\\.markdownEditorCommandActions" \
  "markdown composer must expose focused editor commands"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".keyboardShortcut(.return, modifiers: [])" \
  "privacy lock overlay must support return-key unlock"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityIdentifier(\"privacy-lock-overlay\")" \
  "privacy lock overlay must expose an accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityLabel(status.title)" \
  "privacy lock overlay must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityHint(status.detail)" \
  "privacy lock overlay must expose an accessibility hint"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  "ProtectedSettingsView" \
  "settings scene must be wrapped by privacy protection"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  ".disabled(!store.canUseProtectedWorkbench)" \
  "settings scene must disable controls while privacy locked"

require_literal \
  "Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift" \
  "PrivacyLockOverlay(store: store)" \
  "settings scene must show the privacy lock overlay"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift" \
  ".accessibilityLabel(\"工作台状态\")" \
  "workbench status control must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift" \
  ".accessibilityValue(\"仓库、当前文章和部署历史\")" \
  "workbench status control must expose a concise accessibility value"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift" \
  ".help(\"查看仓库、当前文章和部署历史的独立状态\")" \
  "workbench status control must keep long status detail out of the VoiceOver hint"

require_literal_source_manifest \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  ".keyboardShortcut(.return, modifiers: [.command])" \
  "AI chat send action must keep a keyboard shortcut"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  ".accessibilityIdentifier(\"ai-chat-workspace\")" \
  "AI chat workspace must expose a stable accessibility identifier"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  ".accessibilityLabel(\"AI 对话工作区\")" \
  "AI chat workspace must expose an accessibility label"

require_literal_source_manifest \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  ".accessibilityIdentifier(\"ai-chat-composer\")" \
  "AI chat composer must expose a stable accessibility identifier"

require_literal_source_manifest \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  ".accessibilityLabel(\"AI 对话输入\")" \
  "AI chat composer must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  ".accessibilityLabel(\"AI 对话标题\")" \
  "AI chat title field must expose an accessibility label"

require_literal_any_file \
  ".accessibilityLabel(\"复制消息\")" \
  "AI chat message action buttons must expose accessibility labels" \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceComponents.swift"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SharedViews.swift" \
  ".accessibilityValue(value)" \
  "metric tiles must expose their current value"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  ".accessibilityHint(\"拖入图片文件到此处\")" \
  "image workbench drop target must expose an accessibility hint"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ImageWorkbenchView.swift" \
  ".accessibilityLabel(\"图片 Alt 文本\")" \
  "image workbench alt text field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift" \
  ".accessibilityLabel(\"发布流程\")" \
  "publish drawer flow must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift" \
  ".accessibilityValue(value)" \
  "publish drawer stats and rows must expose current values"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/SettingsProfileBar.swift" \
  ".accessibilityLabel(\"Profile 名称\")" \
  "settings profile name field must expose an accessibility label"

require_literal_any_file \
  ".accessibilityLabel(\"仓库访问 Token\")" \
  "settings repository token field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/TokenSettingsView.swift" \
  "Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"AI API Key\")" \
  "settings AI API key field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/AISettingsView.swift" \
  "Sources/PersonalSitePublisherMac/Views/AIKeychainSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"启动时显示隐私界面遮罩\")" \
  "settings privacy toggle must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/PrivacySettingsView.swift" \
  "Sources/PersonalSitePublisherMac/Views/PrivacySettingsLockSection.swift"

require_literal_any_file \
  ".accessibilityLabel(\"文章标题\")" \
  "article inspector title field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift" \
  "Sources/PersonalSitePublisherMac/Views/EditorInspectorSections.swift"

require_literal_any_file \
  ".accessibilityLabel(\"图片 Alt 文本\")" \
  "article inspector image alt field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift" \
  "Sources/PersonalSitePublisherMac/Views/EditorInspectorSections.swift"

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
  ".accessibilityLabel(\"启用自动同步\")" \
  "repository auto-sync toggle must expose an accessibility label" \
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
  "Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift" \
  ".accessibilityLabel(\"当前站点 Profile\")" \
  "profile picker must expose an accessibility label"

require_literal_source_manifest \
  "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift" \
  ".accessibilityLabel(\"AI 模型名称\")" \
  "AI custom model field must expose an accessibility label"

require_literal_any_file \
  ".accessibilityLabel(\"当前文章阅读量\")" \
  "content performance page view field must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift" \
  "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift" \
  ".accessibilityLabel(\"外部验收证据链接\")" \
  "external evidence URL field must expose an accessibility label"

require_literal \
  "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift" \
  ".accessibilityLabel(\"启用部署轮询\")" \
  "deployment polling toggle must expose an accessibility label"

require_literal_any_file \
  ".accessibilityLabel(\"复制全部外部调试链接\")" \
  "social external debug copy-all action must expose an accessibility label" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift" \
  "Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspectorSections.swift" \
  "Sources/PersonalSitePublisherMac/Views/EditorInspectorSections.swift"

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

textfield_gaps="$(
  perl -0ne 'while(/TextField\([^\n]*(?:\n[^\n]*){0,8}/g){$m=$&; if($m !~ /accessibilityLabel/){$prefix=substr($_,0,pos($_)); $line=1+($prefix=~tr/\n//); print "$ARGV:$line\n"}}' \
    "$ROOT_DIR"/Sources/PersonalSitePublisherMac/Views/*.swift
)"
[[ -z "$textfield_gaps" ]] || fail "text fields missing accessibility labels: $textfield_gaps"

echo "accessibility gate: labels, values, hints, keyboard shortcuts, command routing, first-run setup, status light, settings, editor, site starter, diff review, and publish recovery verified"
