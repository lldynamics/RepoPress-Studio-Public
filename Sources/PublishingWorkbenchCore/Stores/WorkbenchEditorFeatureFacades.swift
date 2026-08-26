import Combine
import Foundation

private struct WorkbenchEditorNavigationDraftIdentity: Equatable {
  let selectedDraftID: UUID?
  let selectedDraftExists: Bool
}

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
    observeValue(store.publishingStore.$selectedSection)
    observeValue(store.publishingStore.$draftListContentScope)
    observeDraftIdentity()
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

  private func observeDraftIdentity() {
    Publishers.CombineLatest(
      store.publishingStore.$selectedDraftID,
      store.publishingStore.$drafts
    )
    .map { selectedDraftID, drafts in
      WorkbenchEditorNavigationDraftIdentity(
        selectedDraftID: selectedDraftID,
        selectedDraftExists: selectedDraftID.map { selectedDraftID in
          drafts.contains { $0.id == selectedDraftID }
        } ?? false
      )
    }
    .removeDuplicates()
    .dropFirst()
    .sink { [weak self] _ in self?.scheduleChangeNotification() }
    .store(in: &cancellables)
  }

  private func scheduleChangeNotification() {
    guard !isChangeNotificationScheduled else { return }
    isChangeNotificationScheduled = true

    // The upstream @Published notification arrives from willSet. Register the
    // deferred invalidation in normal and AppKit event-tracking modes so its
    // getters can expose the committed selection in either path.
    RunLoop.main.perform(inModes: [
      .default,
      RunLoop.Mode("NSEventTrackingRunLoopMode"),
    ]) { [weak self] in
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

private struct WorkbenchMarkdownEditorSaveDraftContext: Equatable {
  let exists: Bool
  let isGeneralDraft: Bool
  let repositoryPath: String?
}

@MainActor
private enum WorkbenchMarkdownEditorSaveStatusProjection {
  static func lastSaveStatus(in store: WorkbenchStore, draftID: UUID) -> String {
    if let recoveryError = store.draftRecoveryJournalErrorMessage?.nilIfEmpty {
      return recoveryError
    }
    guard let draft = store.drafts.first(where: { $0.id == draftID }) else {
      return store.lastSaveStatus
    }
    if draft.isGeneralDraft {
      return store.hasUnsavedChanges
        ? CoreL10n.text("正在保存到软件…")
        : CoreL10n.text("已保存在软件")
    }
    switch store.siteDraftFileSaveStates[draftID] {
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

  static func hasUnsavedChanges(in store: WorkbenchStore, draftID: UUID) -> Bool {
    if store.draftRecoveryJournalErrorMessage?.nilIfEmpty != nil {
      return true
    }
    guard let draft = store.drafts.first(where: { $0.id == draftID }) else {
      return store.hasUnsavedChanges
    }
    if draft.isGeneralDraft {
      return store.hasUnsavedChanges
    }
    switch store.siteDraftFileSaveStates[draftID] {
    case .pending, .failed:
      return true
    case .saved, nil:
      return store.hasUnsavedChanges
    }
  }
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
    observeValue(store.publishingStore.$editorFocusRequest)
    observeValue(store.aiWorkspaceStore.$aiTokenAvailability)
    observeValue(store.aiWorkspaceStore.$isAIActionRunning)

    store.aiStore.$aiDraftSuggestionStateRevision
      .map { [weak self] _ -> AIPublishingMetadataSuggestion? in
        guard let self else { return nil }
        return self.store.aiMetadataSuggestion(for: self.trackedDraftID)
      }
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

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
    WorkbenchMarkdownEditorSaveStatusProjection.lastSaveStatus(
      in: store,
      draftID: trackedDraftID
    )
  }

  public var hasUnsavedChanges: Bool {
    WorkbenchMarkdownEditorSaveStatusProjection.hasUnsavedChanges(
      in: store,
      draftID: trackedDraftID
    )
  }

  public var isAIActionRunning: Bool {
    store.isAIActionRunning
  }

  public var aiTokenAvailability: KeychainTokenAvailability {
    store.aiTokenAvailability
  }

  public var aiMetadataSuggestion: AIPublishingMetadataSuggestion? {
    store.aiMetadataSuggestion(for: trackedDraftID)
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

/// A toolbar-scoped save projection. Persistence transitions should repaint
/// the save indicator without invalidating the 100k-character composer root.
@MainActor
public final class WorkbenchMarkdownEditorSaveStatusFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var trackedDraftID: UUID
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore, draftID: UUID) {
    self.store = store
    trackedDraftID = draftID
    observeValue(store.persistenceStore.$hasUnsavedChanges)
    observeValue(store.persistenceStore.$status)
    observeValue(store.$draftRecoveryJournalErrorMessage)

    store.$siteDraftFileSaveStates
      .map { [weak self] states in
        self.flatMap { states[$0.trackedDraftID] }
      }
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    store.publishingStore.$drafts
      .map { [weak self] drafts -> WorkbenchMarkdownEditorSaveDraftContext? in
        guard let self else { return nil }
        guard let draft = drafts.first(where: { $0.id == self.trackedDraftID }) else {
          return WorkbenchMarkdownEditorSaveDraftContext(
            exists: false,
            isGeneralDraft: false,
            repositoryPath: nil
          )
        }
        return WorkbenchMarkdownEditorSaveDraftContext(
          exists: true,
          isGeneralDraft: draft.isGeneralDraft,
          repositoryPath: draft.repositoryPath
        )
      }
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  public var lastSaveStatus: String {
    WorkbenchMarkdownEditorSaveStatusProjection.lastSaveStatus(
      in: store,
      draftID: trackedDraftID
    )
  }

  public var hasUnsavedChanges: Bool {
    WorkbenchMarkdownEditorSaveStatusProjection.hasUnsavedChanges(
      in: store,
      draftID: trackedDraftID
    )
  }

  public func trackDraft(_ draftID: UUID) {
    guard trackedDraftID != draftID else { return }
    trackedDraftID = draftID
    objectWillChange.send()
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
