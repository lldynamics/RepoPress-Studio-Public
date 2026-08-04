import Foundation

extension WorkbenchStore {
  @discardableResult
  public func appendLocalWhisperTranscript(_ transcript: String) -> Bool {
    guard let selectedDraft else {
      setAIActionMessage(CoreL10n.text("请先选择一篇文章，再插入本地 Whisper 转写。"))
      return false
    }
    let buffer = draftBodyEditorBuffer(for: selectedDraft.id)
    var updatedDraft = selectedDraft
    if buffer.isDirty {
      updatedDraft.bodyMarkdown = buffer.bodyMarkdown
    }
    let normalized = transcript.trimmedForPublishing
    guard !normalized.isEmpty else { return false }
    let separator = updatedDraft.bodyMarkdown.trimmedForPublishing.isEmpty ? "" : "\n\n"
    updatedDraft.bodyMarkdown = updatedDraft.bodyMarkdown.trimmedForPublishing
      + separator
      + normalized
      + "\n"
    updateDraft(updatedDraft)
    save()
    setAIActionMessage(CoreL10n.text("已将本地 Whisper 转写插入当前文章。"))
    return true
  }
}
