import Foundation

extension PublishingStore {
  public func updateActiveEditorSelection(
    draftID: UUID,
    windowID: UUID? = nil,
    selectedRange: NSRange,
    selectedText: String,
    bodyUTF16Count: Int
  ) {
    let selection = ActiveEditorSelection(
      draftID: draftID, windowID: windowID, range: selectedRange,
      selectedText: selectedText, bodyUTF16Count: bodyUTF16Count
    )
    if activeEditorSelection != selection {
      let previousDraftID = activeEditorSelection?.draftID
      activeEditorSelection = selection
      if let previousDraftID, previousDraftID != draftID {
        activeEditorSelectionDidChange.send(previousDraftID)
      }
      activeEditorSelectionDidChange.send(draftID)
    }
  }

  public func clearActiveEditorSelection(for draftID: UUID? = nil, windowID: UUID? = nil) {
    guard let activeEditorSelection,
      draftID == nil || activeEditorSelection.draftID == draftID,
      windowID == nil || activeEditorSelection.windowID == windowID
    else { return }
    let clearedDraftID = activeEditorSelection.draftID
    self.activeEditorSelection = nil
    activeEditorSelectionDidChange.send(clearedDraftID)
  }

  public func activeEditorSelectionRange(
    for draft: ArticleDraft,
    windowID: UUID? = nil
  ) -> NSRange? {
    guard windowID == nil || activeEditorSelection?.windowID == windowID else { return nil }
    return activeEditorSelection?.validatedRange(in: draft)
  }
}
