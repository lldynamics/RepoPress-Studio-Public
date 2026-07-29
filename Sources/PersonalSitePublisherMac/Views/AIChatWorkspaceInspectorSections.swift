import PublishingWorkbenchCore
import SwiftUI

struct AIChatConversationInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if context.messages.isEmpty {
        ContentUnavailableView(
          "开始对话",
          systemImage: "bubble.left.and.text.bubble.right",
          description: Text("在下方输入问题，AI 会结合当前文章回答。")
        )
        .frame(minHeight: 130)
      } else {
        if context.totalMessageCount > context.messages.count {
          Button {
            actions.loadEarlierMessages()
          } label: {
            Label(
              "加载更早消息（已显示 \(context.messages.count)/\(context.totalMessageCount)）",
              systemImage: "clock.arrow.circlepath"
            )
          }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.primary)
        }

        ForEach(context.messages) { message in
          VStack(alignment: .leading, spacing: 6) {
            Text(message.role.localizedDisplayNameKey)
              .font(.caption.weight(.semibold))
              .foregroundStyle(message.role == .assistant ? WorkbenchTheme.primary : .secondary)

            Text(AIPublishingChatMessageCompositionService.displayContent(for: message))
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)

            if !message.knowledgeCitations.isEmpty {
              knowledgeCitations(message.knowledgeCitations)
            }

            if let plan = message.automationPlan {
              AIChatAutomationPlanCard(
                message: message,
                plan: plan,
                currentDraft: context.draft,
                isAutomationRunning: context.isAutomationRunning,
                latestRunRecord: context.automationRunRecords.first {
                  $0.planID == plan.id && ($0.hasRollback || $0.rolledBackAt != nil)
                } ?? context.automationRunRecords.first { $0.planID == plan.id },
                actions: actions
              )
            }

            if message.id == latestAssistantMessageID {
              Button {
                actions.appendReply(message, context.draft)
              } label: {
                Label(
                  message.knowledgeCitations.isEmpty ? "预览并追加" : "预览并附引用",
                  systemImage: "rectangle.split.2x1"
                )
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
          .contextMenu {
            Button {
              actions.branchConversation(message.id, context.draft)
            } label: {
              Label("从这条消息处分支对话", systemImage: "arrow.triangle.branch")
            }
            .disabled(context.isChatRunning)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var latestAssistantMessageID: AIPublishingChatMessage.ID? {
    context.messages.last(where: { $0.role == .assistant })?.id
  }

  @ViewBuilder
  private func knowledgeCitations(_ citations: [KnowledgeCitation]) -> some View {
    Divider()
    VStack(alignment: .leading, spacing: 5) {
      Label("资料库引用", systemImage: "books.vertical")
        .font(.workbenchCardTitle)
        .foregroundStyle(.secondary)

      ForEach(citations) { citation in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text("[\(citation.id)] \(citation.title)")
              .font(.workbenchItemTitle)
            Spacer(minLength: 8)
            Button {
              actions.openCitation(citation)
            } label: {
              Label("打开原文", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.plain)
            .font(.workbenchButtonLabel)
            .foregroundStyle(WorkbenchTheme.primary)
          }
          if let locator = citation.locator?.nilIfEmpty {
            Text(locator)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text(citation.excerpt)
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .textSelection(.enabled)
        }
      }
    }
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

      let draftTitle = context.draft.title.nilIfEmpty ?? "未命名文章"
      Text(draftTitle)
        .font(.callout.weight(.medium))
        .workbenchTruncatedIdentity(draftTitle, lineLimit: 2)

      Text(context.markdownPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(context.markdownPath, lineLimit: 2)

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
              .font(.workbenchItemTitle)
              .workbenchTruncatedIdentity(suggestion.targetTitle)
            Text(suggestion.reason)
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            Text(suggestion.targetPath)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .workbenchTruncatedIdentity(suggestion.targetPath)

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
