import Combine
import Foundation
import PublishingCoreSupport
import PublishingWorkbenchCore

@MainActor
final class WorkspaceCommandPaletteArticleSearch: ObservableObject {
  typealias Search = @Sendable (String, [ArticleDraft], Int) async -> [DraftFullTextSearchHit]
  typealias Debounce = @Sendable (Duration) async throws -> Void

  static let resultLimit = 120

  @Published private(set) var snapshot = DraftFullTextSearchPresentationSnapshot.empty
  @Published private(set) var isSearching = false
  @Published private(set) var protectedPrivateDraftCount = 0
  @Published private(set) var resultsRevision = UUID()

  private var task: Task<Void, Never>?
  private var activeRequestID = UUID()
  private let search: Search
  private let debounce: Debounce

  init(
    search: @escaping Search = WorkspaceCommandPaletteArticleSearch.defaultSearch,
    clock: any Clock<Duration> = ContinuousClock(),
    debounce: Debounce? = nil
  ) {
    self.search = search
    self.debounce = debounce ?? { duration in try await clock.sleep(for: duration) }
  }

  deinit {
    task?.cancel()
  }

  @discardableResult
  func update(
    query: String,
    scope: WorkspaceUnifiedSearchScope,
    articleScope: DraftFullTextSearchScope,
    activeProfileID: UUID,
    inputs: [DraftFullTextSearchInput],
    masksPrivateContent: Bool
  ) -> Task<Void, Never>? {
    task?.cancel()
    let requestID = UUID()
    activeRequestID = requestID
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard scope.includesArticles, !normalizedQuery.isEmpty else {
      clearResults()
      return nil
    }

    let scopedInputs = inputs.filter { input in
      articleScope.includes(input.draft, activeProfileID: activeProfileID)
    }
    let protectedPrivateDraftCount =
      masksPrivateContent
      ? scopedInputs.count(where: { $0.draft.isPrivate })
      : 0

    snapshot = .empty
    self.protectedPrivateDraftCount = protectedPrivateDraftCount
    isSearching = true
    resultsRevision = UUID()

    let search = self.search
    let debounce = self.debounce
    let resultLimit = Self.resultLimit
    task = Task { [weak self] in
      do {
        try await debounce(DebounceIntervals.commandPaletteArticles)
        try Task.checkCancellation()

        let worker = Task.detached(priority: .userInitiated) {
          let searchableDrafts = DraftFullTextSearchPreparation.prepare(
            inputs: scopedInputs,
            masksPrivateContent: masksPrivateContent
          )
          let hits = await search(normalizedQuery, searchableDrafts, resultLimit)
          return DraftFullTextSearchPresentationSnapshot(hits: hits)
        }
        let result = await withTaskCancellationHandler(
          operation: { await worker.value },
          onCancel: { worker.cancel() }
        )
        guard !Task.isCancelled, self?.activeRequestID == requestID else { return }
        self?.snapshot = result
        self?.isSearching = false
        self?.resultsRevision = UUID()
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self?.activeRequestID == requestID else { return }
        self?.clearResults()
      }
    }
    return task
  }

  func cancel() {
    task?.cancel()
    task = nil
    activeRequestID = UUID()
    isSearching = false
  }

  func waitUntilIdle() async {
    await task?.value
  }

  private func clearResults() {
    task = nil
    snapshot = .empty
    isSearching = false
    protectedPrivateDraftCount = 0
    resultsRevision = UUID()
  }

  nonisolated private static func defaultSearch(
    query: String,
    drafts: [ArticleDraft],
    limit: Int
  ) async -> [DraftFullTextSearchHit] {
    DraftFullTextSearchService().search(query: query, drafts: drafts, limit: limit)
  }

}
