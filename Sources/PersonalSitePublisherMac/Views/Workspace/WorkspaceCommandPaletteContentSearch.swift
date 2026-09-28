import Combine
import Foundation
import PublishingCoreSupport
import PublishingKnowledgeCore

@MainActor
final class WorkspaceCommandPaletteContentSearch: ObservableObject {
  typealias KnowledgeSearch =
    @MainActor (
      KnowledgeStore, String, Int
    ) async throws -> [KnowledgeSearchResult]
  typealias RSSSearch =
    @MainActor (
      RSSReaderStore, String, Int
    ) async throws -> [RSSWorkspacePaletteSearchResult]

  enum State: Equatable {
    case idle
    case searching
    case ready
    case failed(String)
  }

  static let resultLimit = 12

  @Published private(set) var knowledgeResults: [KnowledgeSearchResult] = []
  @Published private(set) var rssResults: [RSSWorkspacePaletteSearchResult] = []
  @Published private(set) var state: State = .idle
  @Published private(set) var resultsRevision = UUID()

  private var task: Task<Void, Never>?
  private var activeRequestID = UUID()
  private let knowledgeSearch: KnowledgeSearch
  private let rssSearch: RSSSearch
  private let clock: any Clock<Duration>
  private let debounceDuration: Duration

  init(
    knowledgeSearch: @escaping KnowledgeSearch = { store, query, limit in
      try await store.workspacePaletteSearch(query: query, limit: limit)
    },
    rssSearch: @escaping RSSSearch = { store, query, limit in
      try await store.workspacePaletteSearch(query: query, limit: limit)
    },
    clock: any Clock<Duration> = ContinuousClock(),
    debounceDuration: Duration = DebounceIntervals.commandPaletteContent
  ) {
    self.knowledgeSearch = knowledgeSearch
    self.rssSearch = rssSearch
    self.clock = clock
    self.debounceDuration = debounceDuration
  }

  deinit {
    task?.cancel()
  }

  @discardableResult
  func update(
    query: String,
    scope: WorkspaceUnifiedSearchScope,
    moduleVisibility: WorkspaceModuleVisibility,
    knowledge: KnowledgeStore,
    rssStore: RSSReaderStore
  ) -> Task<Void, Never>? {
    task?.cancel()
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestID = UUID()
    activeRequestID = requestID
    let shouldSearchKnowledge = scope.includesResources && moduleVisibility.libraryEnabled
    let shouldSearchRSS = scope.includesRSS && moduleVisibility.rssEnabled
    guard !normalizedQuery.isEmpty, shouldSearchKnowledge || shouldSearchRSS else {
      knowledgeResults = []
      rssResults = []
      state = .idle
      resultsRevision = UUID()
      return nil
    }

    knowledgeResults = []
    rssResults = []
    state = .searching
    resultsRevision = UUID()
    let knowledgeSearch = self.knowledgeSearch
    let rssSearch = self.rssSearch
    let clock = self.clock
    let debounceDuration = self.debounceDuration
    task = Task { [weak self] in
      do {
        try await clock.sleep(for: debounceDuration)
        try Task.checkCancellation()
        async let libraryResults: [KnowledgeSearchResult] =
          shouldSearchKnowledge
          ? knowledgeSearch(knowledge, normalizedQuery, Self.resultLimit)
          : []
        async let archiveResults: [RSSWorkspacePaletteSearchResult] =
          shouldSearchRSS
          ? rssSearch(rssStore, normalizedQuery, Self.resultLimit)
          : []
        let results = try await (libraryResults, archiveResults)
        guard !Task.isCancelled, self?.activeRequestID == requestID else { return }
        self?.knowledgeResults = results.0
        self?.rssResults = results.1
        self?.state = .ready
        self?.resultsRevision = UUID()
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self?.activeRequestID == requestID else { return }
        self?.knowledgeResults = []
        self?.rssResults = []
        self?.state = .failed(error.localizedDescription)
        self?.resultsRevision = UUID()
      }
    }
    return task
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  func waitUntilIdle() async {
    await task?.value
  }
}
