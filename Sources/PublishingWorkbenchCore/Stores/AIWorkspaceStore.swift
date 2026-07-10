import Combine
import Foundation

@MainActor
public final class AIWorkspaceStore: ObservableObject {
  @Published public internal(set) var aiTokenAvailability: KeychainTokenAvailability
  @Published public internal(set) var aiActionResult: AIPublishingActionResult?
  @Published public internal(set) var aiActionMessage: String?
  @Published public internal(set) var isAIActionRunning: Bool
  @Published public internal(set) var aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord]
  @Published public internal(set) var aiMetadataSuggestionDraftID: UUID?
  @Published public internal(set) var aiMetadataSuggestion: AIPublishingMetadataSuggestion?
  @Published public internal(set) var isAIMetadataSuggestionRunning: Bool
  @Published public internal(set) var aiChatDraftID: UUID?
  @Published public internal(set) var aiChatConversationTitle: String?
  @Published public internal(set) var aiChatMessages: [AIPublishingChatMessage]
  @Published public internal(set) var aiChatContextMode: AIPublishingChatContextMode
  @Published public internal(set) var aiChatModelGrade: AIChatModelGrade
  @Published public internal(set) var aiChatSelectedModel: String
  @Published public internal(set) var aiChatFocusedParagraphID: String?
  @Published public internal(set) var aiChatCustomPrompts: [AIPublishingCustomPrompt]
  @Published public internal(set) var pendingAIQuickPrompt: AIPublishingQuickPrompt?
  @Published public internal(set) var aiChatMessage: String?
  @Published public internal(set) var isAIChatRunning: Bool
  @Published public internal(set) var aiImageTextSuggestionDraftID: UUID?
  @Published public internal(set) var aiImageTextSuggestions: [AIPublishingImageTextSuggestion]
  @Published public internal(set) var isAIImageTextRunning: Bool
  @Published public internal(set) var seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot]
  @Published public internal(set) var seoSocialPreviewSnapshot: SEOSocialPreviewSnapshot?
  @Published public internal(set) var seoSocialPreviewMessage: String?
  @Published public internal(set) var isAIPublishingAssistantPresented: Bool

  init(
    aiTokenAvailability: KeychainTokenAvailability = KeychainTokenAvailability(hasToken: false),
    aiActionResult: AIPublishingActionResult? = nil,
    aiActionMessage: String? = nil,
    isAIActionRunning: Bool = false,
    aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] = [],
    aiMetadataSuggestionDraftID: UUID? = nil,
    aiMetadataSuggestion: AIPublishingMetadataSuggestion? = nil,
    isAIMetadataSuggestionRunning: Bool = false,
    aiChatDraftID: UUID? = nil,
    aiChatConversationTitle: String? = nil,
    aiChatMessages: [AIPublishingChatMessage] = [],
    aiChatContextMode: AIPublishingChatContextMode = .site,
    aiChatModelGrade: AIChatModelGrade = .standard,
    aiChatSelectedModel: String = "",
    aiChatFocusedParagraphID: String? = nil,
    aiChatCustomPrompts: [AIPublishingCustomPrompt] = [],
    pendingAIQuickPrompt: AIPublishingQuickPrompt? = nil,
    aiChatMessage: String? = nil,
    isAIChatRunning: Bool = false,
    aiImageTextSuggestionDraftID: UUID? = nil,
    aiImageTextSuggestions: [AIPublishingImageTextSuggestion] = [],
    isAIImageTextRunning: Bool = false,
    seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot] = [:],
    seoSocialPreviewSnapshot: SEOSocialPreviewSnapshot? = nil,
    seoSocialPreviewMessage: String? = nil,
    isAIPublishingAssistantPresented: Bool = false
  ) {
    self.aiTokenAvailability = aiTokenAvailability
    self.aiActionResult = aiActionResult
    self.aiActionMessage = aiActionMessage
    self.isAIActionRunning = isAIActionRunning
    self.aiMetadataApplicationRecords = aiMetadataApplicationRecords
    self.aiMetadataSuggestionDraftID = aiMetadataSuggestionDraftID
    self.aiMetadataSuggestion = aiMetadataSuggestion
    self.isAIMetadataSuggestionRunning = isAIMetadataSuggestionRunning
    self.aiChatDraftID = aiChatDraftID
    self.aiChatConversationTitle = aiChatConversationTitle
    self.aiChatMessages = aiChatMessages
    self.aiChatContextMode = aiChatContextMode
    self.aiChatModelGrade = aiChatModelGrade
    self.aiChatSelectedModel = aiChatSelectedModel
    self.aiChatFocusedParagraphID = aiChatFocusedParagraphID
    self.aiChatCustomPrompts = aiChatCustomPrompts
    self.pendingAIQuickPrompt = pendingAIQuickPrompt
    self.aiChatMessage = aiChatMessage
    self.isAIChatRunning = isAIChatRunning
    self.aiImageTextSuggestionDraftID = aiImageTextSuggestionDraftID
    self.aiImageTextSuggestions = aiImageTextSuggestions
    self.isAIImageTextRunning = isAIImageTextRunning
    self.seoSocialPreviewSnapshots = seoSocialPreviewSnapshots
    self.seoSocialPreviewSnapshot = seoSocialPreviewSnapshot
    self.seoSocialPreviewMessage = seoSocialPreviewMessage
    self.isAIPublishingAssistantPresented = isAIPublishingAssistantPresented
  }
}
