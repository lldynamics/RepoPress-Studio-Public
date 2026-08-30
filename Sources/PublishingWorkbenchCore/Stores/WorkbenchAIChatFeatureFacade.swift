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
  private let usesWindowDraftSelection: Bool
  private let observedDraftIDSubject: CurrentValueSubject<UUID?, Never>
  /// The Inspector is hosted in multiple windows. A non-nil value is the
  /// window's local selection; nil preserves the existing shared selection
  /// behavior for standalone/screenshot hosts.
  public private(set) var observedDraftID: UUID?
  /// A durable conversation write invalidates cached inspector context; token
  /// publications deliberately leave this unchanged.
  @Published public private(set) var chatSessionLifecycleRevision: UInt64 = 0
  /// Related-article suggestions are derived from this snapshot, independently
  /// of the selected draft's own timestamp.
  @Published public private(set) var siteMaintenanceSnapshotVersion = 0

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

  public init(
    store: WorkbenchStore,
    draftID: UUID? = nil,
    windowScopedDraftSelection: Bool = false
  ) {
    self.store = store
    usesWindowDraftSelection = windowScopedDraftSelection || draftID != nil
    observedDraftID = draftID
    observedDraftIDSubject = CurrentValueSubject(draftID)

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
    store.aiStore.$aiChatSessionLifecycleRevision
      .removeDuplicates()
      .sink { [weak self] revision in
        self?.chatSessionLifecycleRevision = revision
      }
      .store(in: &cancellables)
    store.siteMaintenanceStore.$snapshotVersion
      .removeDuplicates()
      .sink { [weak self] revision in
        self?.siteMaintenanceSnapshotVersion = revision
      }
      .store(in: &cancellables)

    let publishing = store.publishingStore
    // A body flush publishes the whole drafts array, but the chat inspector's
    // selection and provider configuration are already observed through the
    // dedicated projections below. Do not make a typing autosave redraw the
    // inspector or rebuild its static relation context.
    observe(publishing.$profiles)
    observe(publishing.$activeProfileID)
    observe(publishing.$draftListContentScope)
    observe(store.$aiConnectionProfiles)

    let inspectedDraftID: AnyPublisher<UUID?, Never> =
      usesWindowDraftSelection
      ? observedDraftIDSubject.eraseToAnyPublisher()
      : publishing.$selectedDraftID.eraseToAnyPublisher()
    Publishers.CombineLatest(publishing.$drafts, inspectedDraftID)
      .map { drafts, draftID in
        draftID.flatMap { draftID in
          drafts.first(where: { $0.id == draftID })?.metadataProjection
        }
      }
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)
  }

  /// Changes only this facade's narrow draft projection. It does not mutate
  /// the global workbench selection or subscribe to full draft bodies.
  public func setObservedDraftID(_ draftID: UUID?) {
    guard usesWindowDraftSelection, observedDraftID != draftID else { return }
    observedDraftID = draftID
    observedDraftIDSubject.send(draftID)
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
