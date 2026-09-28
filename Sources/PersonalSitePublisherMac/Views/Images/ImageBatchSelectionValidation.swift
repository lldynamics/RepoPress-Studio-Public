import Foundation

struct ImageBatchPreviewContext {
  let source: RepositoryImageInventorySource
  let imageRevision: UInt64
}

enum ImageBatchSelectionValidation {
  static func isValid(
    _ selection: [UUID: Set<UUID>], affectedItems: [ImageBatchAffectedItem],
    draftAttachmentPaths: [UUID: [UUID: String]]
  ) -> Bool {
    guard !selection.isEmpty, selection.values.contains(where: { !$0.isEmpty }) else {
      return false
    }
    let previews = Dictionary(grouping: affectedItems, by: \.draftID)
    return selection.allSatisfy { draftID, attachmentIDs in
      guard let paths = draftAttachmentPaths[draftID], let items = previews[draftID] else {
        return false
      }
      return attachmentIDs.allSatisfy { id in
        guard let preview = items.first(where: { $0.item.attachmentID == id }) else { return false }
        return paths[id] == preview.item.repositoryPath
      }
    }
  }
}
