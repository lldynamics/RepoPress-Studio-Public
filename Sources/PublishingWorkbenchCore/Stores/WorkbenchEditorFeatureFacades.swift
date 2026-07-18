import Combine
import Foundation

/// Publishes only the state that can replace the editor's center surface.
/// Publishing progress, preview generation, and AI streaming stay outside this
/// observation boundary.
@MainActor
public final class WorkbenchEditorNavigationFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    self.store = store
    observeValue(store.publishingStore.$activeProfileID)
    observeValue(store.publishingStore.$drafts)
    observeValue(store.publishingStore.$selectedSection)
    observeValue(store.publishingStore.$selectedDraftID)
  }

  public var activeProfileID: UUID {
    store.activeProfileID
  }

  public var selectedSection: WorkspaceSection {
    store.selectedSection
  }

  public var selectedDraft: ArticleDraft? {
    store.selectedDraft
  }

  private func observeValue<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

private struct WorkbenchEditorLatestAssistantReference: Equatable {
  let draftID: UUID?
  let messageID: UUID?
}

/// A per-editor projection that avoids forwarding every change from the broad
/// publishing, persistence, and AI stores. In particular, token-by-token AI
/// chat updates do not invalidate the Markdown editor while the assistant
/// message identity remains unchanged.
@MainActor
public final class WorkbenchMarkdownEditorFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var trackedDraftID: UUID
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore, draftID: UUID) {
    self.store = store
    trackedDraftID = draftID

    observeValue(store.publishingStore.$profiles)
    observeValue(store.publishingStore.$activeProfileID)
    observeValue(store.publishingStore.$drafts)
    observeValue(store.publishingStore.$editorDisplayMode)
    observeValue(store.publishingStore.$editorFocusRequest)
    observeValue(store.persistenceStore.$hasUnsavedChanges)
    observeValue(store.persistenceStore.$status)
    observeValue(store.aiWorkspaceStore.$aiTokenAvailability)
    observeValue(store.aiWorkspaceStore.$isAIActionRunning)

    store.publishingStore.draftBodyEditorBufferWillChange
      .sink { [weak self] changedDraftID in
        guard let self, self.trackedDraftID == changedDraftID else { return }
        self.objectWillChange.send()
      }
      .store(in: &cancellables)

    Publishers.CombineLatest(
      store.aiWorkspaceStore.$aiChatDraftID,
      store.aiWorkspaceStore.$aiChatMessages
    )
    .map { draftID, messages in
      WorkbenchEditorLatestAssistantReference(
        draftID: draftID,
        messageID: messages.last(where: { $0.role == .assistant })?.id
      )
    }
    .removeDuplicates()
    .dropFirst()
    .sink { [weak self] _ in self?.objectWillChange.send() }
    .store(in: &cancellables)
  }

  public var editorDisplayMode: EditorDisplayMode {
    store.editorDisplayMode
  }

  public var editorFocusRequest: EditorFocusRequest? {
    store.editorFocusRequest
  }

  public var drafts: [ArticleDraft] {
    store.drafts
  }

  public var lastSaveStatus: String {
    store.lastSaveStatus
  }

  public var hasUnsavedChanges: Bool {
    store.hasUnsavedChanges
  }

  public var isAIActionRunning: Bool {
    store.isAIActionRunning
  }

  public var aiTokenAvailability: KeychainTokenAvailability {
    store.aiTokenAvailability
  }

  public var aiMetadataSuggestion: AIPublishingMetadataSuggestion? {
    store.aiMetadataSuggestion
  }

  public func trackDraft(_ draftID: UUID) {
    trackedDraftID = draftID
  }

  public func profile(for draft: ArticleDraft) -> SiteProfile {
    store.profile(for: draft)
  }

  public func draftBodyEditorBuffer(for draftID: UUID) -> DraftBodyEditorBuffer {
    store.draftBodyEditorBuffer(for: draftID)
  }

  public func latestAssistantMessage(for draftID: UUID) -> AIPublishingChatMessage? {
    guard store.aiChatDraftID == draftID else { return nil }
    return store.aiChatMessages.last { $0.role == .assistant }
  }

  public func preflightIssues(for draft: ArticleDraft) -> [PreflightIssue] {
    store.preflightIssues(for: draft)
  }

  private func observeValue<P: Publisher>(_ publisher: P)
  where P.Failure == Never, P.Output: Equatable {
    publisher
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
