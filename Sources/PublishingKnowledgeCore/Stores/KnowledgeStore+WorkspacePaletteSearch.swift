import Foundation

@MainActor
extension KnowledgeStore {
  /// Keeps command-palette lookup independent from the library browser's
  /// search text, collection, sort, and current selection.
  public func workspacePaletteSearch(
    query: String,
    limit: Int = 12
  ) async throws -> [KnowledgeSearchResult] {
    try await service.workspacePaletteSearch(query: query, limit: limit)
  }
}
