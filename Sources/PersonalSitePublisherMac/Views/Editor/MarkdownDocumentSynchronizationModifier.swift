import SwiftUI

struct MarkdownDocumentSynchronizationModifier: ViewModifier {
  let editorDocument: String
  let editorBody: String
  let canonicalFrontMatter: String
  let onEditorDocumentChange: (String, String) -> Void
  let onEditorBodyChange: (String, String) -> Void
  let onCanonicalFrontMatterChange: (String) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: editorDocument) { previousDocument, updatedDocument in
        onEditorDocumentChange(previousDocument, updatedDocument)
      }
      .onChange(of: editorBody) { previousBody, updatedBody in
        onEditorBodyChange(previousBody, updatedBody)
      }
      .onChange(of: canonicalFrontMatter) { _, updatedFrontMatter in
        onCanonicalFrontMatterChange(updatedFrontMatter)
      }
  }
}

/// Delayed observer snapshots must match the entire rendered body, not merely
/// a suffix (every document has an empty suffix).
enum MarkdownDocumentBodyBoundary {
  static func prefix(in document: String, bodyUTF16Offset: Int, matchingBody: String) -> String? {
    let source = document as NSString
    guard bodyUTF16Offset >= 0, bodyUTF16Offset <= source.length,
      source.substring(from: bodyUTF16Offset) == matchingBody
    else { return nil }
    return source.substring(to: bodyUTF16Offset)
  }
}
