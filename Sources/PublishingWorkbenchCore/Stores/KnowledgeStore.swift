import Combine
import Foundation

@MainActor
public final class KnowledgeStore: ObservableObject {
  let service: KnowledgeLibraryService
  private let operationEventRecorder:
    (@MainActor @Sendable (WorkbenchOperationEventRecord) -> Void)?
  let smartCollectionService = KnowledgeSmartCollectionService()
  var searchTask: Task<Void, Never>?
  var selectedTextTask: Task<Void, Never>?
  var selectedCapturedTextTask: Task<Void, Never>?
  var relatedChaptersTask: Task<Void, Never>?
  var documentInsightsTask: Task<Void, Never>?
  var articleBacklinksTask: Task<Void, Never>?
  var articleBacklinksTargetID: String?
  var startupReloadTask: Task<Void, Never>?
  /// Test-only synchronization point for proving that an accepted write still
  /// refreshes its projection when the initiating UI task is cancelled.
  var afterAcceptedMutationBeforeProjection: (@MainActor () async -> Void)?
  private var knowledgeMutationTail: Task<Void, Never>?
  private var knowledgeMutationTailGeneration: UInt64 = 0
  private var acceptedKnowledgeMutationGeneration: UInt64 = 0
  private var busyOperationIDs = Set<UUID>()
  var lastImportRetryAction: (@MainActor () async -> Void)?
  var visibleDocumentsCacheRevision: UInt64?
  var visibleDocumentsCache: [KnowledgeDocument] = []
  var visibleSearchResultsCacheRevision: UInt64?
  var visibleSearchResultsCache: [KnowledgeSearchResult] = []
  #if DEBUG
    private(set) var visibleDocumentsSnapshotBuildCount = 0
    private(set) var visibleSearchResultsSnapshotBuildCount = 0
  #endif

  @Published public internal(set) var listPresentationRevision: UInt64 = 0
  @Published public internal(set) var documents: [KnowledgeDocument] = [] {
    didSet { invalidateListPresentation() }
  }
  @Published public internal(set) var recycledDocuments: [KnowledgeRecycledDocument] = []
  @Published public internal(set) var folders: [KnowledgeFolder] = []
  @Published public internal(set) var searchResults: [KnowledgeSearchResult] = [] {
    didSet { invalidateListPresentation() }
  }
  @Published public internal(set) var selectedSearchResult: KnowledgeSearchResult?
  @Published public internal(set) var selectedResultQuery = ""
  @Published public var selectedDocumentID: UUID?
  @Published public internal(set) var folderScope: KnowledgeFolderScope = .all {
    didSet { invalidateListPresentation() }
  }
  @Published public internal(set) var documentSort = KnowledgeDocumentSort() {
    didSet { invalidateListPresentation() }
  }
  @Published public internal(set) var searchFilter = KnowledgeSearchFilter() {
    didSet { invalidateListPresentation() }
  }
  @Published public internal(set) var selectedDocumentText = ""
  @Published public internal(set) var isLoadingSelectedDocumentText = false
  @Published public internal(set) var selectedDocumentTextError: String?
  @Published public internal(set) var selectedDocumentCapturedText: String?
  @Published public internal(set) var isLoadingSelectedDocumentCapturedText = false
  @Published public internal(set) var selectedDocumentCapturedTextError: String?
  @Published public internal(set) var searchText = "" {
    didSet { invalidateListPresentation() }
  }
  @Published public internal(set) var isSearching = false
  @Published public internal(set) var isBusy = false
  @Published public internal(set) var isImporting = false
  @Published public internal(set) var importProgress: Double?
  @Published public internal(set) var importOperationTitle: String?
  @Published public internal(set) var lastImportFailure: String?
  @Published public internal(set) var statusMessage: String?
  @Published public internal(set) var lastError: String?
  @Published public internal(set) var pinnedDocumentIDs: Set<UUID> = []
  @Published public internal(set) var relatedChapters: [KnowledgeRelatedChapter] = []
  @Published public internal(set) var isLoadingRelatedChapters = false
  @Published public internal(set) var annotations: [KnowledgeAnnotation] = []
  @Published public internal(set) var backlinks: [KnowledgeBacklink] = []
  @Published public internal(set) var articleBacklinks: [KnowledgeBacklink] = []
  @Published public internal(set) var isLoadingArticleBacklinks = false
  @Published public internal(set) var revisions: [KnowledgeDocumentRevision] = []
  @Published public internal(set) var healthSnapshot: KnowledgeLibraryHealthSnapshot?
  @Published public internal(set) var isLoadingHealth = false

  public init(
    service: KnowledgeLibraryService = KnowledgeLibraryService(),
    operationEventRecorder:
      (@MainActor @Sendable (WorkbenchOperationEventRecord) -> Void)? = nil
  ) {
    self.service = service
    self.operationEventRecorder = operationEventRecorder
    startupReloadTask = Task { [weak self] in
      guard let self else { return }
      await performReload()
      startupReloadTask = nil
    }
  }

  func recordKnowledgeImportEvent(
    outcome: WorkbenchOperationLogOutcome,
    result: KnowledgeImportResult? = nil
  ) {
    operationEventRecorder?(
      WorkbenchOperationEventRecord(
        kind: .knowledgeImport,
        outcome: outcome,
        createdItemCount: result?.insertedCount,
        updatedItemCount: result?.updatedCount,
        skippedItemCount: result?.skippedCount
      )
    )
  }

  func knowledgeImportOutcome(for result: KnowledgeImportResult) -> WorkbenchOperationLogOutcome {
    let changedCount = result.insertedCount + result.updatedCount
    if changedCount > 0, result.skippedCount > 0 { return .partial }
    if changedCount > 0 { return .succeeded }
    return .recorded
  }

  public var rootURL: URL {
    service.rootURL
  }

  deinit {
    searchTask?.cancel()
    selectedTextTask?.cancel()
    selectedCapturedTextTask?.cancel()
    relatedChaptersTask?.cancel()
    documentInsightsTask?.cancel()
    articleBacklinksTask?.cancel()
    startupReloadTask?.cancel()
    knowledgeMutationTail?.cancel()
  }

  public var selectedDocument: KnowledgeDocument? {
    guard let selectedDocumentID else { return nil }
    return documents.first { $0.id == selectedDocumentID }
  }

  public var smartCollections: [KnowledgeSmartCollection] {
    smartCollectionService.collections(for: documents)
  }

  public var backlinkGroups: [KnowledgeBacklinkGroup] {
    Dictionary(grouping: backlinks) { backlink in
      "\(backlink.targetKind.rawValue):\(backlink.targetID)"
    }
    .values
    .compactMap(KnowledgeBacklinkGroup.init(backlinks:))
    .sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
      return $0.id < $1.id
    }
  }

  public func smartCollections(
    kind: KnowledgeSmartCollectionKind
  ) -> [KnowledgeSmartCollection] {
    smartCollections.filter { $0.rule.kind == kind }
  }

  public func smartCollection(
    rule: KnowledgeSmartCollectionRule
  ) -> KnowledgeSmartCollection? {
    smartCollections.first { $0.rule == rule }
  }

  public var visibleDocuments: [KnowledgeDocument] {
    if visibleDocumentsCacheRevision == listPresentationRevision {
      return visibleDocumentsCache
    }
    let candidates: [KnowledgeDocument]
    if searchText.trimmedForPublishing.isEmpty {
      candidates = documents
    } else {
      var seen = Set<UUID>()
      candidates = visibleSearchResults.compactMap { result in
        seen.insert(result.document.id).inserted ? result.document : nil
      }
    }
    let filtered =
      searchText.trimmedForPublishing.isEmpty
      ? candidates.filter(isIncludedInCurrentScope)
      : candidates
    let result = documentSort.sorted(filtered)
    #if DEBUG
      visibleDocumentsSnapshotBuildCount += 1
    #endif
    visibleDocumentsCache = result
    visibleDocumentsCacheRevision = listPresentationRevision
    return result
  }

  public var visibleSearchResults: [KnowledgeSearchResult] {
    if visibleSearchResultsCacheRevision == listPresentationRevision {
      return visibleSearchResultsCache
    }
    let result = searchFilter.filtered(
      searchResults,
      isInCurrentCollection: isIncludedInCurrentScope
    )
    #if DEBUG
      visibleSearchResultsSnapshotBuildCount += 1
    #endif
    visibleSearchResultsCache = result
    visibleSearchResultsCacheRevision = listPresentationRevision
    return result
  }

  private func invalidateListPresentation() {
    listPresentationRevision &+= 1
    visibleDocumentsCacheRevision = nil
    visibleSearchResultsCacheRevision = nil
  }

  /// Keeps the presentation busy state truthful when several asynchronous
  /// knowledge operations overlap. Every operation receives its own lease, so
  /// one completion cannot mark the store idle while another is still running.
  func beginBusyOperation() -> UUID {
    let operationID = UUID()
    busyOperationIDs.insert(operationID)
    isBusy = true
    return operationID
  }

  func finishBusyOperation(_ operationID: UUID) {
    busyOperationIDs.remove(operationID)
    isBusy = !busyOperationIDs.isEmpty
  }

  /// Serializes all Store-originated knowledge writes in FIFO order. The tail
  /// is intentionally never cancelled by a waiting caller: once accepted, a
  /// persistence request either reaches the service or reports its real error.
  func performQueuedKnowledgeMutation(
    _ operation: @escaping @MainActor () async -> Void
  ) async {
    acceptedKnowledgeMutationGeneration &+= 1
    let generation = acceptedKnowledgeMutationGeneration
    let predecessor = knowledgeMutationTail
    let task = Task { @MainActor in
      if let predecessor { await predecessor.value }
      await operation()
    }
    knowledgeMutationTail = task
    knowledgeMutationTailGeneration = generation
    await task.value
  }

  func performQueuedKnowledgeMutation<T: Sendable>(
    _ operation: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    acceptedKnowledgeMutationGeneration &+= 1
    let generation = acceptedKnowledgeMutationGeneration
    let predecessor = knowledgeMutationTail
    let resultTask = Task<T, Error> { @MainActor in
      if let predecessor { await predecessor.value }
      return try await operation()
    }
    let tail = Task<Void, Never> {
      do {
        _ = try await resultTask.value
      } catch {
        // The result task's caller observes the error; the FIFO tail only waits
        // for completion so a failed mutation cannot block later requests.
      }
    }
    knowledgeMutationTail = tail
    knowledgeMutationTailGeneration = generation
    return try await resultTask.value
  }

  func flushKnowledgeMutations() async {
    while let tail = knowledgeMutationTail {
      let generation = knowledgeMutationTailGeneration
      await tail.value
      guard knowledgeMutationTailGeneration == generation else { continue }
      return
    }
  }

  func currentKnowledgeMutationGeneration() -> UInt64 {
    acceptedKnowledgeMutationGeneration
  }

  func waitAfterAcceptedMutationBeforeProjection() async {
    await afterAcceptedMutationBeforeProjection?()
  }
}
