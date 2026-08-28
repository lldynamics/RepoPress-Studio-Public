import Foundation

@MainActor
extension KnowledgeStore {
  /// Resolves the selected revision's managed original for image preview or
  /// insertion. No external source URL is consulted.
  public func originalFileURL(documentID: UUID) -> URL? {
    do {
      return try service.originalFileURL(documentID: documentID)
    } catch {
      return nil
    }
  }
}
