import Combine
import Foundation

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

  public func start() {
    store.startLocalSitePreview()
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
