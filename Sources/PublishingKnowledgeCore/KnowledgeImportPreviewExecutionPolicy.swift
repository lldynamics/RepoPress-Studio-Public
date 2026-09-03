import Foundation

package enum KnowledgeImportPreviewExecutionPolicy {
  package static func priority(
    for sourceURLs: [URL],
    sourceTreeContainsPDF: Bool = false
  ) -> TaskPriority {
    if sourceTreeContainsPDF
      || sourceURLs.contains(where: {
        ["pdf", "jpg", "jpeg", "png", "heic", "heif", "webp"].contains(
          $0.pathExtension.lowercased())
      })
    {
      return .background
    }
    return .userInitiated
  }
}
