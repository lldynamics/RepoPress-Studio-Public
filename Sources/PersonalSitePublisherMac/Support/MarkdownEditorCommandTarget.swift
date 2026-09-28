import AppKit

/// One mounted editor, retained by its composer session. Menu commands must
/// drain this editor's coalesced input, not every window's native editor.
@MainActor
final class MarkdownEditorCommandTarget {
  weak var coordinator: MacMarkdownTextView.Coordinator?
  var documentID: UUID?

  func flushPendingWrites(for expectedDocumentID: UUID? = nil) -> Bool {
    guard expectedDocumentID == nil || documentID == expectedDocumentID else { return false }
    guard let coordinator, let textView = coordinator.textView,
      !textView.hasMarkedText()
    else { return false }
    coordinator.flushPendingBindingWrites(notifyingDocumentCommit: true)
    return true
  }
}
