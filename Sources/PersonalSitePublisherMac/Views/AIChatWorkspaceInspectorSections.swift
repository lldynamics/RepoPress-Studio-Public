import PublishingWorkbenchCore
import SwiftUI

struct AIChatConversationInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    AIChatInspectorSection("对话") {
      if context.messages.isEmpty {
        ContentUnavailableView(
          "开始对话",
          systemImage: "bubble.left.and.text.bubble.right",
          description: Text("在下方输入问题，AI 会结合当前文章回答。")
        )
        .frame(minHeight: 130)
      } else {
        if context.totalMessageCount > context.messages.count {
          Text("仅显示最近 \(context.messages.count) 条，共 \(context.totalMessageCount) 条消息。")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        ForEach(context.messages) { message in
          VStack(alignment: .leading, spacing: 6) {
            Text(message.role.localizedDisplayNameKey)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(message.role == .assistant ? WorkbenchTheme.primary : .secondary)

            Text(AIPublishingChatMessageCompositionService.displayContent(for: message))
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)

            if message.id == latestAssistantMessageID {
              Button {
                actions.appendReply(message, context.draft)
              } label: {
                Label("追加到文章", systemImage: "text.append")
              }
              .controlSize(.small)
            }
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .fill(message.role == .assistant ? WorkbenchTheme.primary.opacity(0.08) : Color.secondary.opacity(0.08))
          )
          .id(message.id)
        }
      }
    }
  }

  private var latestAssistantMessageID: AIPublishingChatMessage.ID? {
    context.messages.last(where: { $0.role == .assistant })?.id
  }
}

struct AIChatContextOverviewInspectorSection: View {
  let context: AIChatInspectorDraftContext

  var body: some View {
    AIChatInspectorSection("上下文文章") {
      AIChatInspectorStatRow(title: "当前对话", value: context.conversationTitle, systemImage: "bubble.left.and.text.bubble.right")
      AIChatInspectorStatRow(title: "上下文", value: context.contextSummary, systemImage: context.contextSystemImage)
      AIChatInspectorStatRow(title: "引用依据", value: context.retrievalBasis, systemImage: "scope")
      AIChatInspectorStatRow(title: "公开候选", value: "\(context.publicCandidateCount)", systemImage: "globe")
      AIChatInspectorStatRow(title: "关联建议", value: "\(context.relatedSuggestionCount)", systemImage: "link")
      AIChatInspectorStatRow(title: "模型", value: context.modelSummary, systemImage: "cpu")

      Divider()

      Text(context.draft.title.nilIfEmpty ?? "未命名文章")
        .font(.callout.weight(.medium))
        .lineLimit(2)

      Text(context.markdownPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .textSelection(.enabled)

      AIChatInspectorStatRow(title: "发布文件", value: "\(context.publishFileCount)", systemImage: "shippingbox")
      AIChatInspectorStatRow(title: "发布检查", value: "\(context.preflightIssueCount)", systemImage: "checklist")
      AIChatInspectorStatRow(
        title: "图片",
        value: context.imageCount.map(String.init) ?? String(localized: "正在读取…"),
        systemImage: "photo"
      )

      if let paragraphTitle = context.selectedParagraphTitle,
         let paragraphPreview = context.selectedParagraphPreview {
        Divider()
        Label(paragraphTitle, systemImage: "text.quote")
          .font(.caption.weight(.semibold))
        Text(paragraphPreview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }

      if let message = context.chatMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
  }
}

struct AIChatRelatedSuggestionsInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    if !context.relatedSuggestions.isEmpty {
      AIChatInspectorSection("关联文章建议") {
        ForEach(context.relatedSuggestions) { suggestion in
          VStack(alignment: .leading, spacing: 5) {
            Text(suggestion.targetTitle)
              .font(.caption.weight(.semibold))
              .lineLimit(1)
            Text(suggestion.reason)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            Text(suggestion.targetPath)
              .font(.caption2.monospaced())
              .foregroundStyle(.tertiary)
              .lineLimit(1)

            HStack {
              Button {
                actions.sendMessage(suggestion.prompt, context.draft)
              } label: {
                Label("让 AI 写内链段落", systemImage: "sparkles")
              }
              .disabled(context.isChatRunning)

              Button {
                actions.selectDraft(suggestion.targetDraftID)
              } label: {
                Label("打开目标", systemImage: "arrow.forward.circle")
              }
            }
            .controlSize(.small)
          }

          if suggestion.id != context.relatedSuggestions.last?.id {
            Divider()
          }
        }
      }
    }
  }
}

struct AIChatWorkflowGuidesInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    AIChatInspectorSection("AI 工作流") {
      ForEach(AIPublishingWorkflowGuide.featuredGuides) { guide in
        Button {
          actions.sendMessage(
            AIPublishingChatPromptTemplateService.workflowGuidePrompt(for: guide),
            context.draft
          )
        } label: {
          VStack(alignment: .leading, spacing: 3) {
            Label(guide.title, systemImage: guide.systemImage)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(guide.actionPreview)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(context.isChatRunning)
      }
    }
  }
}

struct AIChatQuickPromptsInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    AIChatInspectorSection("快捷提示") {
      ForEach(AIPublishingQuickPrompt.featuredCapabilitySections) { section in
        VStack(alignment: .leading, spacing: 6) {
          Label(section.group.localizedDisplayName, systemImage: section.group.systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

          ForEach(section.prompts) { prompt in
            Button {
              actions.sendMessage(prompt.prompt, context.draft)
            } label: {
              Label(prompt.localizedDisplayName, systemImage: prompt.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(context.isChatRunning)
          }
        }
      }
    }
  }
}

struct AIChatRecommendedActionsInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    AIChatInspectorSection("当前推荐") {
      ForEach(recommendedActions, id: \.self) { action in
        Button {
          actions.sendMessage(
            AIPublishingChatPromptTemplateService.editorActionPrompt(for: action),
            context.draft
          )
        } label: {
          Label(action.localizedDisplayName, systemImage: systemImage(for: action))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(context.isChatRunning)
      }
    }
  }

  private var recommendedActions: [AIPublishingActionKind] {
    Array(
      AIPublishingActionRecommendationService.recommendation(draft: context.draft)
        .actions
        .prefix(4)
    )
  }

  private func systemImage(for action: AIPublishingActionKind) -> String {
    AIPublishingWritingActionCatalog.articleActions.first { $0.kind == action }?.systemImage
      ?? "sparkles"
  }
}

struct AIChatLatestReplyInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    if let latestReply = context.latestReply {
      AIChatInspectorSection("最近回复") {
        Text(latestReply.content)
          .font(.caption)
          .lineLimit(8)
          .textSelection(.enabled)

        Button {
          actions.appendReply(latestReply, context.draft)
        } label: {
          Label("追加到文章", systemImage: "text.append")
        }
      }
    }
  }
}
