import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct AIChatPromptLibrarySheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  @State private var selectedScope: AIPublishingPromptLibraryScope = .all

  let draft: ArticleDraft
  var onApplyPrompt: (AIPublishingQuickPrompt) -> Void
  var onApplyWorkflowGuide: (AIPublishingWorkflowGuide) -> Void
  var onApplyEditorAction: (AIPublishingActionKind) -> Void
  var customPrompts: [AIPublishingCustomPrompt]
  var onApplyCustomPrompt: (AIPublishingCustomPrompt) -> Void
  var onDeleteCustomPrompt: (AIPublishingCustomPrompt.ID) -> Void

  private var snapshot: AIPublishingPromptLibrarySnapshot {
    AIPublishingPromptLibraryService.snapshot(
      selectedScope: selectedScope,
      searchText: searchText,
      draft: draft
    )
  }

  var body: some View {
    NavigationSplitView {
      List(AIPublishingPromptLibraryScope.allCases, selection: $selectedScope) { scope in
        Label(scope.displayName, systemImage: scope.systemImage)
          .tag(scope)
      }
      .navigationTitle("AI 场景")
      .frame(minWidth: 180)
    } detail: {
      List {
        if let recommendation = snapshot.recommendation {
          Section {
            VStack(alignment: .leading, spacing: 4) {
              Text(recommendation.title)
                .font(.callout.weight(.semibold))
              Text(recommendation.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

            ForEach(recommendation.actions) { action in
              Button {
                onApplyEditorAction(action)
                dismiss()
              } label: {
                AIChatPromptLibraryEditorActionRow(action: action)
              }
              .buttonStyle(.plain)
            }
          }
        }

        if !customPrompts.isEmpty {
          Section("自定义提示") {
            ForEach(customPrompts) { prompt in
              HStack(spacing: 8) {
                Button {
                  onApplyCustomPrompt(prompt)
                  dismiss()
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Label(prompt.title, systemImage: "bookmark")
                    Text(prompt.prompt)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(2)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                  onDeleteCustomPrompt(prompt.id)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除自定义提示")
                .accessibilityLabel("删除自定义提示")
                .accessibilityValue(prompt.title)
              }
            }
          }
        }

        if !snapshot.recommendedWorkflowGuides.isEmpty {
          Section("推荐工作流") {
            ForEach(snapshot.recommendedWorkflowGuides) { guide in
              Button {
                onApplyWorkflowGuide(guide)
                dismiss()
              } label: {
                AIChatPromptLibraryWorkflowRow(guide: guide)
              }
              .buttonStyle(.plain)
            }
          }
        }

        ForEach(snapshot.spotlightActionSections) { section in
          Section("\(section.group.displayName) · 常用动作") {
            ForEach(section.actions) { action in
              Button {
                onApplyEditorAction(action)
                dismiss()
              } label: {
                AIChatPromptLibraryEditorActionRow(action: action)
              }
              .buttonStyle(.plain)
            }
          }
        }

        if !snapshot.workflowGuides.isEmpty {
          Section("AI 工作流") {
            ForEach(snapshot.workflowGuides) { guide in
              Button {
                onApplyWorkflowGuide(guide)
                dismiss()
              } label: {
                AIChatPromptLibraryWorkflowRow(guide: guide)
              }
              .buttonStyle(.plain)
            }
          }
        }

        ForEach(snapshot.promptSections) { section in
          Section(section.group.displayName) {
            ForEach(section.prompts) { prompt in
              Button {
                onApplyPrompt(prompt)
                dismiss()
              } label: {
                Label(prompt.displayName, systemImage: prompt.systemImage)
              }
            }
          }
        }

        ForEach(snapshot.editorActionSections) { section in
          Section("\(section.group.displayName) · 编辑器动作") {
            ForEach(section.actions) { action in
              Button {
                onApplyEditorAction(action)
                dismiss()
              } label: {
                AIChatPromptLibraryEditorActionRow(action: action)
              }
              .buttonStyle(.plain)
            }
          }
        }

        if !snapshot.hasVisibleContent {
          Section {
            Text("没有找到匹配的 AI 指令。")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .searchable(text: $searchText, prompt: "搜索 AI 指令")
      .navigationTitle("AI 指令库")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            dismiss()
          }
        }
      }
    }
  }
}

struct AIChatPromptLibraryEditorActionRow: View {
  let action: AIPublishingActionKind

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: action.promptLibrarySystemImage)
        .foregroundStyle(Color.accentColor)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 4) {
        Text(action.displayName)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
        Text(action.promptLibraryDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Image(systemName: "plus.circle")
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

struct AIChatPromptLibraryWorkflowRow: View {
  let guide: AIPublishingWorkflowGuide

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: guide.systemImage)
        .foregroundStyle(Color.accentColor)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 4) {
        Text(guide.title)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
        Text(guide.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(guide.actionPreview)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      Image(systemName: "plus.circle")
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}
