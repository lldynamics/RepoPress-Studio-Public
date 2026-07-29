import Foundation
import PublishingWorkbenchCore

struct AIChatContextInspectorState {
  let draft: AIChatInspectorDraftContext?
}

struct AIChatInspectorModelGradeCandidate: Equatable, Identifiable {
  let grade: AIChatModelGrade
  let title: String
  let model: String

  var id: String { grade.rawValue }
}

enum AIChatInspectorHeaderPresentation {
  static func conversationTitle(_ title: String?) -> String {
    title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? String(localized: "新对话")
  }

  static func contextTitle(for mode: AIPublishingChatContextMode) -> String {
    switch mode {
    case .site:
      return String(localized: "当前文章")
    case .general:
      return String(localized: "通用聊天")
    }
  }

  static func providerTitle(for config: AIProviderConfig) -> String {
    switch config.preset {
    case .openAICompatible, .custom:
      return String(localized: "自定义 API")
    case .deepSeek, .openRouter, .local:
      return config.preset.localizedDisplayName
    }
  }

  static func modelSummary(
    for config: AIProviderConfig,
    activeModel: String?
  ) -> String {
    let provider = providerTitle(for: config)
    guard let activeModel = activeModel?.nilIfEmpty else { return provider }
    return "\(provider) · \(activeModel)"
  }

  static func supportsSelectableReasoningLevel(
    config: AIProviderConfig,
    hasDraft: Bool
  ) -> Bool {
    hasDraft && config.usesDeepSeekAPI
  }

  static func modelGradeCandidates(
    for config: AIProviderConfig,
    currentModel: String
  ) -> [AIChatInspectorModelGradeCandidate] {
    [
      (.fast, String(localized: "快速")),
      (.standard, String(localized: "标准")),
      (.highQuality, String(localized: "高质量")),
    ].map { grade, title in
      AIChatInspectorModelGradeCandidate(
        grade: grade,
        title: title,
        model: AIChatModelCatalog.model(
          for: grade,
          config: config,
          currentModel: currentModel
        )
      )
    }
  }

  static func showsCustomModelInput(
    selection: AIChatModelSelectionPresentation?
  ) -> Bool {
    selection?.canEditCustomModel == true
  }
}

struct AIChatInspectorDraftContext {
  let draft: ArticleDraft
  let conversationTitle: String
  let contextSummary: String
  let contextSystemImage: String
  let retrievalBasis: String
  let publicCandidateCount: Int
  let relatedSuggestionCount: Int
  let modelSummary: String
  let markdownPath: String
  let publishFileCount: Int
  let preflightIssueCount: Int
  let imageCount: Int?
  let selectedParagraphTitle: String?
  let selectedParagraphPreview: String?
  let chatMessage: String?
  let messages: [AIPublishingChatMessage]
  let totalMessageCount: Int
  let relatedSuggestions: [AIChatRelatedSuggestionPresentation]
  let isChatRunning: Bool
  let isAutomationRunning: Bool
  let automationRunRecords: [WorkbenchAutomationRunRecord]
  let latestReply: AIPublishingChatMessage?
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
  let branchConversation: (AIPublishingChatMessage.ID, ArticleDraft) -> Void
  let loadEarlierMessages: () -> Void
  let openCitation: (KnowledgeCitation) -> Void
  let executeAutomationPlan: (AIPublishingChatMessage.ID) -> Void
  let executeAutomationStep: (AIPublishingChatMessage.ID, UUID) -> Void
  let previewAutomationStep: (AIPublishingChatMessage.ID, UUID) -> WorkbenchAutomationDraftPreview?
  let cancelAutomationPlan: (AIPublishingChatMessage.ID) -> Void
  let rollbackAutomationRun: (UUID) -> Void
}
