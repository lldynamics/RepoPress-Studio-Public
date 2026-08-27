import Combine
import Foundation

/// A draft-scoped live projection for the Markdown editor and its Inspector
/// consumers. It observes only the tracked draft's buffer and selection;
/// unrelated drafts and broad PublishingStore mutations stay outside the
/// observation boundary.
@MainActor
public final class WorkbenchMarkdownEditorLiveContextFeatureFacade: ObservableObject {
  private struct Projection: Equatable {
    let bodyMarkdown: String
    let bodyRevision: UInt64
    let activeEditorSelection: ActiveEditorSelection?
    let validatedSelectionRange: NSRange?
  }

  private unowned let store: WorkbenchStore
  private var trackedDraftID: UUID
  private var lastProjection: Projection
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore, draftID: UUID) {
    self.store = store
    trackedDraftID = draftID
    lastProjection = Self.projection(for: draftID, in: store)

    store.publishingStore.draftBodyEditorBufferDidChange
      .sink { [weak self] changedDraftID in
        guard let self, self.trackedDraftID == changedDraftID else { return }
        self.publishProjectionIfChanged()
      }
      .store(in: &cancellables)

    store.publishingStore.activeEditorSelectionDidChange
      .sink { [weak self] changedDraftID in
        guard let self, self.trackedDraftID == changedDraftID else { return }
        self.publishProjectionIfChanged()
      }
      .store(in: &cancellables)
  }

  public var bodyMarkdown: String {
    currentProjection.bodyMarkdown
  }

  public var bodyRevision: UInt64 {
    currentProjection.bodyRevision
  }

  /// The raw active selection for the tracked draft. Consumers that need a
  /// text range should use `validatedSelectionRange` instead.
  public var activeEditorSelection: ActiveEditorSelection? {
    currentProjection.activeEditorSelection
  }

  /// A range is exposed only when its UTF-16 count and selected text still
  /// match the live editor buffer. A zero-length caret remains valid.
  public var validatedSelectionRange: NSRange? {
    currentProjection.validatedSelectionRange
  }

  public func trackDraft(_ draftID: UUID) {
    guard trackedDraftID != draftID else { return }
    trackedDraftID = draftID
    lastProjection = Self.projection(for: draftID, in: store)
    objectWillChange.send()
  }

  private var currentProjection: Projection {
    Self.projection(for: trackedDraftID, in: store)
  }

  private func publishProjectionIfChanged() {
    let projection = currentProjection
    guard projection != lastProjection else { return }
    lastProjection = projection
    objectWillChange.send()
  }

  private static func projection(for draftID: UUID, in store: WorkbenchStore) -> Projection {
    let buffer = store.draftBodyEditorBuffer(for: draftID)
    let selection = store.activeEditorSelection?.draftID == draftID
      ? store.activeEditorSelection
      : nil
    let validatedRange: NSRange?
    if let selection {
      validatedRange = Self.validatedRange(for: selection, in: buffer.bodyMarkdown)
    } else {
      validatedRange = nil
    }
    return Projection(
      bodyMarkdown: buffer.bodyMarkdown,
      bodyRevision: buffer.revision,
      activeEditorSelection: selection,
      validatedSelectionRange: validatedRange
    )
  }

  private static func validatedRange(
    for selection: ActiveEditorSelection,
    in bodyMarkdown: String
  ) -> NSRange? {
    let source = bodyMarkdown as NSString
    let range = selection.range
    guard selection.bodyUTF16Count == source.length,
      range.location >= 0,
      range.length >= 0,
      range.location <= source.length,
      range.length <= source.length - range.location
    else {
      return nil
    }
    guard range.length == 0 || source.substring(with: range) == selection.selectedText else {
      return nil
    }
    return range
  }
}

/// Observation boundary for related-content recommendations. Import progress,
/// search updates and unrelated document details do not invalidate this section.
@MainActor
public final class KnowledgeRelatedChaptersFeatureFacade: ObservableObject {
  private unowned let store: KnowledgeStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: KnowledgeStore) {
    self.store = store
    observe(store.$relatedChapters)
    observe(store.$isLoadingRelatedChapters)
    observe(store.$selectedDocumentID)
    observe(store.$documents)
  }

  public var recommendations: [KnowledgeRelatedChapter] {
    store.relatedChapters
  }

  public var isLoading: Bool {
    store.isLoadingRelatedChapters
  }

  public var usesChapterTerminology: Bool {
    store.selectedDocument?.kind == .book
  }

  public func select(_ recommendation: KnowledgeRelatedChapter) {
    store.selectRelatedChapter(recommendation)
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

/// Observation boundary for the library-health sheet. Selection, search,
/// annotations and recommendation changes stay outside this view.
@MainActor
public final class KnowledgeLibraryHealthFeatureFacade: ObservableObject {
  private unowned let store: KnowledgeStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: KnowledgeStore) {
    self.store = store
    observe(store.$healthSnapshot)
    observe(store.$isLoadingHealth)
    observe(store.$isBusy)
    observe(store.$lastError)
    observe(store.$documents)
  }

  public var healthSnapshot: KnowledgeLibraryHealthSnapshot? {
    store.healthSnapshot
  }

  public var isLoading: Bool {
    store.isLoadingHealth
  }

  public var isBusy: Bool {
    store.isBusy
  }

  public var lastError: String? {
    store.lastError
  }

  public var hasDocuments: Bool {
    !store.documents.isEmpty
  }

  public func documentTitle(for id: UUID) -> String? {
    store.documents.first { $0.id == id }?.title
  }

  public func refreshLibraryHealth() async {
    _ = await store.refreshLibraryHealth()
  }

  public func localContentRepairPreviews() async -> [KnowledgeSourceRefreshPreview]? {
    await store.localContentRepairPreviews()
  }

  public func applyLocalContentRepairs(
    _ previews: [KnowledgeSourceRefreshPreview]
  ) async -> Bool {
    await store.applyLocalContentRepairs(previews)
  }

  public func rebuildAllSemanticIndex() async {
    await store.rebuildAllSemanticIndex()
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

/// Observation boundary for the toolbar preview control. Draft edits,
/// repository scans, AI streaming and deployment polling do not redraw it.
@MainActor
public final class WorkbenchLocalSitePreviewFeatureFacade: ObservableObject {
  private unowned let store: WorkbenchStore
  private var cancellables = Set<AnyCancellable>()

  public init(store: WorkbenchStore) {
    self.store = store
    observe(store.publishingStore.$activeProfileID)
    observe(store.publishingStore.$localSitePreviewPlan)
    observe(store.publishingStore.$localSitePreviewRuntimeStatus)
    observe(store.publishingStore.$localSitePreviewRefreshToken)
  }

  public var activeProfileID: UUID {
    store.activeProfileID
  }

  public var plan: LocalSitePreviewPlan? {
    store.localSitePreviewPlan
  }

  public var runtimeStatus: LocalSitePreviewRuntimeStatus {
    store.localSitePreviewRuntimeStatus
  }

  public var refreshToken: UInt64 {
    store.publishingStore.localSitePreviewRefreshToken
  }

  public func start() -> LocalSitePreviewStartDisposition {
    store.publishingStore.refreshLocalSitePreviewPlan(
      for: store.activeProfile,
      repositoryReport: store.repositoryReport(for: store.activeProfile)
    )
    return store.publishingStore.startLocalSitePreview()
  }

  public func authorizeAndStart(
    _ request: LocalSitePreviewAuthorizationRequest
  ) -> LocalSitePreviewStartDisposition {
    store.publishingStore.authorizeAndStartLocalSitePreview(request)
  }

  public func stop() {
    store.stopLocalSitePreview()
  }

  public func refreshStatus() {
    store.refreshLocalSitePreviewRuntimeStatus()
  }

  public func reload() {
    store.publishingStore.reloadLocalSitePreview()
  }

  public func verifyReachability() async {
    await store.verifyLocalSitePreviewReachability()
  }

  public func openSettings() {
    store.selectSection(.sync)
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

/// Observation boundary for the repository workspace. Repository operations
/// are intentionally observed as one cohesive feature store, while publishing
/// updates are limited to the active profile, selected draft metadata and the
/// preview/release state rendered by this workspace. AI streams, editor body
/// buffers, knowledge imports and maintenance progress remain outside it.
@MainActor
public final class WorkbenchRepositoryWorkspaceObservationFacade: ObservableObject {
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    store.repositoryStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    observe(
      Publishers.CombineLatest(
        store.publishingStore.$profiles,
        store.publishingStore.$activeProfileID
      )
      .compactMap { profiles, activeProfileID in
        profiles.first(where: { $0.id == activeProfileID })
      }
      .removeDuplicates()
    )
    observe(
      Publishers.CombineLatest(
        store.publishingStore.$drafts,
        store.publishingStore.$selectedDraftID
      )
      .map { drafts, selectedDraftID in
        selectedDraftID.flatMap { selectedDraftID in
          drafts.first(where: { $0.id == selectedDraftID })?.metadataProjection
        }
      }
      .removeDuplicates()
    )
    observe(store.publishingStore.$localPublishReadiness)
    observe(store.publishingStore.$remotePublishPreviewSnapshot)
    observe(store.publishingStore.$localSitePreviewPlan)
    observe(store.publishingStore.$localSitePreviewRuntimeStatus)
    observe(store.publishingStore.$publishActionFeedback)
    observe(store.publishingStore.$releaseRecords)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

/// Observation boundary for release history. It follows only the release
/// ledger, remote-publish busy state and deployment status/polling inputs used
/// by that page, avoiding redraws from unrelated workbench features.
@MainActor
public final class WorkbenchReleaseHistoryObservationFacade: ObservableObject {
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    observe(
      Publishers.CombineLatest(
        store.publishingStore.$profiles,
        store.publishingStore.$activeProfileID
      )
      .compactMap { profiles, activeProfileID in
        profiles.first(where: { $0.id == activeProfileID })
      }
      .removeDuplicates()
    )
    observe(store.publishingStore.$releaseRecords)
    observe(store.publishingStore.$publishActionFeedback)
    observe(store.repositoryStore.$isRemoteRepositoryPublishing)
    observe(store.repositoryStore.$localRepositoryReleaseHistory)
    observe(store.deploymentStore.$deploymentStatusSnapshots)
    observe(store.deploymentStore.$deploymentStatusHistory)
    observe(store.deploymentStore.$isDeploymentStatusChecking)
    observe(store.deploymentStore.$deploymentStatusMessage)
    observe(store.deploymentStore.$deploymentPollingSettings)
    observe(store.deploymentStore.$deploymentPollingState)
    observe(store.deploymentStore.$deploymentTokenAvailability)
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}

/// Observation boundary for the Site Starter wizard. It follows only the
/// active site, Starter results and the repository/deployment state rendered
/// by the wizard; editor, AI, knowledge and maintenance updates stay outside.
@MainActor
public final class WorkbenchSiteStarterObservationFacade: ObservableObject {
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore) {
    observe(
      Publishers.CombineLatest(
        store.publishingStore.$profiles,
        store.publishingStore.$activeProfileID
      )
      .compactMap { profiles, activeProfileID in
        profiles.first(where: { $0.id == activeProfileID })
      }
      .removeDuplicates()
    )
    observe(store.publishingStore.$siteStarterResult)
    observe(store.publishingStore.$siteStarterImportResult)
    observe(store.publishingStore.$siteStarterPushResult)
    observe(store.publishingStore.$isSiteStarterOperationRunning)
    observe(store.publishingStore.$isLocalRepositoryMutationRunning)
    observe(store.publishingStore.$publishActionFeedback)
    observe(store.repositoryStore.$isRemoteRepositoryChecking)
    observe(store.repositoryStore.$remoteRepositoryCreationResult)
    observe(store.repositoryStore.$remoteRepositoryAccessCheck)
    observe(store.repositoryStore.$remoteRepositoryAccessCheckByProfileID)
    observe(store.repositoryStore.$repositoryTokenAvailability)
    observe(store.deploymentStore.$deploymentStatusMessage)
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .dropFirst()
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }
}
