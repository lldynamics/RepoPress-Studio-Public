import Foundation

enum KnowledgeSourceListContextActionSelection {
  static func documentIDs(
    contextDocumentID: UUID,
    selectedDocumentIDs: Set<UUID>,
    isDocumentListSelectionActive: Bool
  ) -> Set<UUID> {
    guard
      isDocumentListSelectionActive,
      selectedDocumentIDs.contains(contextDocumentID)
    else {
      return [contextDocumentID]
    }
    return selectedDocumentIDs
  }
}
