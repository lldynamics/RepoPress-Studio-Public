import Foundation
import PublishingWorkbenchCore

struct AIChatContextInspectorState {
  let conversation: AIChatInspectorConversationContext?
}

enum AIChatInspectorContextPresentationPolicy {
  static func canPresentConversation(
    mode: AIPublishingChatContextMode,
    hasDraft: Bool
  ) -> Bool {
    mode == .general || hasDraft
  }
}

@MainActor
enum AIChatInspectorDraftResolver {
  static func resolve(
    selectedDraftID: UUID?,
    usesWindowDraftSelection: Bool,
    ai: WorkbenchAIFeatureFacade
  ) -> ArticleDraft? {
    if let selectedDraftID {
      return ai.chatDraft(for: selectedDraftID)
    }
    return usesWindowDraftSelection ? nil : ai.selectedChatDraft
  }
}

/// Static inspector data is relatively expensive (profile/context relation
/// lookup and title derivation), while a stream changes only its final text
/// leaf. This cache is deliberately main-actor confined because it backs one
/// SwiftUI inspector instance.
@MainActor
final class AIChatInspectorStaticProjectionCache: ObservableObject {
  struct Key: Equatable {
    let draftID: UUID?
    let draftUpdatedAt: Date?
    let conversationID: UUID?
    let contextMode: AIPublishingChatContextMode
    let conversationTitle: String?
    let firstUserMessageID: UUID?
    let lifecycleRevision: UInt64
    let siteMaintenanceSnapshotVersion: Int
  }

  struct Projection {
    let draft: ArticleDraft?
    let conversationID: UUID?
    let conversationTitle: String
    let relatedSuggestions: [AIChatRelatedSuggestionPresentation]
  }

  private var key: Key?
  private var projection: Projection?
  private(set) var buildCount = 0

  func resolve(
    key: Key,
    build: () -> Projection
  ) -> Projection {
    if self.key == key, let projection { return projection }
    let next = build()
    self.key = key
    projection = next
    buildCount &+= 1
    return next
  }
}

/// Keeps the inspector's scroll intent explicit: a user drag opts out of
/// streaming auto-scroll, and only an explicit return action opts back in.
enum AIChatScrollPinningPolicy {
  static func shouldShowReturnToLatest(
    isPinnedToLatest: Bool,
    hasLatestMessage: Bool
  ) -> Bool {
    !isPinnedToLatest && hasLatestMessage
  }

  static func isPinnedAfterUserDrag() -> Bool { false }

  static func isPinnedAfterReturnToLatest() -> Bool { true }

  static func shouldFollowScheduledScroll(
    isPinnedToLatest: Bool,
    scheduledGeneration: UInt64,
    currentGeneration: UInt64
  ) -> Bool {
    isPinnedToLatest && scheduledGeneration == currentGeneration
  }
}

enum AIChatAssistantMessagePresentationMode: Equatable {
  case streamingText
  case structured
}

/// Chooses the lightweight text surface only for the assistant message that
/// is currently receiving the active chat stream. The store already coalesces
/// streaming token publications into its 50 ms UI updates; this policy keeps
/// each such update from rebuilding Markdown/code-block views. Completed and
/// older messages keep their structured presentation.
enum AIChatAssistantMessagePresentationPolicy {
  static func mode(
    role: AIPublishingChatRole,
    messageID: UUID,
    latestMessageID: UUID?,
    isChatRunning: Bool
  ) -> AIChatAssistantMessagePresentationMode {
    guard role == .assistant,
      isChatRunning,
      messageID == latestMessageID
    else {
      return .structured
    }
    return .streamingText
  }
}

struct AIChatInspectorModelGradeCandidate: Equatable, Identifiable {
  let grade: AIChatModelGrade
  let title: String
  let model: String

  var id: String { grade.rawValue }
}

struct AIChatContextSummaryPresentation: Equatable {
  let title: String
  let detail: String
}

enum AIChatConnectionReadiness: Equatable {
  case ready
  case missingEndpoint
  case missingModel
  case missingAPIKey
  case noDraft

  var isReady: Bool {
    self == .ready
  }

  var title: String {
    switch self {
    case .ready:
      return String(localized: "连接配置已就绪")
    case .missingEndpoint:
      return String(localized: "未配置 Endpoint")
    case .missingModel:
      return String(localized: "未配置模型")
    case .missingAPIKey:
      return String(localized: "未配置 API Key")
    case .noDraft:
      return String(localized: "请先选择文章")
    }
  }

  var detail: String {
    switch self {
    case .ready:
      return String(localized: "连接配置已就绪，点击查看快捷切换")
    case .missingEndpoint:
      return String(localized: "未配置 Endpoint / Base URL")
    case .missingModel:
      return String(localized: "未配置模型")
    case .missingAPIKey:
      return String(localized: "未配置 API Key")
    case .noDraft:
      return String(localized: "请先选择一篇文章，再切换 AI 连接和模型。")
    }
  }
}

struct AIChatInspectorConversationContext {
  /// General conversations deliberately have no implicit draft. Site
  /// conversations retain the draft only for explicit editing affordances.
  let draft: ArticleDraft?
  let conversationID: UUID?
  let conversationTitle: String
  let messages: [AIPublishingChatMessage]
  let totalMessageCount: Int
  let relatedSuggestions: [AIChatRelatedSuggestionPresentation]
  let isChatRunning: Bool
  let isAutomationRunning: Bool
  let automationRunRecords: [WorkbenchAutomationRunRecord]
}

struct AIChatRelatedSuggestionPresentation: Identifiable {
  let id: String
  let targetTitle: String
  let reason: String
  let targetPath: String
  let targetDraftID: UUID
  let prompt: String
}

struct AIChatContextInspectorActions {
  let sendMessage: (String, ArticleDraft) -> Void
  let selectDraft: (UUID) -> Void
  let appendReply: (AIPublishingChatMessage, ArticleDraft) -> Void
  let applyCodeBlock: (AIChatCodeBlock, ArticleDraft) -> Void
  let insertCodeBlockAtCursor: (AIChatCodeBlock, ArticleDraft) -> Void
  let copyCodeBlock: (AIChatCodeBlock) -> Void
  let copyReply: (AIPublishingChatMessage) -> Void
  let branchConversation: (AIPublishingChatMessage.ID, ArticleDraft) -> Void
  let loadEarlierMessages: () -> Void
  let openCitation: (KnowledgeCitation) -> Void
  let previewStructuredEdits:
    (AIPublishingChatMessage, AIStructuredEditReview, ArticleDraft) -> Void
  let recordStructuredEditFeedback:
    (AILocalEditFeedbackDecision, AIStructuredEditProposal, String?) -> Void
  let createTranslationDraft: (AITranslationDraftPlan) -> Void
  let executeAutomationPlan: (UUID, AIPublishingChatMessage.ID) -> Void
  let executeAutomationStep: (UUID, AIPublishingChatMessage.ID, UUID) -> Void
  let acceptAutomationStep: (UUID, AIPublishingChatMessage.ID, UUID, String) -> Void
  let rejectAutomationStep: (UUID, AIPublishingChatMessage.ID, UUID, String?) -> Void
  let previewAutomationStep:
    (UUID, AIPublishingChatMessage.ID, UUID) -> WorkbenchAutomationDraftPreview?
  let cancelAutomationPlan: (UUID, AIPublishingChatMessage.ID) -> Void
  let rollbackAutomationRun: (UUID) -> Void
  let abandonAgentContinuation: (UUID, UUID, UUID, UUID, Int) -> Bool
}
