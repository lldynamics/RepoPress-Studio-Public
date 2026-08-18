import Combine
import Foundation

/// Observation boundary for the high-frequency AI chat inspector.
///
/// The command facade still owns the existing AI actions, but this projection
/// publishes only values that can change the inspector's rendered state. In
/// particular, image-workbench and site-maintenance updates do not invalidate
/// the chat surface.
@MainActor
public final class WorkbenchAIChatFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  /// Read-only chat state belongs to this narrow observation boundary. The
  /// command facade remains available for actions, while quick-switch views
  /// can avoid depending on unrelated image and site-maintenance publishers.
  public var tokenAvailability: KeychainTokenAvailability {
    store.aiTokenAvailability
  }

  public var chatModelGrade: AIChatModelGrade {
    store.aiChatModelGrade
  }

  public var chatSelectedModel: String {
    store.aiChatSelectedModel
  }

  public var chatReasoningEffortOverride: String? {
    store.activeAIConnectionProfile.config.resolvedAdvancedSettings
      .reasoningEffortOverride?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  public var chatConnectionProfiles: [AIConnectionProfile] {
    store.aiConnectionProfiles
  }

  public var activeChatConnectionProfile: AIConnectionProfile {
    store.activeAIConnectionProfile
  }

  public func chatProviderConfig(for draft: ArticleDraft) -> AIProviderConfig {
    store.aiProviderConfig(for: store.profile(for: draft))
  }

  public init(store: WorkbenchStore) {
    self.store = store

    let aiWorkspace = store.aiWorkspaceStore
    observe(aiWorkspace.$aiTokenAvailability)
    observe(aiWorkspace.$aiChatDraftID)
    observe(aiWorkspace.$aiChatConversationTitle)
    observe(aiWorkspace.$aiChatMessages)
    observe(aiWorkspace.$aiChatContextMode)
    observe(aiWorkspace.$aiChatKnowledgePolicy)
    observe(aiWorkspace.$aiChatModelGrade)
    observe(aiWorkspace.$aiChatReasoningLevel)
    observe(aiWorkspace.$aiChatSelectedModel)
    observe(aiWorkspace.$aiChatFocusedParagraphID)
    observe(aiWorkspace.$aiChatCustomPrompts)
    observe(aiWorkspace.$aiConversations)
    observe(aiWorkspace.$activeAIConversationIDsByDraftID)
    observe(aiWorkspace.$activeAIConversationIDsByScope)
    observe(aiWorkspace.$aiChatMessage)
    observe(aiWorkspace.$isAIChatRunning)
    observe(aiWorkspace.$isAutomationRunning)
    observe(aiWorkspace.$automationRunRecords)
    observe(aiWorkspace.$isAIPublishingAssistantPresented)
    observeAny(aiWorkspace.$pendingAIQuickPrompt)

    observe(store.aiStore.$aiChatManualRetryState)
    observe(store.aiStore.$aiGeneralChatManualRetryState)

    let publishing = store.publishingStore
    observe(publishing.$drafts)
    observe(publishing.$profiles)
    observe(publishing.$activeProfileID)
    observe(publishing.$selectedDraftID)
    observe(publishing.$draftListContentScope)
    observe(store.$aiConnectionProfiles)
  }

  private func observe<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  private func observeAny<P: Publisher>(_ publisher: P)
  where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
  }
}
