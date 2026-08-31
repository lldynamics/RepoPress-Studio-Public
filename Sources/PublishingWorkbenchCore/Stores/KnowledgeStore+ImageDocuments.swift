import Foundation

@MainActor
extension KnowledgeStore {
  /// Resolves the selected revision's managed original for image preview or
  /// insertion. No external source URL is consulted.
  public func originalFileURL(documentID: UUID) async -> URL? {
    do {
      return try await service.originalFileURLAsync(documentID: documentID)
    } catch {
      return nil
    }
  }
}
