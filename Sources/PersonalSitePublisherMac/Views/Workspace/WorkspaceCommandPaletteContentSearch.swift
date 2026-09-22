import Combine
import Foundation
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

  init(
    knowledgeSearch: @escaping KnowledgeSearch = { store, query, limit in
      try await store.workspacePaletteSearch(query: query, limit: limit)
    },
    rssSearch: @escaping RSSSearch = { store, query, limit in
      try await store.workspacePaletteSearch(query: query, limit: limit)
    }
  ) {
    self.knowledgeSearch = knowledgeSearch
    self.rssSearch = rssSearch
  }

  deinit {
    task?.cancel()
  }

  func update(
    query: String,
    scope: WorkspaceUnifiedSearchScope,
    knowledge: KnowledgeStore,
    rssStore: RSSReaderStore
  ) {
    task?.cancel()
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestID = UUID()
    activeRequestID = requestID
    guard !normalizedQuery.isEmpty, scope.includesResources || scope.includesRSS else {
      knowledgeResults = []
      rssResults = []
      state = .idle
      resultsRevision = UUID()
      return
    }

    knowledgeResults = []
    rssResults = []
    state = .searching
    resultsRevision = UUID()
    let knowledgeSearch = self.knowledgeSearch
    let rssSearch = self.rssSearch
    task = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(180))
        try Task.checkCancellation()
        async let libraryResults: [KnowledgeSearchResult] =
          scope.includesResources
          ? knowledgeSearch(knowledge, normalizedQuery, Self.resultLimit)
          : []
        async let archiveResults: [RSSWorkspacePaletteSearchResult] =
          scope.includesRSS
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
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}
