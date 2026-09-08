import Foundation

/// The sidebar projection is deliberately narrower than editor and publish state.
/// Keep the impact policy independent of Store observation and persistence.
enum DraftChangeImpact: Equatable {
  case listMetadata
  case editorMetadata
  case body(imageReferencesChanged: Bool)

  init(previous: ArticleDraft?, updated: ArticleDraft) {
    guard let previous, previous.hasSameListMetadata(as: updated) else {
      self = .listMetadata
      return
    }
    guard previous.hasSameEditorMetadata(as: updated) else {
      self = .editorMetadata
      return
    }
    self = .body(
      imageReferencesChanged:
        ImageWorkbenchMarkdownReferenceSignature(markdown: previous.bodyMarkdown)
        != ImageWorkbenchMarkdownReferenceSignature(markdown: updated.bodyMarkdown))
  }
}
