import Foundation

extension KnowledgeLibraryService {
  /// A bounded lexical search for the workspace command palette. This stays on
  /// the maintained SQLite full-text index and deliberately does not prepare
  /// semantic models or alter the library browser's query and filter state.
  public func workspacePaletteSearch(
    query: String,
    limit: Int = 12
  ) async throws -> [KnowledgeSearchResult] {
    let normalizedQuery = query.trimmedForPublishing
    guard !normalizedQuery.isEmpty, limit > 0 else { return [] }
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let rawResults = try service.database().search(
        query: normalizedQuery,
        limit: min(limit, 24),
        onlyRemoteAIAllowed: false
      )
      try Task.checkCancellation()
      return rawResults.map { result in
        var explained = result
        explained.signals = service.searchPresentationService.lexicalSignals(
          for: result,
          query: normalizedQuery
        )
        return explained
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
