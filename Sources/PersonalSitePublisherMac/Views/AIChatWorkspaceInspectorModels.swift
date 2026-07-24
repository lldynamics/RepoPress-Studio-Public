import Foundation
import PublishingWorkbenchCore

struct AIChatContextInspectorState {
  let draft: AIChatInspectorDraftContext?
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
  let loadEarlierMessages: () -> Void
  let openCitation: (KnowledgeCitation) -> Void
  let executeAutomationPlan: (AIPublishingChatMessage.ID) -> Void
  let executeAutomationStep: (AIPublishingChatMessage.ID, UUID) -> Void
  let previewAutomationStep: (AIPublishingChatMessage.ID, UUID) -> WorkbenchAutomationDraftPreview?
  let cancelAutomationPlan: (AIPublishingChatMessage.ID) -> Void
  let rollbackAutomationRun: (UUID) -> Void
}
