import Foundation

extension WorkbenchStore {
  public func updateActiveEditorSelection(
    draftID: UUID,
    windowID: UUID? = nil,
    selectedRange: NSRange,
    selectedText: String,
    bodyUTF16Count: Int
  ) {
    publishingStore.updateActiveEditorSelection(
      draftID: draftID, windowID: windowID, selectedRange: selectedRange,
      selectedText: selectedText, bodyUTF16Count: bodyUTF16Count
    )
  }

  public func clearActiveEditorSelection(for draftID: UUID? = nil, windowID: UUID? = nil) {
    publishingStore.clearActiveEditorSelection(for: draftID, windowID: windowID)
  }

  public func activeEditorSelectionRange(
    for draft: ArticleDraft,
    windowID: UUID? = nil
  ) -> NSRange? {
    publishingStore.activeEditorSelectionRange(for: draft, windowID: windowID)
  }
}
