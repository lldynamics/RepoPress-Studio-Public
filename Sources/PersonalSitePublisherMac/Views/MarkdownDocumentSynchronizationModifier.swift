import SwiftUI

struct MarkdownDocumentSynchronizationModifier: ViewModifier {
  let editorDocument: String
  let editorBody: String
  let canonicalFrontMatter: String
  let onEditorDocumentChange: (String) -> Void
  let onEditorBodyChange: (String, String) -> Void
  let onCanonicalFrontMatterChange: (String) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: editorDocument) { _, updatedDocument in
        onEditorDocumentChange(updatedDocument)
      }
      .onChange(of: editorBody) { previousBody, updatedBody in
        onEditorBodyChange(previousBody, updatedBody)
      }
      .onChange(of: canonicalFrontMatter) { _, updatedFrontMatter in
        onCanonicalFrontMatterChange(updatedFrontMatter)
      }
  }
}
