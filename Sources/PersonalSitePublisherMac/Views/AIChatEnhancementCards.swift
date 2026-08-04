import PublishingWorkbenchCore
import SwiftUI

enum AIChatContextReferencePresentation {
  static func label(for reference: AIContextReference) -> String {
    reference.workbenchResourceName.isEmpty
      ? reference.kind.localizedDisplayName
      : "\(reference.kind.localizedDisplayName)：\(reference.workbenchResourceName)"
  }

  static func summary(for references: [AIContextReference]) -> String {
    let summary = AIContextTransmissionSummaryService.make(references: references)
    guard !summary.items.isEmpty else {
      return String(localized: "本次不发送额外上下文。")
    }
    let details = references.map { reference in
      String(
        format: String(localized: "%@（约 %lld 字）"),
        label(for: reference),
        Int64(reference.characterCount)
      )
    }.joined(separator: "、")
    return String(
      format: String(localized: "将发送 %lld 项上下文，共约 %lld 字：%@"),
      Int64(summary.items.count),
      Int64(summary.totalCharacterCount),
      details
    )
  }
}

struct AIChatStructuredEditReviewCard: View {
  let message: AIPublishingChatMessage
  let payload: AIPublishingChatStructuredEditPayload
  let preview: (AIStructuredEditReview) -> Void
  let recordDecision: (AILocalEditFeedbackDecision, AIStructuredEditProposal, String?) -> Void

  @State private var review: AIStructuredEditReview

  init(
    message: AIPublishingChatMessage,
    payload: AIPublishingChatStructuredEditPayload,
    preview: @escaping (AIStructuredEditReview) -> Void,
    recordDecision:
      @escaping (AILocalEditFeedbackDecision, AIStructuredEditProposal, String?) -> Void
  ) {
    self.message = message
    self.payload = payload
    self.preview = preview
    self.recordDecision = recordDecision
    _review = State(
      initialValue: AIStructuredEditReviewService.initialReview(
        for: payload.document
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label(payload.goal, systemImage: "checklist.checked")
          .font(.workbenchCardTitle)
        Spacer()
        Text("\(payload.document.changes.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ForEach(payload.document.changes) { proposal in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(proposal.category.rawValue)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            Spacer()
            Text("\(Int((proposal.confidence * 100).rounded()))%")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          Text(proposal.originalText)
            .font(.workbenchSupporting)
            .strikethrough()
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          Text(proposal.replacementText)
            .font(.workbenchSupporting)
            .foregroundStyle(WorkbenchTheme.primary)
            .textSelection(.enabled)
          Text(proposal.reason)
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack {
            decisionButton(
              title: "接受",
              systemImage: "checkmark",
              decision: .accepted,
              proposal: proposal
            )
            decisionButton(
              title: "拒绝",
              systemImage: "xmark",
              decision: .rejected,
              proposal: proposal
            )
          }
          .controlSize(.small)
        }
        .padding(8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
      }

      HStack {
        Button("全部接受") {
          for proposal in payload.document.changes {
            recordDecision(.accepted, proposal, message.model)
          }
          review = AIStructuredEditReviewService.acceptingAll(in: review)
        }
        Button("全部拒绝") {
          for proposal in payload.document.changes {
            recordDecision(.rejected, proposal, message.model)
          }
          review = AIStructuredEditReviewService.rejectingAll(in: review)
        }
        Spacer()
        Button {
          preview(review)
        } label: {
          Label("预览已接受修改", systemImage: "rectangle.split.2x1")
        }
        .disabled(acceptedCount == 0)
      }
      .controlSize(.small)
    }
    .padding(9)
    .background(
      WorkbenchTheme.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 10)
    )
  }

  private var acceptedCount: Int {
    payload.document.changes.filter {
      review.decision(for: $0.id) == .accepted
    }.count
  }

  private func decisionButton(
    title: String,
    systemImage: String,
    decision: AIStructuredEditDecision,
    proposal: AIStructuredEditProposal
  ) -> some View {
    Button {
      do {
        switch decision {
        case .accepted:
          review = try AIStructuredEditReviewService.accepting(
            proposal.id,
            in: review
          )
          recordDecision(.accepted, proposal, message.model)
        case .rejected:
          review = try AIStructuredEditReviewService.rejecting(
            proposal.id,
            in: review
          )
          recordDecision(.rejected, proposal, message.model)
        case .pending:
          break
        }
      } catch {}
    } label: {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(.bordered)
    .tint(
      review.decision(for: proposal.id) == decision
        ? WorkbenchTheme.primary
        : nil
    )
  }
}

struct AIChatTranslationDraftCard: View {
  let plan: AITranslationDraftPlan
  let create: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label("关联翻译草稿", systemImage: "character.book.closed")
        .font(.workbenchCardTitle)
      Text(plan.translatedDraft.title)
        .font(.workbenchItemTitle)
      Text("目标语言：\(plan.targetLanguageCode) · 新草稿默认保持未发布")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button(action: create) {
        Label("创建并打开新草稿", systemImage: "plus.square.on.square")
      }
      .controlSize(.small)
    }
    .padding(9)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct AIChatAssistantFeedbackControls: View {
  let initialDecision: AILocalEditFeedbackDecision?
  let record: (AILocalEditFeedbackDecision) -> Void
  @State private var decision: AILocalEditFeedbackDecision?

  init(
    initialDecision: AILocalEditFeedbackDecision?,
    record: @escaping (AILocalEditFeedbackDecision) -> Void
  ) {
    self.initialDecision = initialDecision
    self.record = record
    _decision = State(initialValue: initialDecision)
  }

  var body: some View {
    HStack(spacing: 5) {
      Text("这条回复有帮助吗？")
        .font(.caption)
        .foregroundStyle(.secondary)
      feedbackButton(.accepted, icon: "hand.thumbsup")
      feedbackButton(.rejected, icon: "hand.thumbsdown")
    }
  }

  private func feedbackButton(
    _ value: AILocalEditFeedbackDecision,
    icon: String
  ) -> some View {
    Button {
      decision = value
      record(value)
    } label: {
      Image(systemName: decision == value ? "\(icon).fill" : icon)
    }
    .buttonStyle(.plain)
    .foregroundStyle(decision == value ? WorkbenchTheme.primary : .secondary)
    .help(value == .accepted ? "有帮助" : "没有帮助")
    .accessibilityLabel(value == .accepted ? "这条回复有帮助" : "这条回复没有帮助")
  }
}
