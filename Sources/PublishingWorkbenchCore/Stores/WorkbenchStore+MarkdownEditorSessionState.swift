import Foundation

extension WorkbenchStore {
  public func markdownEditorSessionState(for draftID: UUID) -> MarkdownEditorSessionState {
    publishingStore.markdownEditorSessionStates[draftID] ?? .empty
  }

  public func updateMarkdownEditorSessionState(
    _ state: MarkdownEditorSessionState,
    for draftID: UUID,
    bodyUTF16Count: Int
  ) {
    let normalized = state.normalized(bodyUTF16Count: bodyUTF16Count)
    guard publishingStore.markdownEditorSessionStates[draftID] != normalized else {
      return
    }
    publishingStore.markdownEditorSessionStates[draftID] = normalized
    scheduleAutosave()
  }
}
