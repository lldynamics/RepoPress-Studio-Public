import Combine
import Foundation

/// Publishes only the state that can replace the editor's center surface.
/// Publishing progress, preview generation, and AI streaming stay outside this
/// observation boundary.
@MainActor
public final class WorkbenchEditorNavigationFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()
  private var isChangeNotificationScheduled = false

  public init(store: WorkbenchStore) {
    self.store = store
    observeValue(store.publishingStore.$activeProfileID)
    observeValue(store.publishingStore.$drafts)
    observeValue(store.publishingStore.$selectedSection)
    observeValue(store.publishingStore.$selectedDraftID)
    observeValue(store.publishingStore.$draftListContentScope)
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
      .sink { [weak self] _ in self?.scheduleChangeNotification() }
      .store(in: &cancellables)
  }

  private func scheduleChangeNotification() {
    guard !isChangeNotificationScheduled else { return }
    isChangeNotificationScheduled = true

    // The upstream @Published notification arrives from willSet. Defer the
    // facade invalidation until its getters can read the committed selection.
    RunLoop.main.perform(inModes: [.default]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isChangeNotificationScheduled = false
        self.objectWillChange.send()
      }
    }
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
    observeValue(store.publishingStore.$customMarkdownSnippets)
    observeValue(store.publishingStore.$editorDisplayMode)
    observeValue(store.publishingStore.$editorFocusRequest)
    observeValue(store.persistenceStore.$hasUnsavedChanges)
    observeValue(store.persistenceStore.$status)
    observeValue(store.$siteDraftFileSaveStates)
    observeValue(store.$draftRecoveryJournalErrorMessage)
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

  public var customMarkdownSnippets: [MarkdownSnippet] {
    store.customMarkdownSnippets
  }

  public var lastSaveStatus: String {
    if let recoveryError = store.draftRecoveryJournalErrorMessage?.nilIfEmpty {
      return recoveryError
    }
    guard let draft = store.drafts.first(where: { $0.id == trackedDraftID }) else {
      return store.lastSaveStatus
    }
    if draft.isGeneralDraft {
      return store.hasUnsavedChanges
        ? CoreL10n.text("正在保存到软件…")
        : CoreL10n.text("已保存在软件")
    }
    switch store.siteDraftFileSaveStates[trackedDraftID] {
    case .pending:
      return CoreL10n.text("正在保存到项目…")
    case .saved:
      return CoreL10n.text("已保存到项目")
    case .failed:
      return CoreL10n.text("项目保存失败")
    case nil:
      return draft.repositoryPath?.nilIfEmpty == nil
        ? CoreL10n.text("尚未写入项目")
        : CoreL10n.text("已保存到项目")
    }
  }

  public var hasUnsavedChanges: Bool {
    if store.draftRecoveryJournalErrorMessage?.nilIfEmpty != nil {
      return true
    }
    guard let draft = store.drafts.first(where: { $0.id == trackedDraftID }) else {
      return store.hasUnsavedChanges
    }
    if draft.isGeneralDraft {
      return store.hasUnsavedChanges
    }
    switch store.siteDraftFileSaveStates[trackedDraftID] {
    case .pending, .failed:
      return true
    case .saved, nil:
      return store.hasUnsavedChanges
    }
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
