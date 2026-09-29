import Foundation

extension KnowledgeStore {
  /// Reads one document's history without changing the shared inspector selection.
  public func revisionsForHistory(documentID: UUID) async throws -> [KnowledgeDocumentRevision] {
    try await service.revisionsAsync(documentID: documentID)
  }
}
