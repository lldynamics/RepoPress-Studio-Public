import PublishingWorkbenchCore
import SwiftUI

struct AIChatConversationInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if context.messages.isEmpty {
        ContentUnavailableView(
          String(localized: "开始对话"),
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
              String(
                format: String(localized: "加载更早消息（已显示 %lld/%lld）"),
                Int64(context.messages.count),
                Int64(context.totalMessageCount)
              ),
              systemImage: "clock.arrow.circlepath"
            )
          }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.primary)
        }

        ForEach(context.messages) { message in
          AIChatMessageSurface(role: message.role) {
            if message.role == .assistant {
              AIChatAssistantMessageContent(
                content: AIPublishingChatMessageCompositionService.displayContent(for: message),
                actions: actions,
                draft: context.draft
              )
            } else {
              Text(verbatim: AIPublishingChatMessageCompositionService.displayContent(for: message))
                .font(.workbenchBody)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if !message.contextReferences.isEmpty {
              Label(
                AIChatContextReferencePresentation.summary(
                  for: message.contextReferences
                ),
                systemImage: "at"
              )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !message.knowledgeCitations.isEmpty {
              knowledgeCitations(message.knowledgeCitations)
            }

            if let payload = message.structuredEditPayload {
              AIChatStructuredEditReviewCard(
                message: message,
                payload: payload,
                preview: { review in
                  actions.previewStructuredEdits(
                    message,
                    review,
                    context.draft
                  )
                },
                recordDecision: actions.recordStructuredEditFeedback
              )
            }

            if let plan = message.translationDraftPlan {
              AIChatTranslationDraftCard(plan: plan) {
                actions.createTranslationDraft(plan)
              }
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

            if message.id == latestAssistantMessageID,
              message.automationPlan == nil,
              message.allowsDraftAppend
            {
              Button {
                actions.appendReply(message, context.draft)
              } label: {
                Label(
                  message.knowledgeCitations.isEmpty
                    ? String(localized: "预览并追加")
                    : String(localized: "预览并附引用"),
                  systemImage: "rectangle.split.2x1"
                )
              }
              .controlSize(.small)
            }

            if message.role == .assistant {
              AIChatAssistantFeedbackControls(
                initialDecision: actions.localFeedbackDecision(message)
              ) { decision in
                actions.recordLocalFeedback(decision, message)
              }
            }
          }
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
      Label(String(localized: "资料库引用"), systemImage: "books.vertical")
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
              Label(String(localized: "打开原文"), systemImage: "arrow.up.forward.square")
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

struct AIChatRelatedSuggestionsInspectorSection: View {
  let context: AIChatInspectorDraftContext
  let actions: AIChatContextInspectorActions

  var body: some View {
    if !context.relatedSuggestions.isEmpty {
      AIChatInspectorSection(String(localized: "关联文章建议")) {
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
                Label(
                  String(localized: "让 AI 写内链段落"),
                  systemImage: "sparkles"
                )
              }
              .disabled(context.isChatRunning)

              Button {
                actions.selectDraft(suggestion.targetDraftID)
              } label: {
                Label(String(localized: "打开目标"), systemImage: "arrow.forward.circle")
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
